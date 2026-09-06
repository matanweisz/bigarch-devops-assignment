#!/bin/sh
# Host side. Fired by the builder's `after :up` trigger. The artifacts are
# already on the host through the /opt/artifacts shared folder, so the only
# job left is powering the builder off, as the assignment requires.
set -eu

cd "$(dirname "$0")/.."

# `vagrant halt builder` cannot be used here: the up action still holds this
# machine's lock while its own after-up trigger runs, so the nested halt is
# refused. Powering off from inside the guest sidesteps the lock.
#
# --no-block so systemd returns before it tears down sshd. `|| true` because
# the connection can drop on the way out, which under `set -e` would fail the
# trigger after a perfectly good build. The poll below is the real check.
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
