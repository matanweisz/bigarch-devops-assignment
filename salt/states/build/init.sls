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
    # The script's --check mode compares both stamps (DEB version+arch, image
    # tags + gateway content hash), so the skip logic lives in one place and a
    # pillar bump or gateway edit triggers exactly the rebuild it needs.
    # `creates:` would silently skip all of that.
    - unless: bash /vagrant/scripts/build.sh --check
    - require:
      - sls: podman
