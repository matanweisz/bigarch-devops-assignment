# Task 3 report: Vagrantfile + builder VM

Status: **DONE**

## What was built

| File | Purpose |
|---|---|
| `Vagrantfile` | Three defines (builder/controller/compute), pinned box, static IPs, rsync shares, provider blocks, triggers |
| `scripts/build.sh` | Runs as root on the builder: Slurm DEBs + gateway image + node_exporter image into `/opt/artifacts` |
| `scripts/pull-artifacts.sh` | Host side: streams `/opt/artifacts` back over SSH, verifies the tar, powers the builder off |
| `salt/states/podman/init.sls` | `podman` package + `/etc/containers/systemd` — shared by builder and controller |
| `salt/states/build/init.sls` | Wraps `build.sh` with pillar-supplied env and the version-stamp guard |
| `salt/minion.builder.conf` | Masterless minion: `file_client: local`, roots at `/vagrant/salt/...`, `role: builder` grain |
| `salt/minion.controller.conf` | `master: 127.0.0.1`, `role: controller` grain |
| `salt/minion.compute.conf` | `master: 192.168.56.10`, `role: compute` grain |
| `salt/master.conf` | `auto_accept: True`, file/pillar roots at `/vagrant/salt/...` |

`.gitignore` needed no change: `artifacts/` and `.vagrant/` were already listed.

### Design notes

- **Pillar is parsed from Ruby.** `PILLAR = YAML.load_file("salt/pillar/common.sls")` gives the
  Vagrantfile the controller and compute addresses, so host networking cannot drift from what the
  states configure. RAM/CPU and the builder's `.5` stay as Ruby constants: no state reads them, and
  the builder is ephemeral so nothing in-guest addresses it.
- **Salt 3008.** `install_type = "stable"` + `install_args = "3008"` are appended verbatim to the
  bootstrap command line (`plugins/provisioners/salt/provisioner.rb:175-181`), which is exactly
  salt-bootstrap's positional `stable <major>` selector. Observed:
  `Using Bootstrap Options:  -F -c /tmp stable 3008` → `install_ubuntu_onedir` on aarch64/noble.
- **`--retcode-passthrough` is already in Vagrant's masterless highstate path**
  (`provisioner.rb:441`), so a failed state fails the provisioner without extra config.
  `salt_call_args = ["--state-output=mixed"]` and `log_level = "info"` are for readability only —
  Vagrant otherwise defaults salt-call to `--log-level=debug` (`provisioner.rb:219`).
- **Build guard lives in two places on purpose.** The state's `unless` compares the pillar version
  against `/opt/artifacts/BUILD_STAMP`; `build.sh` repeats the check so it is safe to run by hand.
  `creates:` was rejected: it would skip a rebuild after a pillar version bump.
- **`debuild --no-lintian`.** Plain `debuild -b -uc -us` runs lintian, which exits non-zero on
  packaging style warnings we do not control and would discard a five-minute compile over them.
- **BUILD_STAMP is written last** so it means "everything above succeeded" — which is what both the
  Salt guard and the controller/compute precondition trust.

## Traps hit and fixed

1. **`salt/master` collides with Vagrant's `OPTIMISTIC_PATH_DEFAULTS`**
   (`provisioner.rb:14-22`): a file at that exact path is auto-adopted as `master_config` for
   *every* machine. The first run logged `Copying salt master config to vm.` on the **builder**.
   Fixed by naming the files `salt/master.conf` / `salt/minion.<role>.conf` and referencing them
   explicitly.
2. **Host `run` triggers get no shell.** Vagrant `Shellwords.split`s an inline host command and
   execs it (`lib/vagrant/plugin/v2/trigger.rb:237-244`), so `>` would have been passed to `tar`
   as a literal argument. The artifact pull had to be a script (`t.run = { path: ... }`), not an
   inline command.
3. **`vagrant halt builder` inside the builder's own `after :up` trigger is refused.** The `up`
   action still holds that machine's lock while its trigger runs:
   > An action 'halt' was attempted on the machine 'builder', but another process is already
   > executing an action on the machine.

   The first end-to-end run produced every artifact correctly and then exited 1 on exactly this.
   Fixed by powering off from inside the guest (`sudo systemctl poweroff --no-block`) plus a
   bounded poll on `vagrant status --machine-readable` so `vagrant status` is deterministic for
   whatever runs after `vagrant up`. (Nested read-only `vagrant ssh`/`vagrant status` are fine —
   only machine *actions* take the lock.)
4. **A bare `raise` in a `t.ruby` trigger prints a Ruby backtrace over the message.** Changed to
   `abort`, which prints just the message and exits 1.

## Verification

All commands run from the repo root on the Apple Silicon host, VirtualBox 7.2.16, Vagrant 2.4.9,
box `bento/ubuntu-24.04` v202510.26.0 (arm64).

### 1. `vagrant validate`

```
$ vagrant validate
Vagrantfile validated successfully.
```

### 2. Cold end-to-end — `vagrant destroy -f builder && rm -rf artifacts && vagrant up builder`

**426s wall clock, exit 0.**

```
Succeeded: 3 (changed=2)
Failed:    0
Total states run:     3
Total run time: 317.346 s
```

Per-state (from the same run's mixed output):

```
Name: podman                    - Function: pkg.installed  - Result: Changed
Name: /etc/containers/systemd   - Function: file.directory - Result: Clean
Name: bash /vagrant/scripts/build.sh - Function: cmd.run   - Result: Changed - Duration: 312618 ms
```

The build guard fired correctly on the cold run:

```
[INFO ] Executing command 'grep' in directory '/root'
[DEBUG] stdout: grep: /opt/artifacts/BUILD_STAMP: No such file or directory
[DEBUG] retcode: 2
[INFO ] Executing command 'bash' in directory '/root'
```

Host results:

```
$ vagrant status builder
builder                   poweroff (virtualbox)

$ cat artifacts/BUILD_STAMP
26.05.3-arm64

$ ls artifacts/debs/*.deb | wc -l
      17

$ ls -lh artifacts/images/
154M  metrics-gateway.tar
 26M  node-exporter.tar
```

The 17 DEBs are `slurm-smd`, `-client`, `-dev`, `-doc`, `-libnss-slurm`, `-libpam-slurm-adopt`,
`-libpmi0`, `-libpmi2-0`, `-libslurm-perl`, `-openlava`, `-sackd`, `-slurmctld`, `-slurmd`,
`-slurmdbd`, `-slurmrestd`, `-sview`, `-torque`, all at `26.05.3-1`, `arm64`/`all`. Well above the
required 8.

### 3. Second `vagrant up builder` (from poweroff)

**41s, exit 0.** Vagrant does not re-provision an already-provisioned machine, so this is the
"no-op boot" branch the brief allows:

```
==> builder: Running trigger: generate pillar secrets...
==> builder: Rsyncing folder: ... => /vagrant
==> builder: Machine already provisioned. Run `vagrant provision` or use the `--provision`
==> builder: Running trigger: pull artifacts from builder and power it off...
EXIT=0 ELAPSED=41s
```

Artifacts re-pulled (17 DEBs still present) and the builder halted again
(`,builder,state,poweroff`).

### 4. Forced re-provision — `vagrant up builder --provision` (the idempotency proof)

**58s total, exit 0. Highstate: 506 ms, zero changes, build skipped by the guard.**

```
Salt binaries found. Configuring only.
  Name: podman                          - Function: pkg.installed  - Result: Clean - Duration: 13.797 ms
  Name: /etc/containers/systemd         - Function: file.directory - Result: Clean - Duration: 1.415 ms
  Name: bash /vagrant/scripts/build.sh  - Function: cmd.run        - Result: Clean - Duration: 490.84 ms

Succeeded: 3
Failed:    0
Total states run:     3
Total run time: 506.052 ms
```

`Succeeded: 3` with no `(changed=N)` suffix means changed=0. Artifacts re-pulled, builder halted.

### 5. Controller/compute artifacts precondition

Tested for real rather than reasoned about, by temporarily renaming the stamp:

```
$ mv artifacts/BUILD_STAMP artifacts/BUILD_STAMP.bak

$ vagrant provision controller
==> controller: Running action triggers before provision ...
==> controller: Running trigger: require builder artifacts...
artifacts/BUILD_STAMP is missing: the builder has not produced the Slurm DEBs and container
images yet. Run `vagrant up builder` first.
exit=1

$ vagrant provision compute
... same message ...
exit=1

$ mv artifacts/BUILD_STAMP.bak artifacts/BUILD_STAMP
$ vagrant provision controller
==> controller: Running trigger: require builder artifacts...
==> controller: VM not created. Moving on...
```

And the builder is *not* gated by it (no such trigger fires):

```
$ vagrant provision builder
==> builder: VM is not currently running. Please, first bring it up with `vagrant up` ...
```

The trigger fires before the VM is even consulted, which is the point: it fails in under a second
instead of failing deep inside a Salt state fifteen minutes in.

### Timing summary

| Run | Command | Wall clock | Highstate | Build state |
|---|---|---|---|---|
| Pre-fix | `vagrant up builder` (first ever) | 418s | 321s | Changed, 312s |
| A | `destroy` + `vagrant up builder` | **426s** | 317s | Changed, 312s |
| B | `vagrant up builder` (from poweroff) | **41s** | not run (already provisioned) | — |
| C | `vagrant up builder --provision` | **58s** | **0.51s** | **Clean (skipped)** |

Both slow runs are dominated by the Slurm debuild (~5m12s at `parallel=6` on 6 vCPU / 4 GB).
Salt bootstrap took ~90s.

## Self-review

- Slurm 26.05.3 tarball downloads fine from `download.schedmd.com` (6,873,582 bytes); no version
  discrepancy, the pinned pillar value is correct.
- The `unless` guard compares the *content* of BUILD_STAMP to `<version>-<arch>`, so bumping
  `slurm:version` in pillar forces a rebuild rather than silently reusing stale DEBs. `build.sh`
  also `rm -rf`s `artifacts/debs` before copying so an old version's DEBs cannot linger for apt.
- `tar -tf` validates the stream before extraction, so a failed remote command cannot leave a
  half-written `artifacts/` that the precondition would then happily accept.
- `-- -T` on the `vagrant ssh` is load-bearing: with a pty the terminal driver mangles the binary
  tar stream.
- `podman build` produces a 154 MB gateway image tar. That is python:3.12-slim plus Flask, not
  bloat, but it is the largest thing crossing the SSH channel.
- Builder rsync additionally excludes `artifacts/`; controller and compute do **not**, because they
  read `/vagrant/artifacts/...` in Tasks 4 and 5.

## Concerns / notes for later tasks

1. **`salt/minion.compute.conf` hardcodes `master: 192.168.56.10`**, duplicating
   `net:controller_ip`. This is unavoidable in kind — the file is what lets the minion *reach* the
   master that serves pillar — but it is a second place to edit if the address ever changes. A
   comment says so. If Task 5 wants zero duplication, `salt.minion_json_config` can be built from
   `PILLAR` in the Vagrantfile instead; I did not do that because it is untested and out of scope
   here.
2. **Controller and compute were never booted** (explicitly out of scope). Their salt provisioner
   blocks are wired per the plan but unexercised; the `install_master` + `run_highstate: false` +
   follow-up `salt-call` arrangement is unverified until Task 4.
3. **`vagrant up` with no arguments** will boot all three in definition order. The builder halts
   itself, then controller's precondition passes because artifacts now exist — the intended
   one-button flow — but that whole-fleet path is untested until Tasks 4 and 5 land.
4. **`build.sh` has no `timeout`** on the `cmd.run`. A wedged build would hang the provisioner
   rather than fail it. Left off deliberately: a wrong timeout that kills a legitimately slow build
   on a slower host is worse than a hang the operator can see.
5. `.claude/` is untracked in the repo root (other agents' worktrees). Not mine; left alone, not
   committed.
