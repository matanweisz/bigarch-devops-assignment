net:
  controller_ip: 192.168.56.10
  compute_ip: 192.168.56.11

slurm:
  version: "26.05.3"
  cluster_name: bigarch
  uid: 967
  db:
    name: slurm_acct_db
    user: slurm

munge:
  uid: 966

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
