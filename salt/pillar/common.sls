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
  # Written by the builder, rsynced to every node with the repo. K3s imports it
  # from disk, so the image is never pulled from a registry.
  image_tar: /vagrant/artifacts/images/metrics-gateway.tar
  chart: /vagrant/charts/metrics-gateway
  release: metrics-gateway

k3s:
  version: "v1.36.4+k3s1"
  install_url: https://get.k3s.io
  # Fixed by k3s, but read by both the k3s and the monitoring states, so it is
  # written once here rather than twice in the states.
  kubeconfig: /etc/rancher/k3s/k3s.yaml
  images_dir: /var/lib/rancher/k3s/agent/images
  # eth0 is Vagrant's NAT link. K3s follows the default route unless told
  # otherwise, which puts the cluster on an address no other node can reach.
  flannel_iface: eth1

helm:
  version: "v3.21.4"
  # Pinned to the same tag as helm:version so the installer script and the
  # binary it fetches cannot drift apart.
  install_url: https://raw.githubusercontent.com/helm/helm/v3.21.4/scripts/get-helm-3

monitoring:
  namespace: monitoring
  release: kps
  kps_version: "88.6.2"
  repo_name: prometheus-community
  repo_url: https://prometheus-community.github.io/helm-charts
  # Rendered values files and their applied-stamps.
  workdir: /opt/monitoring
  # Sized for the 6GB compute VM. A lab has no use for long retention, and an
  # unbounded Prometheus is the first thing to OOM here.
  retention: 2h
  prometheus_cpu_request: 200m
  prometheus_memory_request: 400Mi
  prometheus_memory_limit: 1Gi
  # Grafana's sidecar imports every ConfigMap carrying this label, which is how
  # the vendored dashboards get in. Used by both the chart values and the
  # ConfigMaps themselves, so the two cannot disagree.
  dashboard_label: grafana_dashboard
  dashboard_label_value: "1"
  dashboards_dir: /vagrant/dashboards
  dashboards:
    - node-exporter-full-1860.json
    - slurm-job-load.json

grafana:
  user: admin
  password: admin
  host: grafana.local
  # K3s bundles Traefik and it stays enabled, so this is the only ingress
  # class present on the cluster.
  ingress_class: traefik

node_exporter:
  image: docker.io/prom/node-exporter:v1.9.1
  port: 9100
