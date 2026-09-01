# Tool and design decisions, with the reasoning

One entry per decision: what we picked, why, what else was on the table. Read this
before the interview; every entry is a likely question.

## Virtualization provider: VirtualBox

Free, and the only provider that runs this project on the Apple Silicon Mac (arm64),
an Ubuntu laptop (amd64), and any reviewer machine with one Vagrantfile. Static-IP
host-only networks are its native, predictable behavior, and 192.168.56.0/24 is inside
its default allowed range. Alternatives: VMware Fusion (free but needs a Broadcom
account, has a known static-IP limitation on modern macOS, and adds nothing on Linux),
Parallels (paid, Mac only), QEMU/libvirt (free but community plugins and manual
networking). A vmware_desktop provider block stays in the Vagrantfile as an option.
Smoke-tested on 2026-08-31: arm64 box boots, static IP works, host can reach the VM.

## Vagrant box: bento/ubuntu-24.04, version pinned

Bento publishes the same box for virtualbox and vmware on both arm64 and amd64, so
each machine transparently gets the right build. Ubuntu 24.04 is an officially
supported Slurm build platform and has current Salt and K3s support. The old
`generic/*` boxes are stale (404s), and `ubuntu/*` cloud images stopped at 22.04 for
VirtualBox. Pinning the version keeps the deployment reproducible.

## Synced folders: rsync type everywhere, artifacts pulled over SSH

Declaring `type: "rsync"` gives identical one-way host-to-guest behavior on every
provider and host OS, and avoids VirtualBox's arm64 guest-additions quirks entirely.
The builder's output goes the other direction, so a Vagrant trigger pulls
`/opt/artifacts` to the host with `vagrant ssh ... tar`. NFS was the obvious
bidirectional answer and is explicitly ruled out: macOS 15.4+ has an unfixed nfsd
kernel panic that Vagrant reliably triggers. vboxsf would tie us to one provider.

## Configuration management: Salt 3008 LTS, master/minion with auto-accept

Master/minion topology and auto-accept are assignment requirements, not choices. What
we chose: Salt 3008 (current LTS, arm64 onedir packages exist), and keeping
`auto_accept: True` even though pre-seeded keys (`seed_master`) would be safer,
because the assignment mandates auto-accept by name. The security trade-off is
documented in the README instead of silently "fixed". Worth knowing: Vagrant refuses
`install_master` combined with `run_highstate` unless keys are pre-seeded, so the
controller runs its highstate through a follow-up `salt-call` shell step, which also
propagates failures properly (the provisioner's own master-mode path does not).

## Builder provisioning: the salt provisioner in masterless mode

The assignment files "Podman on Controller and Builder" under Salt states, but the
builder boots before the master exists. Masterless `salt-call` applies the same
`podman` state locally with no master dependency. One state file, two consumers,
which is exactly what the no-duplication criterion wants to see. The alternative,
installing podman from the build shell script, would have duplicated logic and missed
the ".sls" wording.

## Data in pillar, targeting by grain, no map.jinja

Pillar is master-held and delivered per-minion over an encrypted channel, so secrets
(DB password, munge key) and all tunables live there. Grains are minion-reported
facts, fine for role targeting, never for secrets. map.jinja, the classic Salt
formula idiom, exists to abstract differences between operating systems; with one OS
across three nodes it would be ceremony, and over-abstraction reads as a negative in
a hiring review.

## Munge key: random bytes, kept as base64 text from pillar to keyfile

Munge needs an identical secret key on every node. We generate 128 random bytes once
on the host (gen-secrets script), store them base64-encoded in a gitignored pillar
file, and write that base64 text verbatim to /etc/munge/munge.key (0600) with
`file.managed` + `contents_pillar`. munged treats the keyfile as opaque bytes, so
the text form carries the same entropy as the decoded binary. The original plan
decoded on the node with `file.decode`, but Salt 3008 masks pillar values at the
pillar.get module boundary and only lifts the mask for template renderers and
file.managed — file.decode receives `**********`, silently discards it as invalid
base64, and writes an empty key (confirmed live against 3008.2). Committing a real
key to git would be a red flag even in a lab, so the pillar file stays gitignored.

## MariaDB setup: idempotent SQL instead of Salt's mysql states

Salt's `mysql_database`/`mysql_user` states need a Python MySQL driver importable by
Salt's own interpreter. Salt 3008 ships as onedir (bundled Python) which cannot see
apt-installed packages, and installing drivers with salt-pip is fragile. Plain
`CREATE DATABASE IF NOT EXISTS` / `CREATE USER IF NOT EXISTS` / `GRANT` over the unix
socket, rendered from pillar into a root-only file, is idempotent, transparent, and
has no dependencies. MariaDB root stays on unix_socket auth, so no root password
exists to manage.

## Slurm: 26.05.x built as DEBs with the official Debian flow

Building from source is mandated. SchedMD ships a `debian/` directory in the tarball;
`mk-build-deps -i debian/control` then `debuild -b -uc -us` produces the separated
`slurm-smd-*` packages the assignment asks for. The version is pinned in pillar for
reproducibility ("latest" at the time we built; bump one pillar value to upgrade).
Installs use `apt-get install ./*.deb`, not `dpkg -i`, because apt resolves the
inter-package dependencies and because Slurm 26.05 demoted munge to a weak dependency
that dpkg would skip.

## Containers on the VMs: Podman with Quadlet units

Podman is mandated. For running node_exporter idempotently we write a Quadlet
`.container` file and let systemd manage the service. Salt has no native podman
state; `podman generate systemd` is deprecated upstream; raw `podman run` from
cmd.run duplicates containers on re-runs, which is a named grading criterion. A
Quadlet unit is declarative: re-running highstate changes nothing unless the file
changed.

## Kubernetes: K3s single node, with two non-default flags

K3s is mandated. The flags matter: `--node-ip 192.168.56.11 --flannel-iface eth1`
pin it to the private network (Vagrant's first interface is NAT, and K3s would
otherwise bind that), and `--write-kubeconfig-mode 644` makes kubectl usable without
sudo. Bundled Traefik stays enabled because the Grafana ingress uses it.

## Helm deployments: helm CLI for both charts

`helm upgrade --install` is idempotent by design (converges instead of re-executing)
and "via Helm" is the literal assignment wording. The K3s HelmChart CRD was the
tempting alternative (no helm binary, self-reconciling) but handles a local unpacked
chart badly, and using it for one chart and the CLI for the other means two
mechanisms for one job. Guarding the command with both a release-status check and
`onchanges` on the values file keeps reruns clean and still retries a failed first
install.

## kube-prometheus-stack configuration choices

Four scrape targets are disabled (etcd, scheduler, controller-manager, kube-proxy)
because K3s does not expose them and permanently red targets look sloppy. The chart's
node-exporter DaemonSet stays on, serving compute's :9100, while the controller's
:9100 comes from the mandated Podman container; `additionalScrapeConfigs` scrapes
both by static IP, satisfying the assignment's "both nodes" wording, and the
DaemonSet's ServiceMonitor is disabled so compute isn't scraped twice. Retention is
2h with resource limits, sized for a 6GB VM.

## Grafana: admin/admin, vendored dashboards, Traefik's default certificate

"Default user/password" is read as Grafana's own default (admin/admin), set from
pillar and stated in the README, because a reviewer will try that first. Both
dashboards (Node Exporter Full 1860 and the custom Slurm panel) are committed as JSON
and provisioned as sidecar ConfigMaps; the alternative `gnetId` mechanism downloads
from grafana.com at every pod start, which breaks offline and isn't reproducible.
HTTPS works through Traefik's built-in self-signed fallback certificate, so
cert-manager would be pure overhead; the browser warning is documented.

## Metrics gateway: Flask plus prometheus_client custom collector

Flask is the smallest mainstream way to get the two required endpoints; the
prometheus_client library guarantees correct exposition format, and a ~20-line custom
collector renders arbitrary metric names and labels from an in-memory dict.
Alternatives: FastAPI (async and pydantic buy nothing here), raw http.server (fewer
deps but hand-rolled text format is where correctness bugs live). Entries expire so
the dashboard doesn't show dead jobs as flat lines, the store is keyed to reject
inconsistent label sets (invalid exposition otherwise), and it runs single-process
because the dict lives in one process's memory. The unused `import sys` is an
explicit assignment instruction, kept without comment as instructed.

## Phase 5: system cron submitting sbatch, not a Kubernetes CronJob

`SLURM_JOB_ID` and `SLURMD_NODENAME` only exist inside a Slurm-launched process, so
the simulation must be a real Slurm job. Cron on the controller submits with sbatch
every five minutes; slurmd executes the job on compute, which is the only reading
consistent with the assignment putting slurmd on compute. The job loops twelve times
at five-second intervals, PUTting simulated cpu/gpu/mem values to the gateway's
NodePort with the job id and node name as labels.
