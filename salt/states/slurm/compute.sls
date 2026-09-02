# Compute only: the daemon that actually runs jobs. Users, host entries, the
# DEB install for this role's package set, slurm.conf and cgroup.conf all come
# from slurm/common.sls. Nothing here duplicates that.

include:
  - munge
  - slurm.common

# slurmd's SlurmdSpoolDir, from slurm.conf.j2. It has to exist with slurm
# ownership before slurmd can start. Asserted here for the same reason
# controller.sls asserts ownership on /var/spool/slurmctld.
/var/spool/slurmd:
  file.directory:
    - user: slurm
    - group: slurm
    - mode: '0700'
    - require:
      - user: slurm-user

slurmd:
  service.running:
    - enable: True
    - require:
      - cmd: slurm-packages
      - file: /var/spool/slurmd
      - file: /var/log/slurm
      - service: munge-service
    - watch:
      - file: /etc/slurm/slurm.conf
      - file: /etc/slurm/cgroup.conf
      - file: /etc/munge/munge.key
