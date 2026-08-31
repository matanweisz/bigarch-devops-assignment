#!/bin/sh
# Generates salt/pillar/secrets.sls if it does not already exist.
# Idempotent: a second run must not touch an existing file, so state
# provisioning and repeated `vagrant up` runs never rotate live secrets.
set -eu

cd "$(dirname "$0")/.."

out="salt/pillar/secrets.sls"

if [ -f "$out" ]; then
	echo "exists"
	exit 0
fi

db_password=$(openssl rand -hex 16)
munge_key_b64=$(openssl rand 128 | base64 | tr -d '\n')

cat >"$out" <<EOF
slurm:
  db:
    password: "${db_password}"

munge:
  key_b64: "${munge_key_b64}"
EOF

chmod 600 "$out"
echo "generated"
