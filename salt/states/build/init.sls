# Builder-only. Wraps scripts/build.sh, which is run straight out of the rsynced
# repo: file_roots already points there, so copying the script into salt://
# would just be a second copy to keep in sync.

{% set version = salt['pillar.get']('slurm:version') %}

build-artifacts:
  cmd.run:
    - name: bash /vagrant/scripts/build.sh
    - env:
        - SLURM_VERSION: '{{ version }}'
        - GATEWAY_IMAGE: '{{ salt['pillar.get']('gateway:image') }}'
        - NODE_EXPORTER_IMAGE: '{{ salt['pillar.get']('node_exporter:image') }}'
    # Guard on the stamp's content, not its existence: a version bump in pillar
    # has to trigger a rebuild, and `creates:` would silently skip it.
    - unless: grep -qx "{{ version }}-$(dpkg --print-architecture)" /opt/artifacts/BUILD_STAMP
    - require:
      - sls: podman
