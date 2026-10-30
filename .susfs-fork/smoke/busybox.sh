#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Fetch the static arm64 busybox that is the userspace of the test VM.
#
# Usage: busybox.sh OUT_FILE
#
# The runner is x86-64, so busybox comes from the arm64 archive and is checked against the SHA256
# in its index. It only runs inside the throwaway VM. Suites are tried newest first, starting
# from the runner's release.
#
# PORTS and CODENAME replace the archive and release, for the tests of this script.
set -euo pipefail

out=${1:?OUT_FILE}
ports=${PORTS:-https://ports.ubuntu.com/ubuntu-ports}
# shellcheck source=/dev/null
codename=${CODENAME:-$(. /etc/os-release && echo "$VERSION_CODENAME")}
[ -n "$codename" ] || { echo "cannot tell the release of this runner" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A speed floor ends a stalled download and curl retries.
fetch() {
  curl -fsSL --connect-timeout 10 --max-time 180 --speed-limit 50000 --speed-time 15 \
    --retry 3 --retry-delay 5 --retry-all-errors -o "$2" "$1"
}

# Path and SHA256 of busybox-static in the first index that lists it.
found=
for suite in "$codename-updates" "$codename"; do
  for part in main universe; do
    fetch "$ports/dists/$suite/$part/binary-arm64/Packages.gz" "$work/Packages.gz"
    # awk reads to the end, an early exit would make gzip fail on the closed pipe.
    found=$(gzip -dc "$work/Packages.gz" | awk -v RS= '
      !done && $0 ~ /(^|\n)Package: busybox-static(\n|$)/ {
        n = split($0, line, "\n")
        for (i = 1; i <= n; i++) {
          if (line[i] ~ /^Filename: /) path = substr(line[i], 11)
          if (line[i] ~ /^SHA256: /) hash = substr(line[i], 9)
        }
        print path, hash
        done = 1
      }')
    [ -z "$found" ] || break 2
  done
done
read -r deb hash <<< "$found" || true
if [ -z "${deb:-}" ] || [ -z "${hash:-}" ]; then
  echo "busybox-static is not in the arm64 index for $codename" >&2
  exit 1
fi

fetch "$ports/$deb" "$work/busybox.deb"
echo "$hash  $work/busybox.deb" | sha256sum -c --quiet - || { echo "busybox.deb does not match the index" >&2; exit 1; }
dpkg-deb -x "$work/busybox.deb" "$work/root"
binary=$(find "$work/root" -name busybox -type f | head -n 1)
if [ -z "$binary" ] || ! file "$binary" | grep -q 'ARM aarch64.*statically linked'; then
  echo "the busybox is not a static arm64 binary" >&2
  exit 1
fi
install -D -m 0755 "$binary" "$out"
echo "busybox from $deb"
