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
# so the two nodes would disagree about it. Claiming the id from pillar before
# the package runs keeps /etc/munge ownership identical on both.
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

# The key file carries the base64 text of 128 random bytes, written verbatim.
# munged treats the keyfile as opaque bytes, so the text form carries the same
# entropy as the decoded binary would. Decoding on the node is not an option:
# Salt 3008 masks pillar values at the pillar.get module boundary and lifts the
# mask for template renderers and file.managed, but not for file.decode, which
# therefore receives '**********', discards it as invalid base64 and writes an
# empty key (verified against 3008.2 on this box). file.managed also sets the
# final mode atomically, so the key is never world-readable in passing.
/etc/munge/munge.key:
  file.managed:
    - contents_pillar: munge:key_b64
    - user: munge
    - group: munge
    - mode: '0600'
    - show_changes: False
    - require:
      - file: /etc/munge

munge-service:
  service.running:
    - name: munge
    - enable: True
    - require:
      - pkg: munge
    - watch:
      - file: /etc/munge/munge.key
