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

