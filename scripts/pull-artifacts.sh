#!/bin/sh
# Host side. Fired by the builder's `after :up` trigger: streams /opt/artifacts
# out of the ephemeral builder over SSH into ./artifacts, then powers it off.
#
# A script rather than an inline trigger: Vagrant Shellwords-splits an inline
# host command and execs it without a shell, so `>` would reach tar as a literal
# argument.
set -eu

cd "$(dirname "$0")/.."

tarball=$(mktemp "${TMPDIR:-/tmp}/bigarch-artifacts.XXXXXX")
trap 'rm -f "$tarball"' EXIT

# -- -T forces ssh not to allocate a pty. With one, the terminal driver mangles
# CR/LF in the binary tar stream and the archive arrives corrupt.
vagrant ssh builder -c 'sudo tar -C /opt/artifacts -cf - .' -- -T >"$tarball"

# Never unpack a stream not proved to be a tar. A failed remote command would
# leave a half-written artifacts/ that the controller's precondition accepts.
tar -tf "$tarball" >/dev/null

# Replace, never merge. Clearing /opt/artifacts guest-side does nothing to the
# host copy, so after a slurm:version bump an extract-in-place would leave old
# DEBs beside the new ones and the slurm state's install glob would match two.
rm -rf artifacts
mkdir artifacts
tar -xf "$tarball" -C artifacts

# `vagrant halt builder` cannot be used here: the up action still holds this
# machine's lock while its own after-up trigger runs, so the nested halt is
# refused. Powering off from inside the guest sidesteps the lock.
#
# --no-block so systemd returns before it tears down sshd. `|| true` because the
# connection can still drop on the way out, which under `set -e` would fail the
# trigger after a perfectly good pull. The poll below is the real check.
vagrant ssh builder -c 'sudo systemctl poweroff --no-block' -- -T || true

# Wait for the box to be genuinely down, so `vagrant status` is deterministic
# for whatever runs after `vagrant up`.
waited=0
while vagrant status builder --machine-readable | grep -q ',state,running'; do
	if [ "$waited" -ge 60 ]; then
		echo "builder did not power off within 60s" >&2
		exit 1
	fi
	sleep 2
	waited=$((waited + 2))
done
