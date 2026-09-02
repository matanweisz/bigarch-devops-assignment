# Compute-only. Single-node K3s, the gateway image, and the two client binaries
# the monitoring state drives. Nothing is deployed into the cluster here. That
# is monitoring/init.sls, which requires the service below.

{% set k3s = salt['pillar.get']('k3s') %}
{% set helm = salt['pillar.get']('helm') %}
{% set compute_ip = salt['pillar.get']('net:compute_ip') %}
{% set image_tar = salt['pillar.get']('artifacts:root') ~ '/images/metrics-gateway.tar' %}
{% set staged_tar = k3s.images_dir ~ '/' ~ image_tar.rsplit('/', 1)[-1] %}

{#- The private NIC is eth1 on VirtualBox but not on every provider or box, and
    naming it wrong sends the whole cluster onto the NAT link. Derive it from
    whichever interface holds the address the cluster must serve on, and let
    pillar override when a lab needs a specific one. #}
{% set iface = namespace(name=k3s.flannel_iface) %}
{%- if not iface.name %}
{%- for name, addresses in grains['ip4_interfaces'].items() %}
{%- if compute_ip in addresses %}{% set iface.name = name %}{% endif %}
{%- endfor %}
{%- endif %}
{#- Rendering has to stop here rather than pass an empty --flannel-iface, which
    installs a cluster on the wrong network that then has to be torn down. #}
{%- if not iface.name %}
{{ salt['test.exception']('no interface holds ' ~ compute_ip ~ '; set pillar k3s:flannel_iface') }}
{%- endif %}

# Both installers are curl-to-shell pipelines, and this may be the first state
# to touch apt on a box whose package lists were never fetched.
curl:
  pkg.installed:
    - refresh: True

{{ k3s.images_dir }}:
  file.directory:
    - makedirs: True
    - mode: '0755'

# Staged before the installer so a first boot imports it while the agent starts.
# A rebuilt tar reaching an already-running containerd is the import state
# further down.
k3s-gateway-image:
  file.managed:
    - name: {{ staged_tar }}
    - source: file://{{ image_tar }}
    - mode: '0644'
    - require:
      - file: {{ k3s.images_dir }}

k3s-install:
  cmd.run:
    - name: curl -sfL {{ k3s.install_url }} | sh -s -
    - env:
        # Without --node-ip and --flannel-iface, K3s binds Vagrant's NAT
        # interface and nothing on the private network reaches the API server
        # or the gateway's NodePort. The kubeconfig mode makes kubectl usable
        # without sudo, which the README's verification steps rely on.
        - INSTALL_K3S_EXEC: '--node-ip {{ compute_ip }} --flannel-iface {{ iface.name }} --write-kubeconfig-mode 644'
        - INSTALL_K3S_VERSION: '{{ k3s.version }}'
    # Guards on the installed version, not on the binary's existence: a version
    # bump in pillar has to re-run the installer, and `creates:` would skip it.
    - unless: /usr/local/bin/k3s --version 2>/dev/null | grep -qF '{{ k3s.version }}'
    - require:
      - pkg: curl
      - file: k3s-gateway-image

k3s:
  service.running:
    - enable: True
    - require:
      - cmd: k3s-install

# Containerd does not re-read the images directory once it is running, so
# importing on change is how a rebuilt image reaches the cluster. The rollout
# that picks it up is in monitoring/init.sls.
k3s-gateway-image-import:
  cmd.run:
    # -n k8s.io: ctr defaults to its own namespace, but kubelet and CRI only
    # see images in k8s.io, so without it the import lands where nothing looks.
    # Requiring the k3s service is a real readiness guarantee: k3s.service is
    # Type=notify, so systemd reports it active only once the server and its
    # embedded containerd signal ready.
    - name: /usr/local/bin/k3s ctr -n k8s.io images import {{ staged_tar }}
    - require:
      - service: k3s
    - onchanges:
      - file: k3s-gateway-image

helm-install:
  cmd.run:
    # get-helm-3 needs bash. DESIRED_VERSION stops it resolving the latest
    # release at install time.
    - name: curl -sfL {{ helm.install_url }} | bash
    - env:
        - DESIRED_VERSION: '{{ helm.version }}'
    - unless: /usr/local/bin/helm version --short 2>/dev/null | grep -qF '{{ helm.version }}'
    - require:
      - pkg: curl
