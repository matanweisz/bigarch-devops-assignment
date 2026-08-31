#!/bin/sh
# Host side. Fired by the builder's `after :up` trigger: streams /opt/artifacts
# out of the ephemeral builder over SSH into ./artifacts, then powers it off.
#
# This is a script rather than an inline trigger because Vagrant Shellwords-splits
# an inline host command and execs it without a shell, so `>` would be passed to
# tar as a literal argument.
set -eu

cd "$(dirname "$0")/.."

tarball=$(mktemp "${TMPDIR:-/tmp}/bigarch-artifacts.XXXXXX")
trap 'rm -f "$tarball"' EXIT

# -- -T forces ssh not to allocate a pty; with one, the terminal driver mangles
# CR/LF in the binary tar stream and the archive arrives corrupt.
vagrant ssh builder -c 'sudo tar -C /opt/artifacts -cf - .' -- -T >"$tarball"

# Never unpack a stream that has not been proved to be a tar. A failed remote
# command would otherwise leave a half-written artifacts/ that the controller's
# precondition would happily accept.
tar -tf "$tarball" >/dev/null

mkdir -p artifacts
tar -xf "$tarball" -C artifacts

# The builder has done its job; it exists only to compile.
#
# `vagrant halt builder` cannot be used here: the up action still holds this
# machine's lock while its own after-up trigger runs, so the nested halt is
# refused. Powering off from inside the guest sidesteps the lock entirely.
# --no-block so systemd returns before it tears down sshd and the exit code
# still reflects whether the command was accepted.
vagrant ssh builder -c 'sudo systemctl poweroff --no-block' -- -T

# Wait for the box to be genuinely down, so `vagrant status` is deterministic
# for whatever runs straight after `vagrant up`.
waited=0
while vagrant status builder --machine-readable | grep -q ',state,running'; do
	if [ "$waited" -ge 60 ]; then
		echo "builder did not power off within 60s" >&2
		exit 1
	fi
	sleep 2
	waited=$((waited + 2))
done
