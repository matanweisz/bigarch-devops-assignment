#!/bin/bash
# Runs as root on the builder, invoked by salt/states/build/init.sls.
#
# Produces /opt/artifacts: Slurm DEBs built the official Debian way, plus the
# gateway and node_exporter images saved as tars for the other two nodes to
# load. A Vagrant trigger then pulls the whole directory back to the host.
#
# Two independent stamps so the expensive Slurm compile is not repeated when
# only an image changed: BUILD_STAMP covers the DEBs (Slurm version + arch),
# IMAGE_STAMP covers the image tars (both tags plus a content hash of
# gateway/, so editing the gateway source rebuilds its image without a tag
# bump). `--check` exits 0 when everything is current; the Salt state uses it
# as its guard so the skip logic lives in exactly one place.
set -euo pipefail

# Every tunable comes from pillar via the state's env block. Fail loudly rather
# than silently building a different version than the cluster expects.
: "${SLURM_VERSION:?set by salt/states/build/init.sls from pillar}"
: "${GATEWAY_IMAGE:?set by salt/states/build/init.sls from pillar}"
: "${NODE_EXPORTER_IMAGE:?set by salt/states/build/init.sls from pillar}"

artifacts=/opt/artifacts
src=/usr/local/src
deb_stamp="${SLURM_VERSION}-$(dpkg --print-architecture)"
gateway_hash=$(find /vagrant/gateway -type f ! -path '*/.venv/*' -exec sha256sum {} + |
	sort | sha256sum | cut -c1-16)
image_stamp="${GATEWAY_IMAGE}|${NODE_EXPORTER_IMAGE}|${gateway_hash}"

debs_current=false
images_current=false
[ -f "$artifacts/BUILD_STAMP" ] && [ "$(cat "$artifacts/BUILD_STAMP")" = "$deb_stamp" ] &&
	debs_current=true
[ -f "$artifacts/IMAGE_STAMP" ] && [ "$(cat "$artifacts/IMAGE_STAMP")" = "$image_stamp" ] &&
	images_current=true

if [ "${1:-}" = "--check" ]; then
	$debs_current && $images_current && exit 0
	exit 1
fi

if $debs_current && $images_current; then
	echo "artifacts already built for ${deb_stamp} / ${image_stamp}, nothing to do"
	exit 0
fi

export DEBIAN_FRONTEND=noninteractive

if ! $debs_current; then
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

	# Rebuild the directory rather than adding to it, so a version bump cannot
	# leave the previous version's DEBs behind for apt to pick up.
	rm -rf "$artifacts/debs"
	mkdir -p "$artifacts/debs"
	cp "${src}"/slurm-smd*.deb "$artifacts/debs/"

	# Written after its section succeeds; the controller/compute preconditions
	# key on this file existing at all, so it must never appear early.
	echo "$deb_stamp" >"$artifacts/BUILD_STAMP"
fi

if ! $images_current; then
	mkdir -p "$artifacts/images"

	podman build -t "$GATEWAY_IMAGE" /vagrant/gateway
	podman save -o "$artifacts/images/metrics-gateway.tar" "$GATEWAY_IMAGE"

	podman pull "$NODE_EXPORTER_IMAGE"
	podman save -o "$artifacts/images/node-exporter.tar" "$NODE_EXPORTER_IMAGE"

	echo "$image_stamp" >"$artifacts/IMAGE_STAMP"
fi

echo "built artifacts: ${deb_stamp} / ${image_stamp}"
