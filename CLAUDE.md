# Project context for AI-assisted sessions

This file is the working context I maintain for Claude Code while building this
assignment. It is committed on purpose: the submission criteria ask for transparency
about AI use, and this file shows exactly what the AI was told, which decisions were
locked by me, and which constraints it had to respect. The README's AI-usage section
explains how we worked; this file is the primary artifact of it.

## What this project is

A DevOps hiring assignment: `vagrant up` brings up a three-node lab that bridges an
HPC scheduler (Slurm) with a cloud-native monitoring stack (K3s, Prometheus, Grafana),
configured end to end by SaltStack. See README.md for the full architecture.

Nodes on a private network, 192.168.56.0/24:

- **builder** (.5): ephemeral. Compiles Slurm DEBs from source with the official
  Debian flow (`mk-build-deps -i debian/control`, `debuild -b -uc -us`), builds the
  metrics-gateway container image, exports everything as artifacts, then powers off.
- **controller** (.10): Salt master and its own minion, slurmctld, slurmdbd, MariaDB,
  munge, and a node_exporter container under Podman.
- **compute** (.11): Salt minion, slurmd, single-node K3s running
  kube-prometheus-stack and the custom metrics gateway.

Primary provider is VirtualBox so the same Vagrantfile runs on an Apple Silicon Mac,
an Ubuntu laptop, or an Intel reviewer machine; a vmware_desktop block is kept as an
alternative. Box: `bento/ubuntu-24.04`, version pinned, which publishes arm64 and
amd64 builds for both providers.

## Decisions locked by the author

These were settled after research and two adversarial design reviews. Agents do not
change them without my explicit approval.

1. The Salt master runs with `auto_accept: True` because the assignment mandates
   auto-accept. The more secure alternative (pre-seeded keys via `seed_master`) was
   considered and rejected for contradicting the instructions. The README documents
   why auto-accept is acceptable only on an isolated lab network.
2. The controller's salt provisioner sets `run_highstate: false`, and a follow-up
   shell step runs `salt-call state.highstate --retcode-passthrough`. Vagrant refuses
   `install_master` together with `run_highstate` unless keys are pre-seeded, and its
   master-mode highstate path does not propagate state failures. This arrangement
   keeps the mandated provisioner and makes failures visible.
3. The builder is provisioned with the vagrant salt provisioner in masterless mode
   and applies the same `podman` state the controller uses. One state, two consumers,
   which is the point of the no-duplication criterion.
4. No NFS synced folders anywhere. macOS 15.4 and later has an unresolved nfsd kernel
   panic that Vagrant environments reliably trigger. Artifacts travel from the builder
   to the host over `vagrant ssh` with tar, and from the host to the other guests
   through normal one-way synced folders. All synced folders are declared
   `type: "rsync"` so behavior is identical across providers and host OSes.
5. MariaDB provisioning uses plain idempotent SQL (`CREATE DATABASE IF NOT EXISTS`,
   `CREATE USER IF NOT EXISTS`, `GRANT`) rendered from pillar into a root-only file
   and applied over the unix socket. Salt's `mysql_*` states need a Python MySQL
   driver inside Salt's own bundled (onedir) interpreter, which cannot see
   apt-installed packages; the SQL route removes that dependency entirely.
6. Both Helm releases (kube-prometheus-stack and the local gateway chart) are managed
   the same way: `helm upgrade --install --wait`, guarded so highstate reruns are
   clean no-ops and a failed first release still gets retried.
7. Grafana dashboards (Node Exporter Full, ID 1860, and the custom Slurm panel) are
   vendored as JSON in this repo and provisioned as sidecar ConfigMaps. No runtime
   downloads from grafana.com, so the deployment is reproducible offline.
8. The gateway code contains an unused `import sys` with no comment because the
   assignment explicitly instructs it. It stays. No linter is added to the repo,
   since any Python linter would flag it. We read this instruction as a check that
   submitters actually read the spec and review what their tools generate.
9. Grafana logs in with admin/admin, sourced from pillar and stated in the README.
10. Deliberately not used: map.jinja (single-OS lab), a private registry, cert-manager
    (Traefik's default certificate is enough for grafana.local), and CI. Each would
    add moving parts without serving a requirement.

## Traps confirmed during research

Forgetting any of these costs hours of debugging.

- Salt 3008 masks pillar values (`**********`) at the `pillar.get` module boundary
  and lifts the mask only for template renderers and `file.managed`. `file.decode`
  was missed upstream: it decodes the mask string to zero bytes and writes an empty
  file while reporting Changed. Never use `file.decode` with `contents_pillar` on
  3008; write the base64 text with `file.managed` instead. When debugging, add
  `unmask=True` to `salt-call pillar.get`.
- Slurm 26.05 demoted munge to a weak package dependency. Install the built DEBs with
  `apt-get install ./*.deb`, never `dpkg -i`, and keep munge as a hard Salt require.
- The controller needs `slurm-smd-client` or `sbatch` does not exist and the Phase 5
  cron job fails.
- The `slurm` user must exist with the same UID on both nodes before the DEBs are
  installed, or state directories get the wrong owner.
- `RealMemory` in slurm.conf must stay below what the kernel reports or the compute
  node drains silently. It is derived from grains minus headroom. The node line also
  carries `State=UNKNOWN` and `ReturnToService=2`.
- `ProctrackType=proctrack/cgroup` does nothing for resource limits without
  `TaskPlugin=task/cgroup,task/affinity`.
- K3s must be started with `--node-ip 192.168.56.11` and a `--flannel-iface` naming the
  private NIC, or it binds the NAT interface; `--write-kubeconfig-mode 644` for a usable
  kubeconfig. The state derives the interface name from whichever one holds
  `net:compute_ip` instead of assuming `eth1`, with `k3s:flannel_iface` as an override.
- The gateway chart must ship a ServiceMonitor carrying the kube-prometheus-stack
  release label. Without it Prometheus never scrapes the gateway and the whole
  validation loop produces an empty panel.
- kube-prometheus-stack values: disable the etcd, scheduler, controller-manager and
  kube-proxy scrape targets (K3s does not expose them), and disable the
  node-exporter ServiceMonitor while keeping its DaemonSet, which serves compute's
  9100 while the Podman exporter serves the controller's.
- Quadlet-generated services cannot be enabled with systemctl; Salt must not set
  `enable: True` on them, and systemd needs a daemon-reload when the `.container`
  file changes.
- The gateway runs one worker; its metric store is in memory and entries expire so
  dashboards do not show stale flat lines after a job ends.
- Synced folders of type rsync only sync on `up`, `reload`, or `vagrant rsync`.
  After editing Salt states: `vagrant rsync controller`, then provision.

## Conventions for all changes

- Every tunable value (versions, IPs, ports, credentials, UIDs) lives in Salt pillar.
  States never hardcode what pillar can carry. Node targeting uses the `role` grain.
- Idempotency is a graded criterion: any state must survive a second highstate with
  zero changes, and must never duplicate a container or restart a healthy service.
- Phase boundaries get a full `vagrant destroy -f && vagrant up` plus a second
  highstate as proof.
- Comments in code explain constraints, not what the next line does. No emoji.
- I review every diff, and I need to be able to explain every line. Anything
  non-obvious gets a written rationale.
