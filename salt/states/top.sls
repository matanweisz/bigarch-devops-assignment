base:
  'role:builder':
    - match: grain
    - podman
    - build

  'role:controller':
    - match: grain
    - podman
    - munge
    - mariadb
    - slurm.controller
    - node_exporter
    - slurm.cron

  'role:compute':
    - match: grain
    - munge
    - slurm.compute
    - k3s
    - monitoring
