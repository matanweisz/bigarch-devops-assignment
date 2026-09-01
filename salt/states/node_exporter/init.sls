# Controller only. The assignment puts a Podman-run node exporter on this node;
# the compute node's :9100 comes from the kube-prometheus-stack DaemonSet
# instead, and Prometheus scrapes both by address.

{% set image = salt['pillar.get']('node_exporter:image') %}

include:
  - podman

# The image was pulled and saved on the builder, so nothing here reaches the
# network. `podman image exists` is the guard because a second `podman load`
# would succeed and change nothing, which the state output would still report as
# a change on every run.
node-exporter-image:
  cmd.run:
    - name: podman load -i /vagrant/artifacts/images/node-exporter.tar
    - unless: podman image exists {{ image }}
    - require:
      - pkg: podman

/etc/containers/systemd/node-exporter.container:
  file.managed:
    - source: salt://node_exporter/files/node-exporter.container.j2
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: /etc/containers/systemd

# The Quadlet generator only runs at daemon-reload, so systemd learns about
# node-exporter.service here and nowhere else. onchanges keeps it to the runs
# where the unit file actually moved.
node-exporter-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: /etc/containers/systemd/node-exporter.container

# No enable: True. systemctl cannot enable a generated unit, and asking it to is
# a hard failure; the [Install] section in the .container file is what starts the
# exporter at boot. Running the service is declarative, so a re-run finds it
# already up and leaves the container alone instead of starting a second one.
node-exporter:
  service.running:
    - require:
      - cmd: node-exporter-image
      - cmd: node-exporter-daemon-reload
    - watch:
      - file: /etc/containers/systemd/node-exporter.container
