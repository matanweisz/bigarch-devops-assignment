# Task 1 Report: Secrets generation + pillar/state skeleton

## Status: DONE

## What was implemented

- `scripts/gen-secrets.sh` — POSIX `sh`, `set -eu`, `cd`s to repo root (so it
  works regardless of invocation cwd). If `salt/pillar/secrets.sls` is
  missing, generates `slurm:db:password` (`openssl rand -hex 16`) and
  `munge:key_b64` (`openssl rand 128 | base64 | tr -d '\n'`), writes the file,
  `chmod 600`s it, prints `generated`. If the file already exists, prints
  `exists` and does nothing else.
- `salt/pillar/common.sls` — all shared pillar keys from the brief verbatim:
  `net:controller_ip`/`net:compute_ip`, `slurm:version`/`cluster_name`/`uid`,
  `munge:uid`, `slurm:db:name`/`user`, `gateway:image`/`node_port`,
  `monitoring:namespace`/`release`, `grafana:user`/`password`,
  `node_exporter:image`/`port`.
- `salt/pillar/top.sls` — `base: '*': [common, secrets]`.
- `salt/pillar/secrets.sls.example` — same structure as the generated
  `secrets.sls` (`slurm:db:password`, `munge:key_b64`), placeholder value
  `"changeme"`, one-line comment pointing at `gen-secrets.sh`. Committed.
- `salt/states/top.sls` — `base:` matched on `role` grain: `role:builder` ->
  `[podman, build]`; `role:controller` -> `[podman, munge, mariadb,
  slurm.controller, node_exporter, slurm.cron]`; `role:compute` -> `[munge,
  slurm.compute, k3s, monitoring]`. State dirs referenced (podman, build,
  munge, mariadb, slurm.controller, node_exporter, slurm.cron, slurm.compute,
  k3s, monitoring) do not exist yet — expected per task brief, later tasks
  create them.
- `.gitignore` — added `salt/pillar/secrets.sls`.

No extra files or pillar keys beyond what the brief specifies.

## Verification

```
$ sh -n scripts/gen-secrets.sh && echo OK
OK

$ sh scripts/gen-secrets.sh
generated

$ stat -f "%m %Sp" salt/pillar/secrets.sls
1788167154 -rw-------

$ sleep 2 && sh scripts/gen-secrets.sh
exists

$ stat -f "%m %Sp" salt/pillar/secrets.sls
1788167154 -rw-------      # same mtime -> second run did not rewrite

$ python3 -c "import yaml"
ModuleNotFoundError: No module named 'yaml'   # no yaml module on this host, per brief's fallback note

$ ruby -ryaml -e 'Dir.glob("salt/pillar/*.sls").reject{|f| f.end_with?(".example")}.push("salt/states/top.sls").each { |f| YAML.load_file(f); puts "OK #{f}" }'
OK salt/pillar/top.sls
OK salt/pillar/secrets.sls
OK salt/pillar/common.sls
OK salt/states/top.sls

$ ruby -ryaml -e 'YAML.load_file("salt/pillar/secrets.sls.example"); puts "OK example"'
OK example

$ git status --ignored --short | grep secrets
!! salt/pillar/secrets.sls   # confirmed gitignored, not staged

$ git diff --cached --summary
 create mode 100644 salt/pillar/common.sls
 create mode 100644 salt/pillar/secrets.sls.example
 create mode 100644 salt/pillar/top.sls
 create mode 100644 salt/states/top.sls
 create mode 100755 scripts/gen-secrets.sh   # executable bit confirmed
```

## Files changed

- `scripts/gen-secrets.sh` (new, mode 755)
- `salt/pillar/common.sls` (new)
- `salt/pillar/top.sls` (new)
- `salt/pillar/secrets.sls.example` (new)
- `salt/states/top.sls` (new)
- `.gitignore` (modified: `+salt/pillar/secrets.sls`)
- `salt/pillar/secrets.sls` (generated locally, gitignored, not committed)

## Self-review

- **Completeness against brief**: all 15 pillar keys and both secret keys
  present with exact values from the brief; `top.sls` role mapping matches
  exactly; gen-secrets.sh behavior (idempotent, mode 600, "generated"/"exists"
  output) matches exactly.
- **No hardcoded values that belong in pillar**: `gen-secrets.sh` writes
  pillar-format YAML directly (there's nowhere else for those two secret
  values to live — they're pillar data being generated, not hardcoded
  business logic). States/Vagrantfile that would consume these pillar keys
  don't exist yet (later tasks), so there's nothing else to check for
  hardcoding in this task's scope.
- **YAGNI**: no map.jinja, no extra pillar layering, no unrequested
  validation beyond what the brief asked for. `secrets.sls.example` mirrors
  only the two secret keys, not the full common pillar (secrets and common
  are separate files by design, matching top.sls).
- **Clean output**: script only prints `generated` or `exists`, no extra
  logging.

## Concerns

- None blocking. Minor note: `gen-secrets.sh` does `cd` to the repo root
  (`dirname "$0"/..`) before writing, so it works when invoked with a
  relative path from any cwd (e.g. a future Vagrant shell provisioner). This
  wasn't explicitly requested by the brief but is a 2-line addition needed
  for the script to be safely callable from contexts other than the repo
  root — flagging in case the reviewer wants it simplified to assume
  repo-root invocation only.
- `python3 -c "import yaml"` failed on this host (no PyYAML installed) —
  used the brief's documented Ruby fallback successfully; did not pip-install
  anything.

## Review fix: umask window (commit 5614f7b)

**Finding (Important, from coordinator review):** `scripts/gen-secrets.sh`
wrote the secrets file with `cat > "$out"` and only `chmod 600` afterward,
leaving a window where the file existed with the process's inherited umask
(potentially group/world-readable) before the permissions were tightened.

**Fix:** added `umask 077` right after `set -eu`, before the file is ever
created, so the heredoc write itself produces a `0600` file — no window, no
extra `chmod` step needed to fix an already-wrong mode (the existing `chmod
600` at the end is now just belt-and-suspenders and was left in place).

```diff
 set -eu
 
+# Secret material below must never be briefly world/group-readable between
+# creation and the chmod call, so restrict the process umask up front.
+umask 077
+
 cd "$(dirname "$0")/.."
```

**Verification:**

```
$ sh -n scripts/gen-secrets.sh && echo OK
OK

$ rm -f salt/pillar/secrets.sls
$ umask 022 && sh scripts/gen-secrets.sh   # deliberately permissive caller umask
generated

$ stat -f "%m %Sp" salt/pillar/secrets.sls
1788167352 -rw-------      # 0600 even though caller's umask was 022

$ sleep 2 && sh scripts/gen-secrets.sh
exists

$ stat -f "%m %Sp" salt/pillar/secrets.sls
1788167352 -rw-------      # unchanged mtime and mode -> second run still a no-op

$ ruby -ryaml -e 'Dir.glob("salt/pillar/*.sls").reject{|f| f.end_with?(".example")}.push("salt/states/top.sls").each { |f| YAML.load_file(f); puts "OK #{f}" }'
OK salt/pillar/top.sls
OK salt/pillar/secrets.sls
OK salt/pillar/common.sls
OK salt/states/top.sls
```

Ran the regenerate step with `umask 022` set in the parent shell specifically
to prove the fix works even against a permissive caller umask (the failure
mode the finding described) — `umask 077` inside the script overrides it
before the file is created, so the `022` never leaks through.
