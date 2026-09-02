# Shared by the builder (image build) and the controller (node_exporter under a
# Quadlet). One state, two consumers.

podman:
  pkg.installed:
    # First apt-touching state on the builder. Same stale-index reasoning as
    # the munge and mariadb installs.
    - refresh: True []

# Quadlet drop-in directory. systemd's generator only reads it if it exists, and
# the controller's node_exporter .container file lands here.
/etc/containers/systemd:
  file.directory:
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True
    - require:
      - pkg: podman
