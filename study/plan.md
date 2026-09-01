> Historical implementation plan, frozen as written before implementation started.
> Where it differs from the code or the README, the code and README are
> authoritative; study/STATE.md records what actually changed and why.

# BigArch HPC-DevOps lab — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every worker reads `CLAUDE.md` and `study/design.md` first; CLAUDE.md's "locked decisions" and "traps" sections are binding.

**Goal:** `vagrant up` produces a 3-VM lab where a cron-driven Slurm job's simulated metrics appear live in Grafana via a custom gateway, K3s and kube-prometheus-stack, all configured by SaltStack.

**Architecture:** builder (masterless salt, compiles Slurm DEBs + gateway image, halts) -> controller (salt master+minion, slurmctld/slurmdbd/MariaDB/munge/Podman node_exporter) -> compute (minion, slurmd, K3s + kps + gateway). Artifacts: builder -> host via SSH tar trigger, host -> guests via rsync synced folder.

**Tech stack:** Vagrant 2.4.9 + VirtualBox 7.2 (vmware_desktop alt), bento/ubuntu-24.04 (pinned), Salt 3008 LTS, Slurm 26.05.x, MariaDB, Podman/Quadlet, K3s stable, kube-prometheus-stack ~88.x, Helm CLI, Python 3.12 + Flask + prometheus_client.

## Global constraints

- Net 192.168.56.0/24: builder .5 (4GB/6cpu), controller .10 (3GB/2cpu), compute .11 (6GB/4cpu).
- All synced folders `type: "rsync"`. No NFS ever (macOS nfsd panic).
- Master `auto_accept: True` (assignment-mandated; do not replace with seed_master).
- Controller provisioner: `install_master: true`, `run_highstate: false`; highstate via shell `salt-call state.highstate --retcode-passthrough`.
- Every tunable in pillar; targeting by `role` grain. No hardcoded values in states.
- Idempotency: second highstate = `changed=0`; no duplicate containers, no service restarts without cause.
- Gateway keeps unused `import sys`, no comment, no linters in repo.
- Image name everywhere: `localhost/metrics-gateway:1.0.0`. Gateway NodePort: `30080`.
- Kps release name `kps`, namespace `monitoring`. Grafana admin/admin from pillar.
- Slurm cluster name `bigarch`. Slurm user UID/GID `967`, munge UID/GID `966` (pillar).
- Artifact layout on host: `artifacts/debs/*.deb`, `artifacts/images/metrics-gateway.tar`, `artifacts/images/node-exporter.tar`, `artifacts/BUILD_STAMP` (contains slurm version + arch).
- Prose committed to the repo goes through the humanizer skill. No emoji, sentence-case headings.
- Commits: conventional, small, one per task step where meaningful (this repo has no ticket key; use `feat:`/`fix:`/`docs:` style).

---

### Task 1: Secrets generation + pillar/state skeleton

**Files:**
- Create: `scripts/gen-secrets.sh`, `salt/pillar/top.sls`, `salt/pillar/common.sls`, `salt/pillar/secrets.sls.example`, `salt/states/top.sls`
- Modify: `.gitignore` (add `salt/pillar/secrets.sls`)

**Interfaces (produced, used by all later tasks):**
- Pillar keys: `net:controller_ip` (192.168.56.10), `net:compute_ip` (192.168.56.11), `slurm:version` (26.05.3), `slurm:cluster_name` (bigarch), `slurm:uid` (967), `munge:uid` (966), `slurm:db:name` (slurm_acct_db), `slurm:db:user` (slurm), `gateway:image` (localhost/metrics-gateway:1.0.0), `gateway:node_port` (30080), `monitoring:namespace` (monitoring), `monitoring:release` (kps), `grafana:user`/`grafana:password` (admin/admin), `node_exporter:image` (docker.io/prom/node-exporter:v1.9.1), `node_exporter:port` (9100).
- Secrets pillar keys: `slurm:db:password`, `munge:key_b64`.
- `salt/states/top.sls` matches grain `role`: builder -> [podman, build], controller -> [podman, munge, mariadb, slurm.controller, node_exporter, slurm.cron], compute -> [munge, slurm.compute, k3s, monitoring].

- [ ] Write `scripts/gen-secrets.sh`: POSIX sh; if `salt/pillar/secrets.sls` missing, write it with `slurm:db:password` = `openssl rand -hex 16` and `munge:key_b64` = `openssl rand 128 | base64 | tr -d '\n'`; chmod 600; print "generated" or "exists". Copy structure into `secrets.sls.example` with placeholder values and a one-line comment saying gen-secrets.sh creates the real one.
- [ ] Write the pillar files with the exact keys above; `pillar/top.sls` serves common + secrets to `*`.
- [ ] Run `sh scripts/gen-secrets.sh` twice; second run must not rewrite the file (compare mtime). Run `salt-call --local --config-dir=/dev/null slt` is not available on host: instead validate YAML with `python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('salt/pillar/*.sls')+['salt/states/top.sls']]"` (jinja-free files only).
- [ ] Commit.

### Task 2: Metrics gateway app (pure Python, host-testable)

**Files:**
- Create: `gateway/app.py`, `gateway/requirements.txt`, `gateway/test_app.py`, `gateway/Containerfile`

**Interfaces (produced):**
- `PUT /update-metric` accepts JSON `{"name": str, "value": number, "labels": {str: str}}` -> 204; 400 on bad name/value/label-name-set conflict; 405 on other methods.
- `GET /metrics` -> Prometheus text format, `CONTENT_TYPE_LATEST`.
- Entries expire after `METRIC_TTL_SECONDS` (env, default 300) — checked at scrape time.
- App listens on `0.0.0.0:8080` (env `PORT`). Container runs `python app.py` (single process, Flask builtin server is acceptable for this lab; note in README limitations).

- [ ] Write `gateway/requirements.txt`: `flask` and `prometheus-client` pinned to current versions (check pypi at implementation time).
- [ ] Write `gateway/test_app.py` first (pytest, Flask test client): PUT then /metrics roundtrip contains `slurm_job_cpu_percent{...} 42.0`; PUT with conflicting label names for same metric -> 400; PUT non-numeric value -> 400; metric name failing `^[a-zA-Z_:][a-zA-Z0-9_:]*$` -> 400; monkeypatched clock past TTL -> series gone from /metrics.
- [ ] Run `cd gateway && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt pytest && .venv/bin/pytest -q` — must fail (no app yet). Add `gateway/.venv` to `.gitignore`.
- [ ] Write `gateway/app.py`: `import sys` among imports (no comment — assignment instruction); store `{(name, tuple(sorted(labels))): (value, labels, timestamp)}` plus a `{name: frozenset(label_names)}` registry; custom collector yields `GaugeMetricFamily` per name with label values, skipping expired entries; Flask routes as above. Target ~80 lines.
- [ ] Pytest green. Commit.
- [ ] Write `Containerfile`: `FROM docker.io/python:3.12-slim`, copy requirements + install, copy app.py, non-root user, `EXPOSE 8080`, `CMD ["python", "app.py"]`. (Build happens on the builder VM in Task 3 — do not build on the host.) Commit.

### Task 3: Vagrantfile + builder (DEBs + images land on host)

**Files:**
- Create: `Vagrantfile`, `scripts/build.sh`, `salt/states/podman/init.sls`, `salt/states/build/init.sls`, `salt/minion.d/` configs as needed
- Modify: `.gitignore` (`.vagrant/` already there)

**Interfaces (consumed):** pillar keys from Task 1, `gateway/` from Task 2.
**Interfaces (produced):** host `artifacts/` layout per global constraints; `podman/init.sls` reused verbatim by controller in Task 4.

- [ ] Write `Vagrantfile`: box + pinned version; three defines in order builder/controller/compute; static IPs; rsync synced folders (repo root -> /vagrant); per-VM virtualbox + vmware_desktop provider blocks with the RAM/CPU table; `config.trigger.before :up` (global) runs `scripts/gen-secrets.sh`.
  - builder: salt provisioner `masterless: true`, `minion_id: builder`, custom minion config setting `grains: {role: builder}` and local file/pillar roots at `/vagrant/salt/states`, `/vagrant/salt/pillar`; `run_highstate: true`; `bootstrap_options` pinning stable 3008. Trigger `after :up` scoped inside the builder define: host runs `vagrant ssh builder -c 'sudo tar -C /opt/artifacts -cf - .' -- -T > artifacts.tar && mkdir -p artifacts && tar -xf artifacts.tar -C artifacts && rm artifacts.tar`, then `vagrant halt builder`.
  - controller: precondition trigger `before :provision` aborts with clear message unless `artifacts/BUILD_STAMP` exists; salt provisioner `install_master: true`, master config `salt/master` (`auto_accept: True`, file/pillar roots `/vagrant/salt/...`), minion config pointing at 127.0.0.1 with `grains: {role: controller}`, `run_highstate: false`; then shell provisioner `salt-call state.highstate --retcode-passthrough --state-output=mixed`.
  - compute: same precondition; salt provisioner minion -> 192.168.56.10, `grains: {role: compute}`, `run_highstate: true`.
- [ ] Write `salt/states/podman/init.sls`: `pkg.installed: podman` + `file.directory: /etc/containers/systemd`. Nothing controller-specific here (the exporter Quadlet lives in `node_exporter/init.sls`, Task 4) — this shared sls is exactly what the assignment's "Podman on Controller and Builder" bullet needs.
- [ ] Write `scripts/build.sh` (invoked by build state, runs as root on builder): exit 0 early if `/opt/artifacts/BUILD_STAMP` matches pillar slurm version+arch; apt-get install build-essential fakeroot devscripts equivs wget; wget slurm tarball from download.schedmd.com (version from env `SLURM_VERSION`); `mk-build-deps -i debian/control -t 'apt-get -y'`; `debuild -b -uc -us` with `DEB_BUILD_OPTIONS=parallel=$(nproc)`; copy `../slurm-smd*.deb` to /opt/artifacts/debs/; `podman build -t localhost/metrics-gateway:1.0.0 /vagrant/gateway && podman save -o /opt/artifacts/images/metrics-gateway.tar localhost/metrics-gateway:1.0.0`; `podman pull docker.io/prom/node-exporter:v1.9.1 && podman save -o /opt/artifacts/images/node-exporter.tar ...`; write BUILD_STAMP last.
- [ ] Write `salt/states/build/init.sls`: `file.managed` build.sh from `salt://` (or run from /vagrant), `cmd.run` with env `SLURM_VERSION` from pillar, `creates: /opt/artifacts/BUILD_STAMP` guard is wrong (stamp checked inside script for version match) — use `unless: grep -qx "$(pillar)-$(dpkg --print-architecture)" /opt/artifacts/BUILD_STAMP`.
- [ ] Run `vagrant validate`, then `vagrant up builder`. Expect ~10-20 min. Verify on host: `ls artifacts/debs/*.deb | wc -l` >= 8, both image tars exist, `vagrant status builder` = poweroff.
- [ ] Re-run `vagrant up builder`: build must skip (stamp), trigger re-pulls, still halts. Commit.

### Task 4: Controller Salt core (munge, MariaDB, Slurm ctld+dbd, node_exporter)

**Files:**
- Create: `salt/states/munge/init.sls`, `salt/states/mariadb/init.sls`, `salt/states/slurm/common.sls`, `salt/states/slurm/controller.sls`, `salt/states/slurm/files/slurm.conf.j2`, `salt/states/slurm/files/slurmdbd.conf.j2`, `salt/states/slurm/files/cgroup.conf`, `salt/states/node_exporter/init.sls`, `salt/states/node_exporter/files/node-exporter.container.j2`, `salt/master`
- Test: live verification on the VM (no unit framework for SLS; the highstate + checks below are the test)

**Interfaces (consumed):** artifacts/debs, podman sls, pillar keys.
**Interfaces (produced):** `slurm/common.sls` + templates reused by compute (Task 5); munge sls reused by compute.

Key content requirements (from CLAUDE.md traps): munge key via `file.decode` from `munge:key_b64` + `/etc/munge` 0700 + key 0600 munge:munge + service watch; users `slurm`/`munge` with pillar UIDs created before any pkg install; DEBs via `cmd.run apt-get install -y /vagrant/artifacts/debs/slurm-smd_* ...-client_* ...-slurmctld_* ...-slurmdbd_*` guarded by `unless: dpkg-query -W slurm-smd-slurmctld`; slurm.conf.j2 single template for both roles (SlurmctldHost from pillar, NodeName line with `CPUs`/`RealMemory={{ (grains['mem_total'] * 0.85) | int }}` computed on compute, `State=UNKNOWN`, `ReturnToService=2`, `SelectType=select/cons_tres`, `ProctrackType=proctrack/cgroup`, `TaskPlugin=task/cgroup,task/affinity`, `AccountingStorageType=accounting_storage/slurmdbd`); slurmdbd.conf 0600 slurm:slurm; mariadb: pkg+service, innodb buffer drop-in, idempotent SQL file (0600 root) + `cmd.run mysql < file` with unless-user-exists guard; service chain mariadb -> munged -> slurmdbd -> slurmctld via require/watch; defensive `sacctmgr -i add cluster` with unless; node_exporter Quadlet unit (`Image=` from pillar via the loaded tar? controller loads `podman load -i /vagrant/artifacts/images/node-exporter.tar` guarded by `unless: podman image exists`; `Network=host`), daemon-reload `onchanges`, `service.running` WITHOUT `enable: True`.

- [ ] Write all files above. `salt/master`: `auto_accept: True`, `file_roots: {base: [/vagrant/salt/states]}`, `pillar_roots: {base: [/vagrant/salt/pillar]}`.
- [ ] `vagrant up controller` (builder artifacts already on host). Expect highstate green.
- [ ] Verify on VM: `systemctl is-active slurmctld slurmdbd mariadb munge node-exporter` all active; `curl -s localhost:9100/metrics | head -1` works; `sacctmgr -nP show cluster` shows `bigarch`; `sinfo` runs (compute node shown down — expected, no compute yet); `mysql slurm_acct_db -e 'show tables' | head` non-empty.
- [ ] Idempotency: `vagrant ssh controller -c 'sudo salt-call state.highstate' | tail -20` -> `changed=0`, `podman ps` shows exactly one node-exporter. Commit.

### Task 5: Compute Slurm (end-to-end job runs)

**Files:**
- Create: `salt/states/slurm/compute.sls`
- Modify: none (reuses munge, slurm/common, templates)

**Interfaces (produced):** working `srun`/`sbatch` from controller to compute.

- [ ] Write `compute.sls`: users + munge (require), DEB install (`slurm-smd`, `-client`, `-slurmd`) guarded as in Task 4, cgroup.conf, slurmd service watching slurm.conf/munge key.
- [ ] `vagrant up compute`. Verify minion key auto-accepted (`vagrant ssh controller -c 'sudo salt-key -l acc'` lists compute), highstate green.
- [ ] Verify from controller: `sinfo` shows node idle; `srun -N1 hostname` returns `compute`; `sbatch --wrap 'sleep 1' && sacct -X --format=JobID,State | tail` shows COMPLETED.
- [ ] Idempotency: second highstate on compute `changed=0`. Commit.
- [ ] Checkpoint: full `vagrant destroy -f && vagrant up` from clean clone state must reach this same verified state unattended. Fix anything that only worked incrementally. Commit fixes.

### Task 6: K3s + kube-prometheus-stack + dashboards

**Files:**
- Create: `salt/states/k3s/init.sls`, `salt/states/monitoring/init.sls`, `salt/states/monitoring/files/kps-values.yaml.j2`, `dashboards/node-exporter-full-1860.json` (vendored, pinned revision), `dashboards/slurm-job-load.json` (placeholder panels refined in Task 8), `salt/states/monitoring/files/dashboards-configmap.yaml.j2`

**Interfaces (consumed):** pillar monitoring/grafana/net keys.
**Interfaces (produced):** reachable https://grafana.local (via /etc/hosts -> .11), Prometheus with `node-exporter` job scraping .10:9100 and .11:9100.

- [ ] `k3s/init.sls`: `cmd.run` get.k3s.io installer with `INSTALL_K3S_EXEC="--node-ip {{ compute_ip }} --flannel-iface eth1 --write-kubeconfig-mode 644"`, `creates: /usr/local/bin/k3s`; copy gateway image tar into `/var/lib/rancher/k3s/agent/images/` (file.managed from /vagrant/artifacts, K3s auto-imports); helm binary via upstream install script `creates: /usr/local/bin/helm`.
- [ ] `kps-values.yaml.j2` exactly per spec: grafana creds from pillar, ingress grafana.local + ingressClassName traefik + tls (no secretName), sidecar dashboards enabled, additionalScrapeConfigs job `node-exporter` -> both IPs from pillar, `prometheus-node-exporter.prometheus.monitor.enabled: false`, kubeEtcd/kubeScheduler/kubeControllerManager/kubeProxy disabled, retention 2h, prometheus resources limits (1Gi).
- [ ] `monitoring/init.sls`: namespace via `kubectl create ns --dry-run=client -o yaml | kubectl apply -f -` pattern or helm `--create-namespace`; dashboards ConfigMaps (label `grafana_dashboard: "1"`) applied via `kubectl apply -f` from rendered file (idempotent); `helm repo add prometheus-community ... ; helm upgrade --install kps prometheus-community/kube-prometheus-stack --version <pin current 88.x> -n monitoring -f values --wait --timeout 15m` with `unless: helm status kps -n monitoring | grep -q deployed` + `onchanges` on rendered values file.
- [ ] Vendor dashboard 1860 JSON: download current revision at implementation time, commit the file, set its datasource input to the default Prometheus datasource per grafana sidecar convention.
- [ ] Provision compute; verify: `kubectl get nodes` Ready; `kubectl -n monitoring get pods` all Running; port-forward or exec: Prometheus `/api/v1/targets` shows node-exporter job with both targets up and zero targets down overall; `curl -sk https://192.168.56.11 -H 'Host: grafana.local'` returns Grafana login redirect.
- [ ] From the mac: add `/etc/hosts` line, open https://grafana.local, log in admin/admin, confirm 1860 dashboard shows both nodes. Screenshot to `docs/grafana-node-exporter.png`.
- [ ] Idempotency: second highstate `changed=0`. Commit.

### Task 7: Gateway Helm chart + deploy

**Files:**
- Create: `charts/metrics-gateway/Chart.yaml`, `values.yaml`, `templates/deployment.yaml`, `templates/service.yaml`, `templates/servicemonitor.yaml`, `templates/_helpers.tpl`
- Modify: `salt/states/monitoring/init.sls` (second helm release, same guard pattern)

**Interfaces (consumed):** image `localhost/metrics-gateway:1.0.0` (imported in Task 6), NodePort 30080, release label `kps`.
**Interfaces (produced):** `http://192.168.56.11:30080/update-metric` reachable from both VMs; gateway scraped by Prometheus (job visible in targets).

- [ ] Write the chart: Deployment (1 replica, `imagePullPolicy: IfNotPresent`, image from values, PORT env, liveness `GET /metrics`), Service (NodePort 30080), ServiceMonitor (`metadata.labels.release: kps`, endpoint port + 15s interval). `helm lint charts/metrics-gateway` clean.
- [ ] Salt: `helm upgrade --install metrics-gateway /vagrant/charts/metrics-gateway -n monitoring --wait` with same unless/onchanges guard.
- [ ] Provision; verify: pod Running with imported image (not pulled); `curl -X PUT .11:30080/update-metric -d '{"name":"test_metric","value":1,"labels":{"a":"b"}}' -H 'content-type: application/json'` -> 204; `curl .11:30080/metrics` shows it; Prometheus targets show gateway up; after TTL it disappears.
- [ ] Idempotency check, commit.

### Task 8: Phase 5 loop (cron + sbatch job + live dashboard)

**Files:**
- Create: `salt/states/slurm/cron.sls`, `salt/states/slurm/files/simulate_metrics.sbatch.j2`, `salt/states/slurm/files/submit_job.sh.j2`
- Modify: `dashboards/slurm-job-load.json` (real panels)

**Interfaces (consumed):** gateway URL from pillar (`http://{{ compute_ip }}:{{ node_port }}`), sbatch from Task 5.

- [ ] `simulate_metrics.sbatch.j2`: `#SBATCH --job-name=metrics-sim --time=00:02:00`; loop 12 iterations, `sleep 5` between; each iteration curls three PUTs (`slurm_job_cpu_percent`, `slurm_job_gpu_percent`, `slurm_job_mem_mb`) with `$RANDOM`-derived values and labels `{"slurm_job_id":"$SLURM_JOB_ID","node":"$SLURMD_NODENAME"}`. Values plausible (cpu 20-100, gpu 0-100, mem 100-2000).
- [ ] `submit_job.sh` wrapper: `sbatch /opt/slurm/simulate_metrics.sbatch` (cron PATH is minimal — absolute paths). `cron.present` for root: `*/5 * * * *`, identifier so re-runs don't duplicate.
- [ ] Highstate controller; wait for next 5-min boundary (or run submit_job.sh manually); verify: `sacct` shows job COMPLETED; Prometheus query `slurm_job_cpu_percent` returns series with job id and node labels.
- [ ] Finalize `dashboards/slurm-job-load.json`: title "Live Slurm Job Load"; template vars `$job_id` = `label_values(slurm_job_cpu_percent, slurm_job_id)`, `$node` = `label_values(slurm_job_cpu_percent, node)`; timeseries panels for cpu/gpu/mem filtered by both vars; stat panel with latest values. Re-apply ConfigMap, verify in Grafana, screenshot to `docs/grafana-slurm-job-load.png`.
- [ ] Idempotency (`crontab -l` has exactly one entry after two highstates), commit.

### Task 9: verify.sh, Makefile, README, final proof

**Files:**
- Create: `scripts/verify.sh`, `Makefile`, `README.md`
- Modify: none

- [ ] `scripts/verify.sh` (~30 lines, runs from host): vagrant status (builder poweroff, others running); `vagrant ssh controller -c 'sinfo -h -o %T'` contains idle/alloc; controller and compute 9100 respond; gateway PUT+GET roundtrip; Prometheus targets API: no target down; prints Grafana URL + /etc/hosts reminder. Exit non-zero on any failure.
- [ ] `Makefile`: `up`, `verify`, `provision` (rsync+provision controller/compute), `destroy`. Four targets, nothing clever.
- [ ] `README.md` (humanizer pass; structure): what this is + mermaid diagram; prerequisites (VirtualBox or VMware, Vagrant, ~13GB RAM free, tested macOS arm64 + Ubuntu amd64); quick start (`vagrant up`, expected wall time, the /etc/hosts line, Grafana URL + admin/admin, browser cert warning note); verify.sh; how the pieces work (per phase, short); design decisions and interpretations (job submitted from controller runs on compute; node-exporter split between podman and DaemonSet; auto_accept scope); idempotency proof (paste real second-highstate summaries); AI use section (tools used, what was generated vs decided, reference to CLAUDE.md, the import sys instruction acknowledged); known limitations (auto_accept, admin/admin, self-signed cert, in-memory gateway, Flask dev server single worker); screenshots.
- [ ] Full clean-room proof: `vagrant destroy -f`, move `artifacts/` aside, fresh `vagrant up`, run `make verify`, wait one cron cycle, check dashboard. Paste timings + outputs into README.
- [ ] Run review agents (code-reviewer + compliance re-check against assignment text) on the full repo; fix findings.
- [ ] Commit; hand to Matan for GitHub repo creation + push (his account, his OK).

## Self-review notes

- Spec coverage: every assignment phase maps to tasks (P1: 3; P2: 1,3,4,5; P3: 6; P4: 2,7; P5: 8; submission criteria: 9 + conventions).
- Type/name consistency: image tag, NodePort, release name, pillar keys defined once in global constraints and referenced by name everywhere.
- Testing: gateway has pytest; SLS "tests" are the listed live verification commands plus the double-highstate and clean-room rules — appropriate for IaC without adding a test framework the assignment doesn't ask for.
