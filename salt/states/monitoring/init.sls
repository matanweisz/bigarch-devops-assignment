# Compute-only. Everything that runs inside K3s: kube-prometheus-stack, the
# vendored Grafana dashboards, and the metrics gateway chart.
#
# Both Helm releases are managed identically, and the guard on each is a single
# `unless` comparing what is deployed against a stamp written only after a
# successful release. The obvious alternatives do not hold up:
#
#   - `onchanges` on the values file alone cannot retry a failed install. The
#     file is written once; if helm then fails, every later highstate sees an
#     unchanged file, keeps the gate shut, and the release stays broken.
#   - `unless: helm status ... deployed` alone retries that failure, but never
#     notices a values, chart or version change.
#   - Both together inherit the first problem, because Salt requires every gate
#     to pass before a state runs.
#
# The stamp carries the release's whole identity - rendered values, and for the
# local chart its file hashes - so the guard is false on a first run, false
# after a failed install, false after any input changes, and true only on a
# clean re-run.
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

{#- An interrupted highstate leaves a release in pending-install or
    pending-upgrade, which helm refuses to touch again ("another operation is in
    progress") until it is cleared. Both releases start by clearing that state
    so a re-run recovers instead of needing a manual uninstall. #}
{#- Both macros must expand to a single line: they are used inside folded YAML
    scalars, where a newline at column zero would end the block. #}
{%- macro unwedge(release) -%}
{{ helm }} status {{ release }} --namespace {{ mon.namespace }} 2>/dev/null | grep -q '^STATUS: pending' && {{ helm }} uninstall {{ release }} --namespace {{ mon.namespace }} --wait || true;
{%- endmacro %}

{#- The local chart has no version to pin against, so its stamp is the rendered
    values plus a hash of every file in the chart. Editing a template is then
    indistinguishable from editing the values, which is the point. #}
{%- macro gateway_identity() -%}
{ cat {{ gateway_values }}; find {{ gateway.chart }} -type f -exec sha256sum {} + | sort; }
{%- endmacro %}

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
    # --force-update rewrites the entry instead of failing when the name is
    # already taken by a different URL.
    - name: >-
        {{ helm }} repo add --force-update {{ mon.repo_name }} {{ mon.repo_url }}
        && {{ helm }} repo update {{ mon.repo_name }}
    # Matched on the URL, not the name: a name pointing at the wrong repository
    # is exactly the case this has to catch.
    - unless: {{ helm }} repo list -o json 2>/dev/null | grep -q '"{{ mon.repo_url }}"'
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
        {{ unwedge(mon.release) }}
        {{ helm }} upgrade --install {{ mon.release }} {{ mon.repo_name }}/{{ mon.kps_chart }}
        --version {{ mon.kps_version }}
        --namespace {{ mon.namespace }}
        --values {{ kps_values }}
        --wait --timeout {{ mon.wait_timeout }}
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
# directory, and the staged copy is what the ConfigMap is built from and what
# the guard compares the cluster against.
#
# The manifest is built by kubectl rather than templated here because dashboard
# 1860 is roughly fifteen thousand lines: rendering it through Jinja would mean
# holding and re-escaping the whole document for no gain.
{% for dashboard in mon.dashboards %}
{% set name = dashboard.rsplit('.', 1)[0] %}
{% set configmap = mon.dashboard_prefix ~ name %}
{% set staged = mon.workdir ~ '/dashboards/' ~ dashboard %}

dashboard-file-{{ name }}:
  file.managed:
    - name: {{ staged }}
    - source: file://{{ mon.dashboards_dir }}/{{ dashboard }}
    - mode: '0644'
    - makedirs: True
    - require:
      - file: {{ mon.workdir }}

dashboard-configmap-{{ name }}:
  cmd.run:
    # Server-side apply: a client-side apply stores the whole object in the
    # last-applied-configuration annotation, and 1860 is far past the 256KB
    # annotation limit. --force-conflicts takes ownership of fields a previous
    # client-side apply recorded.
    - name: >-
        {{ kubectl }} create configmap {{ configmap }}
        --namespace {{ mon.namespace }}
        --from-file={{ dashboard }}={{ staged }}
        --dry-run=client --output yaml
        | {{ kubectl }} label --local --filename - --output yaml
        {{ mon.dashboard_label }}={{ mon.dashboard_label_value }}
        | {{ kubectl }} apply --server-side --force-conflicts --filename -
    # Compares what the cluster actually holds against the staged file, so a
    # ConfigMap someone deleted or edited is restored, while an untouched one
    # keeps a second highstate clean. An `onchanges` on the staged file would
    # never notice that drift.
    - unless: >-
        {{ kubectl }} get configmap {{ configmap }} --namespace {{ mon.namespace }}
        --output jsonpath="{.data['{{ dashboard | replace('.', '\\.') }}']}" 2>/dev/null
        | cmp -s - {{ staged }}
    - require:
      - cmd: monitoring-namespace
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

# Placed before the release on purpose. On a first highstate there is no
# deployment yet and this is a no-op; on a later one, a rebuilt image has just
# been imported into containerd and the running pods are still on the old
# layers, so they are cycled here and the release below then finds nothing to
# change. An `if` rather than `cmd || true`: a missing deployment is a silent
# success, but a rollout that genuinely fails still fails the state.
gateway-rollout:
  cmd.run:
    - name: >-
        if {{ kubectl }} get deployment {{ gateway.release }} --namespace {{ mon.namespace }} > /dev/null 2>&1;
        then {{ kubectl }} rollout restart deployment/{{ gateway.release }} --namespace {{ mon.namespace }}
        && {{ kubectl }} rollout status deployment/{{ gateway.release }} --namespace {{ mon.namespace }}
        --timeout {{ gateway.wait_timeout }};
        fi
    - require:
      - cmd: monitoring-namespace
    - onchanges:
      - cmd: k3s-gateway-image-import

gateway-release:
  cmd.run:
    - name: >-
        {{ unwedge(gateway.release) }}
        {{ helm }} upgrade --install {{ gateway.release }} {{ gateway.chart }}
        --namespace {{ mon.namespace }}
        --values {{ gateway_values }}
        --wait --timeout {{ gateway.wait_timeout }}
        && {{ gateway_identity() }} > {{ gateway_values }}.applied
    - unless: >-
        {{ helm }} status {{ gateway.release }} --namespace {{ mon.namespace }} 2>/dev/null
        | grep -q '^STATUS: deployed'
        && {{ gateway_identity() }} | cmp -s - {{ gateway_values }}.applied
    - require:
      - file: gateway-values
      - cmd: gateway-rollout
      # The chart ships a ServiceMonitor, whose CRD is installed by
      # kube-prometheus-stack. Without this the first install fails on an
      # unknown kind. It is the only ordering the two releases need.
      - cmd: kps-release
      # The image is never pulled, so it has to be in containerd before any pod
      # referencing it can start.
      - cmd: k3s-gateway-image-import
