# Controller only: the two daemons that make this node the cluster's brain.
# Everything shared with the compute node lives in slurm/common.sls.

{% set cluster = salt['pillar.get']('slurm:cluster_name') %}

include:
  - munge
  - mariadb
  - slurm.common

/etc/slurm/slurmdbd.conf:
  file.managed:
    - source: salt://slurm/files/slurmdbd.conf.j2
    - template: jinja
    - user: slurm
    - group: slurm
    - mode: '0600'
    # The rendered file carries the database password; a diff in the highstate
    # output would put it on the terminal and in Vagrant's log.
    - show_changes: False
    - require:
      - file: /etc/slurm
      - user: slurm-user

# slurmctld keeps the job queue and its own state here across restarts. The
# package creates it, but only correctly if the slurm account already existed at
# install time, so the ownership is asserted rather than assumed.
/var/spool/slurmctld:
  file.directory:
    - user: slurm
    - group: slurm
    - mode: '0700'
    - require:
      - user: slurm-user

# The database has to be reachable before slurmdbd starts: on a first run it
# creates the whole accounting schema, and it exits if it cannot log in.
slurmdbd:
  service.running:
    - enable: True
    - require:
      - cmd: slurm-packages
      - cmd: slurm-db-provisioned
      - service: mariadb
      - service: munge-service
    - watch:
      - file: /etc/slurm/slurmdbd.conf
      - file: /etc/munge/munge.key

slurmctld:
  service.running:
    - enable: True
    - require:
      - cmd: slurm-packages
      - file: /var/spool/slurmctld
      - file: /var/log/slurm
      - service: slurmdbd
      - service: munge-service
    - watch:
      - file: /etc/slurm/slurm.conf
      - file: /etc/munge/munge.key

# Defensive: slurmctld registers the cluster with slurmdbd on its own, but that
# happens asynchronously and sacct is unusable until it has. Registering by hand
# turns a race into a state that either passed or failed.
#
# The retry is for the same race in the other direction: slurmdbd accepts
# connections a beat after systemd calls it started, and the first sacctmgr can
# land in that gap.
slurm-cluster-registered:
  cmd.run:
    - name: sacctmgr -i add cluster {{ cluster }}
    - unless: sacctmgr -nP show cluster format=Cluster | cut -d'|' -f1 | grep -qx {{ cluster }}
    - retry:
        attempts: 5
        interval: 5
    - require:
      - service: slurmdbd
      - service: slurmctld
