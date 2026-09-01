# Compute-only. Everything that runs inside K3s: kube-prometheus-stack, the
# vendored Grafana dashboards, and the metrics gateway chart.
#
# Both Helm releases are managed identically. `helm upgrade --install` converges
# rather than re-executes, and the guard on each release is a single `unless`
# that answers one question: is this release deployed from exactly the values
# file we hold now? That is false when the release is missing (first run, or a
# failed install to retry) and false when the values changed, and true on a
# clean re-run - which is the whole idempotency requirement. It is one `unless`
# rather than `unless` plus `onchanges` because Salt requires every gate to
# pass, so combining the two would skip an upgrade after a values change.
#
# The environment travels inline in the two command prefixes below rather than
# through `env:`, so a guard runs with exactly the environment its command does.
# A guard that silently loses KUBECONFIG fails, which reads as "not deployed"
# and re-runs helm on every highstate - an idempotency break that nothing in the
# output would point at.

include:
  - k3s

{% set mon = salt['pillar.get']('monitoring') %}
{% set gateway = salt['pillar.get']('gateway') %}
{% set kubeconfig = salt['pillar.get']('k3s:kubeconfig') %}

{# HOME is set because helm derives its repository and cache paths from it and
   Salt does not set one unless a state uses runas. Left to the minion's own
   environment, the repository list would land in a different directory
   depending on whether the highstate came from salt-call or from the master,
   and the repo guard below would stop being idempotent. #}
{% set env = 'HOME=/root KUBECONFIG=' ~ kubeconfig %}
{% set helm = env ~ ' /usr/local/bin/helm' %}
{% set kubectl = env ~ ' /usr/local/bin/kubectl' %}

{% set kps_values = mon.workdir ~ '/kps-values.yaml' %}
{% set gateway_values = mon.workdir ~ '/gateway-values.yaml' %}

{{ mon.workdir }}:
  file.directory:
    - user: root
    - group: root
    # The rendered kube-prometheus-stack values carry the Grafana password.
    - mode: '0750'

monitoring-namespace:
  cmd.run:
    - name: {{ kubectl }} create namespace {{ mon.namespace }}
    - unless: {{ kubectl }} get namespace {{ mon.namespace }} > /dev/null 2>&1
    - require:
      - service: k3s

monitoring-helm-repo:
  cmd.run:
    - name: {{ helm }} repo add {{ mon.repo_name }} {{ mon.repo_url }} && {{ helm }} repo update {{ mon.repo_name }}
    - unless: {{ helm }} repo list 2>/dev/null | grep -q '^{{ mon.repo_name }}[[:space:]]'
    - require:
      - cmd: helm-install

kps-values:
  file.managed:
    - name: {{ kps_values }}
    - source: salt://monitoring/files/kps-values.yaml.j2
    - template: jinja
    - mode: '0600'
    - require:
      - file: {{ mon.workdir }}

kps-release:
  cmd.run:
    - name: >-
        {{ helm }} upgrade --install {{ mon.release }} {{ mon.repo_name }}/kube-prometheus-stack
        --version {{ mon.kps_version }}
        --namespace {{ mon.namespace }}
        --values {{ kps_values }}
        --wait --timeout 15m
        && install -m 0600 {{ kps_values }} {{ kps_values }}.applied
    - unless: >-
        {{ helm }} status {{ mon.release }} --namespace {{ mon.namespace }} 2>/dev/null
        | grep -q '^STATUS: deployed'
        && cmp -s {{ kps_values }} {{ kps_values }}.applied
    - require:
      - cmd: monitoring-namespace
      - cmd: monitoring-helm-repo
      - file: kps-values

# One mechanism for both dashboards: the repo's JSON is staged under the work
# directory, and the staged copy is both the ConfigMap's content and the change
# detector that decides whether the ConfigMap needs reapplying. `kubectl apply`
# would be idempotent against the cluster on its own, but cmd.run always reports
# a change, so the `onchanges` is what keeps a second highstate clean.
#
# The manifest is built by kubectl rather than templated here because dashboard
# 1860 is roughly fifteen thousand lines: rendering it through Jinja would mean
# holding and re-escaping the whole document for no gain.
{% for dashboard in mon.dashboards %}
{% set name = dashboard.rsplit('.', 1)[0] %}

dashboard-file-{{ name }}:
  file.managed:
    - name: {{ mon.workdir }}/dashboards/{{ dashboard }}
    - source: file://{{ mon.dashboards_dir }}/{{ dashboard }}
    - mode: '0644'
    - makedirs: True
    - require:
      - file: {{ mon.workdir }}

dashboard-configmap-{{ name }}:
  cmd.run:
    - name: >-
        {{ kubectl }} create configmap grafana-dashboard-{{ name }}
        --namespace {{ mon.namespace }}
        --from-file={{ dashboard }}={{ mon.workdir }}/dashboards/{{ dashboard }}
        --dry-run=client --output yaml
        | {{ kubectl }} label --local --filename - --output yaml
        {{ mon.dashboard_label }}={{ mon.dashboard_label_value }}
        | {{ kubectl }} apply --filename -
    - require:
      - cmd: monitoring-namespace
    - onchanges:
      - file: dashboard-file-{{ name }}
{% endfor %}

gateway-values:
  file.managed:
    - name: {{ gateway_values }}
    - source: salt://monitoring/files/gateway-values.yaml.j2
    - template: jinja
    - mode: '0644'
    - require:
      - file: {{ mon.workdir }}

gateway-release:
  cmd.run:
    - name: >-
        {{ helm }} upgrade --install {{ gateway.release }} {{ gateway.chart }}
        --namespace {{ mon.namespace }}
        --values {{ gateway_values }}
        --wait --timeout 5m
        && install -m 0644 {{ gateway_values }} {{ gateway_values }}.applied
    - unless: >-
        {{ helm }} status {{ gateway.release }} --namespace {{ mon.namespace }} 2>/dev/null
        | grep -q '^STATUS: deployed'
        && cmp -s {{ gateway_values }} {{ gateway_values }}.applied
    - require:
      - file: gateway-values
      # The chart ships a ServiceMonitor, whose CRD is installed by
      # kube-prometheus-stack. Without this the first install fails on an
      # unknown kind. It is the only ordering the two releases need.
      - cmd: kps-release
      # The image is never pulled, so the tar has to be on disk for K3s to
      # import before any pod referencing it can start.
      - file: k3s-gateway-image
