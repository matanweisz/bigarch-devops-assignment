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

