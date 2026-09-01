# Session state — updated 2026-09-01 (Ubuntu laptop)

Where the project stands, for resuming in another session.

## Where we are

All nine tasks of study/plan.md are implemented, reviewed, and live-verified on the
Ubuntu amd64 laptop. The working branch is `impl`; the ledger in
`.superpowers/sdd/plan/progress.md` records every task, review round, and fix.

The clean-room proof passed on 2026-09-01: `vagrant destroy -f`, artifacts moved
aside, one unattended `vagrant up` rebuilt everything (builder compiled 17 DEBs and
both images, controller highstate 35/0, compute 36/0), `make verify` all green
(15 Prometheus targets, 0 down), and second highstates on both nodes report
changed=0. The Phase 5 loop is live: cron fires every five minutes, metrics-sim
jobs run on compute, and all three slurm_job_* series land in Prometheus with the
slurm_job_id and node labels.

## What changed relative to the original design

- The munge key is written as base64 text via file.managed, not decoded with
  file.decode: Salt 3008 masks pillar values at the pillar.get boundary and
  file.decode was missed in the upstream retrofit, so it writes a zero-byte key.
  Documented in CLAUDE.md traps, decisions.md, and the README.
- The Helm release guards are a single unless comparing a content stamp
  (values + chart hash + chart version), not unless+onchanges — the pair is an
  AND in Salt and would skip upgrades and never retry failed installs.
- Dashboard ConfigMaps are applied with kubectl apply --server-side: the 469KB
  1860 dashboard exceeds the 256KB last-applied-configuration annotation cap.
- The K3s flannel interface is derived from the NIC holding the compute IP at
  render time (pillar override available), not hardcoded to eth1.
- The gateway TTL (90s) flows from pillar through the chart into
  METRIC_TTL_SECONDS, so dashboards go quiet between five-minute cron cycles.
- Artifact paths derive from pillar artifacts:root.

## Remaining before submission (all need Matan)

1. Screenshots: docs/grafana-node-exporter.png and docs/grafana-slurm-job-load.png
   are referenced by the README but not yet taken. Host /etc/hosts line
   `192.168.56.11 grafana.local`, then https://grafana.local, admin/admin.
2. Publishing: main is far behind impl and impl is unpushed. Decide the shape of
   the published history.
3. History hygiene decisions, unchanged from the Mac snapshot: the two main
   commits carrying the ZoomInfo author email, and whether study/,
   .superpowers/, and bigarch-assignment.md stay in the published repo
   (currently tracked; the .gitignore entries only stop new additions).
   `git rm -r --cached study .superpowers bigarch-assignment.md` on a submission
   branch is the minimal-surgery option; CLAUDE.md stays either way.

## Environment notes for this laptop

- VirtualBox 7.2.6 (apt) + Vagrant 2.4.9 (.deb). KVM modules coexist fine with
  VirtualBox here (kernel 7.0); /etc/modprobe.d/blacklist-kvm.conf exists anyway.
- Incremental state edits: `make provision` (rsync both, highstate both). The
  master serves states from the controller's /vagrant, so forgetting the
  controller rsync yields "No matching sls found" on compute.
