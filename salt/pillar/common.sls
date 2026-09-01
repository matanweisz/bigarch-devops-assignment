net:
  controller_ip: 192.168.56.10
  compute_ip: 192.168.56.11
  # The Vagrant machine names, which are also the guests' hostnames, the Salt
  # minion ids, and the names Slurm knows the two nodes by.
  controller_host: controller
  compute_host: compute

slurm:
  version: "26.05.3"
  cluster_name: bigarch
  partition: debug
  uid: 967
  # Which of the builder's DEBs each role installs. The controller needs the
  # client package too: without it there is no sbatch for the Phase 5 cron job.
  packages:
    controller:
      - slurm-smd
      - slurm-smd-client
      - slurm-smd-slurmctld
      - slurm-smd-slurmdbd
    compute:
      - slurm-smd
      - slurm-smd-client
      - slurm-smd-slurmd
  # The compute node's NodeName line. Both values are rendered into the one
  # slurm.conf both nodes share, so neither can come from the local node's
  # grains. RealMemory is deliberately well under the VM's 6144MB: a value the
  # kernel cannot back drains the node with no error anywhere obvious. Keep
  # compute_cpus in step with the Vagrantfile's sizing for the compute machine.
  compute_cpus: 4
  compute_real_memory: 5000
  db:
    name: slurm_acct_db
    user: slurm
    innodb_buffer_pool_size: "256M"

gateway:
  image: localhost/metrics-gateway:1.0.0
  node_port: 30080

monitoring:
  namespace: monitoring
  release: kps

grafana:
  user: admin
  password: admin

node_exporter:
  image: docker.io/prom/node-exporter:v1.9.1
  port: 9100
