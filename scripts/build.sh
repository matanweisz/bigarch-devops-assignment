#!/bin/bash
# Runs as root on the builder, invoked by salt/states/build/init.sls.
#
# Produces /opt/artifacts: Slurm DEBs built the official Debian way, plus the
# gateway and node_exporter images saved as tars for the other two nodes to
# load. A Vagrant trigger then pulls the whole directory back to the host.
set -euo pipefail

# Every tunable comes from pillar via the state's env block. Fail loudly rather
# than silently building a different version than the cluster expects.
: "${SLURM_VERSION:?set by salt/states/build/init.sls from pillar}"
: "${GATEWAY_IMAGE:?set by salt/states/build/init.sls from pillar}"
: "${NODE_EXPORTER_IMAGE:?set by salt/states/build/init.sls from pillar}"

artifacts=/opt/artifacts
src=/usr/local/src
stamp="${SLURM_VERSION}-$(dpkg --print-architecture)"

# The Salt state guards on this same value. Repeating it here keeps the script
# safe to run by hand and safe to re-run after a partial failure.
if [ -f "$artifacts/BUILD_STAMP" ] && [ "$(cat "$artifacts/BUILD_STAMP")" = "$stamp" ]; then
	echo "artifacts already built for ${stamp}, nothing to do"
	exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y build-essential fakeroot devscripts equivs wget bzip2

tarball="slurm-${SLURM_VERSION}.tar.bz2"
[ -f "${src}/${tarball}" ] ||
	wget -q -O "${src}/${tarball}" "https://download.schedmd.com/slurm/${tarball}"

# A half-extracted tree from a previous failed run would poison the build.
rm -rf "${src}/slurm-${SLURM_VERSION}"
tar -xjf "${src}/${tarball}" -C "$src"
cd "${src}/slurm-${SLURM_VERSION}"

# SchedMD ships debian/ in the tarball. Reading the build deps out of its own
# control file beats maintaining a parallel package list that rots on every bump.
mk-build-deps -i debian/control -t 'apt-get -y'

# -b binary only, -uc -us unsigned: a lab has no signing key. --no-lintian
# because lintian exits non-zero on packaging style warnings we do not control,
# which would throw away the whole compile over nits.
DEB_BUILD_OPTIONS="parallel=$(nproc)" debuild --no-lintian -b -uc -us

# Rebuild the directory rather than adding to it, so a version bump cannot leave
# the previous version's DEBs behind for apt to pick up.
rm -rf "$artifacts/debs"
mkdir -p "$artifacts/debs" "$artifacts/images"
cp "${src}"/slurm-smd*.deb "$artifacts/debs/"

podman build -t "$GATEWAY_IMAGE" /vagrant/gateway
podman save -o "$artifacts/images/metrics-gateway.tar" "$GATEWAY_IMAGE"

podman pull "$NODE_EXPORTER_IMAGE"
podman save -o "$artifacts/images/node-exporter.tar" "$NODE_EXPORTER_IMAGE"

# Written last on purpose: the stamp means "everything above succeeded". Both
# the Salt guard and the controller/compute preconditions trust exactly that.
echo "$stamp" >"$artifacts/BUILD_STAMP"
echo "built artifacts for ${stamp}"
