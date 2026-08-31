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

