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
    # The apt index here is whatever last refreshed it: salt-bootstrap's own
    # update when it installed Salt on a fresh boot, and nothing at all on a
    # later `vagrant provision` against a long-lived box, where the pinned
    # versions the stale index names may no longer be on the mirror. Refreshing
    # makes this install independent of that, and it reports no state changes,
    # so it stays invisible in the idempotency proof.
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

# file.decode writes contents and nothing else, so it would create the key at
# whatever the umask says and leave it world-readable until a later state
# tightened it. Creating the empty file at its final mode first closes that
# window: the decode below opens an existing 0600 file and only rewrites its
# bytes. replace: False keeps this state away from the contents it does not own.
munge-key-file:
  file.managed:
    - name: /etc/munge/munge.key
    - user: munge
    - group: munge
    - mode: '0600'
    - replace: False
    - create: True
    - require:
      - file: /etc/munge

# The key is 128 random bytes. Carrying it through pillar base64-encoded and
# decoding here keeps binary content out of the YAML and out of git.
/etc/munge/munge.key:
  file.decode:
    - encoding_type: base64
    - contents_pillar: munge:key_b64
    - checksum: sha256
    - require:
      - file: munge-key-file

munge-service:
  service.running:
    - name: munge
    - enable: True
    - require:
      - pkg: munge
    - watch:
      - file: munge-key-file
      - file: /etc/munge/munge.key
