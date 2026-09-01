# Applied on the controller and the compute node. Slurm authenticates every RPC
# with munge, so both ends need the same account and the same key material.
# Nothing here is role-specific on purpose.

{% set munge_uid = salt['pillar.get']('munge:uid') %}

munge-group:
  group.present:
    - name: munge
    - gid: {{ munge_uid }}
    - system: True

# The munge package creates its own account with whatever id happens to be free,
# so the two nodes would disagree about it. Claiming the id from pillar first is
# what keeps /etc/munge ownership identical on both.
munge-user:
  user.present:
    - name: munge
    - uid: {{ munge_uid }}
    - gid: {{ munge_uid }}
    - home: /var/lib/munge
    - shell: /usr/sbin/nologin
    - system: True
    - createhome: False
    - require:
      - group: munge-group

munge:
  pkg.installed:
    # The base box ships with an empty apt list cache, so the first install of a
    # run has to refresh it. A refresh reports no state changes, so this stays
    # invisible on re-runs.
    - refresh: True
    - require:
      - user: munge-user

/etc/munge:
  file.directory:
    - user: munge
    - group: munge
    - mode: '0700'
    - require:
      - pkg: munge

# The key is 128 random bytes. Carrying it through pillar base64-encoded and
# decoding here keeps binary content out of the YAML and out of git.
/etc/munge/munge.key:
  file.decode:
    - encoding_type: base64
    - contents_pillar: munge:key_b64
    - checksum: sha256
    - require:
      - file: /etc/munge

# file.decode writes contents and nothing else. replace: False lets a second
# state own mode and ownership without touching the bytes.
munge-key-permissions:
  file.managed:
    - name: /etc/munge/munge.key
    - user: munge
    - group: munge
    - mode: '0600'
    - replace: False
    - require:
      - file: /etc/munge/munge.key

munge-service:
  service.running:
    - name: munge
    - enable: True
    - require:
      - pkg: munge
    - watch:
      - file: /etc/munge/munge.key
      - file: munge-key-permissions
