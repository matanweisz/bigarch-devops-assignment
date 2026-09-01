> Historical design spec, frozen as written before implementation started.
> Where it differs from the code or the README, the code and README are
> authoritative; study/STATE.md records what actually changed and why.

# BigArch HPC-DevOps Hybrid Orchestrator — Design Spec

Date: 2026-08-31 · Status: approved by Matan · Location: `study/` (drafted as local
prep material; later committed deliberately for process transparency).

## Goal

One-button (`vagrant up`) 3-VM lab: an ephemeral builder compiles Slurm 26.05.x DEBs +
container images; a Salt-master controller runs slurmctld/slurmdbd/MariaDB/munge/Podman
node_exporter; a compute minion runs slurmd + single-node K3s with kube-prometheus-stack
and a custom Python metrics gateway. A cron-driven Slurm job pushes simulated
CPU/GPU/Mem metrics through the gateway into Prometheus/Grafana ("Live Slurm Job Load"
panel). Graded on: AI explainability, pillar/grains (no hardcoding), no duplication,
idempotent highstate, README quality.

## Host & providers

- Hosts: Apple Silicon Mac (arm64, 32GB/10 cores, macOS 26.5) today; an Ubuntu laptop
  (amd64) later; possibly an Intel reviewer machine. Portability is a requirement.
- Provider: **VirtualBox 7.1+** primary (free, runs on all three host types with one
  Vagrantfile; static-IP host-only nets are its native behavior and 192.168.56.0/24 is
  its default allowed range). A `vmware_desktop` provider block is kept as an
  alternative for Fusion users. Decision revised 2026-08-31 when the Ubuntu-laptop
  requirement landed; Fusion was never installed.
- All synced folders declared `type: "rsync"` explicitly: identical one-way behavior on
  every provider/host OS, and it sidesteps VirtualBox's arm64 guest-additions (vboxsf)
  quirks. Artifact return path is SSH tar, also provider-agnostic.
- Box: `bento/ubuntu-24.04`, version pinned (e.g. 202510.26.0). Publishes arm64+amd64
  for virtualbox and vmware_desktop.
- Phase 0 gate: smoke-test that VirtualBox on this Mac (arm64) boots the bento box with
  a static-IP private network. Vagrant 2.4.9 already installed. If arm64 VirtualBox
  proves unstable, fall back to Fusion on the Mac only; IPs and states don't change.

## Topology

Private network `192.168.56.0/24` (inside VirtualBox's default host-only range).

| VM | IP | RAM/CPU | Role |
|---|---|---|---|
| builder | .5 | 4GB/6cpu | Ephemeral. Vagrant **salt provisioner, masterless** (`role: builder` grain): applies shared `podman` sls + `build` sls (wraps `scripts/build.sh`). Halted by a Vagrant trigger scoped to its define block. |
| controller | .10 | 3GB/2cpu | Vagrant salt provisioner `install_master: true` + self-minion (`master: 127.0.0.1`), `run_highstate: false`; follow-up shell step `salt-call state.highstate --retcode-passthrough`. Runs slurmctld, slurmdbd, MariaDB, munge, Podman node_exporter (Quadlet), Phase-5 cron. |
| compute | .11 | 6GB/4cpu | Vagrant salt provisioner minion → .10, highstate at provision. Runs slurmd, K3s, kube-prometheus-stack, metrics gateway. |

`vagrant up` boots them in definition order (VMware provider is strictly serial) = the
one button. Vagrantfile precondition aborts controller/compute provisioning with a clear
message if artifacts are missing.

## Artifact flow (no NFS — macOS ≥15.4 nfsd kernel-panic bug)

1. Builder compiles Slurm DEBs (official flow: `mk-build-deps -i debian/control`,
   `debuild -b -uc -us`), builds the gateway image (`podman build`), saves gateway +
   node_exporter images as tars. All into `/opt/artifacts` in-guest. Version-stamp file
   makes rebuilds skip when artifacts exist.
2. Vagrant trigger (after builder up): host pulls `/opt/artifacts` via
   `vagrant ssh builder -- sudo tar ...` into host `./artifacts/` (gitignored), then
   halts the builder.
3. Controller/compute read `/vagrant/artifacts/...` via the default synced folder
   (one-way host→guest is sufficient in this direction; works on VMware rsync and
   VirtualBox vboxsf alike).

## Salt design

- Salt 3008 LTS via salt-bootstrap (Broadcom-era repos; Vagrant fetches current
  bootstrap from GitHub with SHA256 check).
- Master: `auto_accept: True` — **assignment-mandated**; README documents why it's
  lab-only. (Reviewer's seed_master alternative rejected: contradicts the literal
  requirement.)
- Targeting: `role` grain (`builder`/`controller`/`compute`) in minion config; top.sls
  matches on it. All tunables in pillar: slurm version, IPs, ports, DB name/user/
  password, munge key (base64), UIDs, chart versions, grafana creds. No map.jinja
  (single-OS lab — deliberate, defensible).
- States: `podman/` (shared: pkg + config; controller adds Quadlet
  `node-exporter.container` + daemon-reload onchanges + service.running; **no**
  `enable: True` on generator units), `build/` (builder), `munge/` (shared key via
  `file.decode`/base64-from-pillar, 0600 munge:munge, /etc/munge 0700, service watch;
  hard `require` from slurm states — 26.05 demoted munge to a weak dep),
  `slurm/common` (user.present slurm with pillar UID **before** pkg install, slurm.conf
  from one Jinja template used by both nodes), `slurm/controller`
  (apt-get install ./slurm-smd{,-client,-slurmctld,-slurmdbd}*.deb guarded;
  slurmdbd.conf 0600 from pillar; service ordering mariadb→munged→slurmdbd→slurmctld;
  defensive `sacctmgr -i add cluster` with unless), `slurm/compute`
  (slurm-smd{,-client,-slurmd}; cgroup.conf + `TaskPlugin=task/cgroup,task/affinity`,
  `ProctrackType=proctrack/cgroup`; RealMemory derived from grains minus headroom —
  wrong value silently drains the node), `mariadb/` (pkg + service + idempotent SQL:
  CREATE DATABASE/USER IF NOT EXISTS + GRANT via unix_socket from a root-only rendered
  .sql file — Salt mysql_* states unusable: onedir Python can't see apt's pymysql),
  `k3s/` (installer with creates guard, `--node-ip 192.168.56.11 --flannel-iface eth1
  --write-kubeconfig-mode 644`; image tars linked into
  /var/lib/rancher/k3s/agent/images/ — K3s ≥1.31.5 auto-imports at runtime),
  `monitoring/` (helm CLI install; kps + gateway chart both via
  `helm upgrade --install --wait --timeout 15m`, guarded by
  `unless: helm status ... deployed` AND `onchanges` on chart/values files),
  `slurm/cron` (cron.present + job script + reporter).
- Idempotency verified at each phase boundary via `vagrant destroy -f && vagrant up`
  plus a second highstate expecting `changed=0`.

## Monitoring stack

kps values (chart ~88.x, keys verified):
- `grafana.adminUser/adminPassword: admin/admin` **from pillar**; README states creds.
- Ingress `grafana.local`, `ingressClassName: traefik`, TLS with no secretName →
  Traefik default self-signed cert (browser warning documented). Host needs
  `/etc/hosts: 192.168.56.11 grafana.local` — printed by a trigger, first in README.
- `additionalScrapeConfigs`: one `node-exporter` job, static targets `.10:9100` +
  `.11:9100`. Controller 9100 = Podman Quadlet node_exporter (assignment: controller
  only). Compute 9100 = kps node-exporter DaemonSet (hostNetwork) with its
  ServiceMonitor disabled (`prometheus-node-exporter.prometheus.monitor.enabled:
  false`) to avoid double-scrape. README defends this reading.
- Disabled: kubeEtcd, kubeScheduler, kubeControllerManager, kubeProxy (K3s doesn't
  expose them; avoids permanently-down targets). Retention 2h + resource limits on
  Prometheus (6GB node).
- Dashboards: **one mechanism** — vendored JSON (1860 "Node Exporter Full" pinned
  revision + custom "Live Slurm Job Load") as sidecar ConfigMaps
  (`grafana_dashboard: "1"`). Custom dashboard has `$job_id`/`$node` template vars via
  label_values.

## Metrics gateway (Phase 4)

- Python + Flask + prometheus_client **custom collector** over an in-memory dict keyed
  `(name, sorted(label_names))`; rejects PUTs whose label names conflict with
  first-seen set (400) and non-numeric values; entries expire (TTL ~2× scrape interval)
  so panels don't flatline after jobs end. Single worker only.
- `PUT /update-metric` `{ "name": ..., "value": ..., "labels": {...} }`; `/metrics`
  with CONTENT_TYPE_LATEST. Contains the assignment-mandated unused `import sys`, no
  comment; **no linter/CI in repo** (would flag F401); user explains it in interview.
- Containerfile built on builder; chart `charts/metrics-gateway/`: Deployment (pinned
  local tag, `imagePullPolicy: IfNotPresent`), Service (NodePort), **ServiceMonitor
  with the kps release label** — without it Prometheus never scrapes the gateway and
  Phase 5 is dead.

## Phase 5 loop

`cron.present` on controller: `*/5 * * * *` → `sbatch` job script. Interpretation
(documented in README): "running a Slurm job on the Controller node" = submitted from
controller; slurmd executes on compute (only consistent reading with Phase 1 roles).
Job: ~1 min, 12 iterations × 5s; each sends `PUT /update-metric` (curl) with simulated
cpu/gpu/mem gauge values labeled `slurm_job_id=$SLURM_JOB_ID`,
`node=$SLURMD_NODENAME` (documented sbatch env vars) to the gateway NodePort on .11.
Grafana custom panel graphs those series filtered by the template vars.

## Repo layout

```
Vagrantfile             Makefile              README.md
artifacts/ (gitignored) scripts/build.sh      scripts/verify.sh
gateway/ (app.py, Containerfile, requirements.txt, test_app.py)
charts/metrics-gateway/
salt/ states/ (top.sls, podman/, build/, munge/, slurm/, mariadb/, k3s/, monitoring/)
      pillar/ (top.sls, common.sls, secrets.sls)
dashboards/ (1860 vendored JSON, slurm-job-load.json)
docs/ (screenshots)     study/ (gitignored)
```

README: mermaid architecture diagram; prerequisites + install; `/etc/hosts` line;
`vagrant up` walkthrough with expected wall time; Grafana access + creds; verify.sh;
idempotency proof (pasted second-run `changed=0`); AI-usage section (explicitly
graded); known limitations & security notes (auto_accept, admin/admin, self-signed
cert, in-memory gateway state, unbounded label cardinality).

## Error handling & testing

- Highstate failures surface via `--retcode-passthrough` (Vagrant's master-mode path
  swallows them otherwise).
- `verify.sh`: sinfo/squeue node state IDLE, all Prometheus targets up, gateway
  /metrics responds, Grafana reachable; ~20 lines, greppable asserts.
- `gateway/test_app.py`: minimal — PUT then /metrics roundtrip, label-conflict 400,
  TTL expiry. No framework beyond pytest/stdlib.
- Phase boundaries: destroy/up from scratch + double highstate.

## Build order

Phase 0 (tools + Fusion static-IP smoke test) → Vagrantfile + builder (DEBs+images) →
controller salt core (munge, mariadb, slurm ctld/dbd) → compute slurm → K3s + kps →
gateway (+chart) → Phase 5 cron + dashboard → README/verify/screenshots → full clean
rebuild + idempotency proof.

## Known risks

1. Fusion on macOS 26 static-IP private networks (Phase 0 gate; VirtualBox fallback).
2. VMware rsync synced folders are up/reload-time only → README documents
   `vagrant rsync controller && vagrant provision <vm>` for state edits.
3. arm64 vs amd64: everything is built and consumed in-guest, so a reviewer on Intel
   rebuilds identical-named amd64 artifacts transparently.
