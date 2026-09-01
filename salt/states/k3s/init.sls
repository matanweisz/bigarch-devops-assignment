# Compute-only. Single-node K3s plus the two client binaries the monitoring
# state drives. Nothing is deployed into the cluster here - that is
# monitoring/init.sls, which requires the service below.

{% set k3s = salt['pillar.get']('k3s') %}
{% set helm = salt['pillar.get']('helm') %}
{% set compute_ip = salt['pillar.get']('net:compute_ip') %}
{% set image_tar = salt['pillar.get']('gateway:image_tar') %}

# Both installers are curl-to-shell pipelines.
curl:
  pkg.installed: []

{{ k3s.images_dir }}:
  file.directory:
    - makedirs: True
    - mode: '0755'

# Staged before the installer runs on purpose: K3s imports every tar in this
# directory while the agent starts, which does not depend on the runtime
# directory watcher that only newer releases have.
k3s-gateway-image:
  file.managed:
    - name: {{ k3s.images_dir }}/{{ image_tar.rsplit('/', 1)[-1] }}
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
        - INSTALL_K3S_EXEC: '--node-ip {{ compute_ip }} --flannel-iface {{ k3s.flannel_iface }} --write-kubeconfig-mode 644'
        - INSTALL_K3S_VERSION: '{{ k3s.version }}'
    - creates: /usr/local/bin/k3s
    - require:
      - pkg: curl
      - file: k3s-gateway-image

k3s:
  service.running:
    - enable: True
    - require:
      - cmd: k3s-install

helm-install:
  cmd.run:
    # get-helm-3 needs bash; DESIRED_VERSION is what stops it resolving the
    # latest release at install time.
    - name: curl -sfL {{ helm.install_url }} | bash
    - env:
        - DESIRED_VERSION: '{{ helm.version }}'
    - creates: /usr/local/bin/helm
    - require:
      - pkg: curl
