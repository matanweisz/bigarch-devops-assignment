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
  # How long to wait for the gateway to become ready, both for helm --wait and
  # for the rollout that follows a rebuilt image.
  wait_timeout: 5m

k3s:
  version: "v1.36.4+k3s1"
  install_url: https://get.k3s.io
  # Fixed by k3s, but read by both the k3s and the monitoring states, so it is
  # written once here rather than twice in the states.
  kubeconfig: /etc/rancher/k3s/k3s.yaml
  images_dir: /var/lib/rancher/k3s/agent/images
  # K3s follows the default route unless told otherwise, which lands it on
  # Vagrant's NAT link where no other node can reach it. Left empty the state
  # derives the right interface from the one holding net:compute_ip, because
  # the private NIC is not named the same on every provider and box. Set a
  # name here to override that.
  flannel_iface: ""

helm:
  version: "v3.21.4"
  # Pinned to the same tag as helm:version so the installer script and the
  # binary it fetches cannot drift apart.
  install_url: https://raw.githubusercontent.com/helm/helm/v3.21.4/scripts/get-helm-3

monitoring:
  namespace: monitoring
  release: kps
  kps_chart: kube-prometheus-stack
  kps_version: "88.6.2"
  repo_name: prometheus-community
  repo_url: https://prometheus-community.github.io/helm-charts
  # The stack pulls a dozen images on a first install, so this is generous.
  wait_timeout: 15m
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
  dashboard_prefix: grafana-dashboard-
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
