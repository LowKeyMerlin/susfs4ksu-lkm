#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Fetch only the .deb files needed to install QEMU and the SELinux policy compiler.
#
# Usage: qemu_debs.sh OUT_DIR
#
# apt decides what is needed, this script fetches it. The runner's mirror sometimes stalls
# mid-download and apt waits for minutes. Each file here has a speed floor, falls back to a
# second mirror and is checked against the SHA256 from apt's index.
#
# The runner's apt sources are a mirror list, so the URIs apt prints are not addresses and carry
# only an MD5. Take the file name from apt and ask the index for its path and SHA256.
#
# MIRRORS (space separated) replaces the default list, for the tests of this script.
set -euo pipefail

out=${1:?OUT_DIR}
packages=(qemu-system-arm cpio secilc)
read -ra mirrors <<< "${MIRRORS:-http://azure.archive.ubuntu.com/ubuntu http://archive.ubuntu.com/ubuntu}"
export DEBIAN_FRONTEND=noninteractive

# Fetch one file from the mirrors in turn and keep it only if the hash matches.
fetch() {
  local file=$1 path=$2 hash=$3 mirror started
  for mirror in "${mirrors[@]}"; do
    started=$SECONDS
    if curl -fsSL --connect-timeout 10 --max-time 180 --speed-limit 50000 --speed-time 15 --retry 2 \
      -o "$out/$file" "$mirror/$path" && echo "$hash  $out/$file" | sha256sum -c --quiet -; then
      echo "$file from ${mirror#http://} in $((SECONDS - started))s"
      return 0
    fi
    echo "$file failed on ${mirror#http://}" >&2
    rm -f "$out/$file"
  done
  return 1
}

# Field of the first record apt-cache prints for a package.
index_field() {
  awk -v key="$1:" '$1 == key { print $2; exit }' <<< "$2"
}

mkdir -p "$out"

updated=
for attempt in 1 2 3 4 5; do
  if sudo apt-get update -q -o Acquire::Retries=3 -o Acquire::http::Timeout=20; then
    updated=yes
    break
  fi
  echo "apt-get update failed, attempt $attempt" >&2
  sleep 15
done
[ -n "$updated" ] || exit 1

# One line per package not installed yet: 'URI' FILE SIZE HASH
uris=$(sudo apt-get install -y -qq --no-install-recommends --print-uris "${packages[@]}")

count=0
while read -r _ file _; do
  [ -n "$file" ] || continue
  # NAME_VERSION_ARCH.deb, with the epoch colon of the version written as %3a.
  stem=${file%.deb}
  versioned=${stem%_*}
  name=${versioned%_*}
  encoded=${versioned##*_}
  version=$(printf '%b' "${encoded//\%/\\x}")
  record=$(apt-cache show "$name=$version" 2> /dev/null || true)
  path=$(index_field Filename "$record")
  hash=$(index_field SHA256 "$record")
  if [ -z "$path" ] || [ -z "$hash" ]; then
    echo "the index has no path or SHA256 for $name=$version, apt named $file" >&2
    exit 1
  fi
  fetch "$file" "$path" "$hash" || { echo "$file could not be fetched from any mirror" >&2; exit 1; }
  count=$((count + 1))
done <<< "$uris"

[ "$count" -gt 0 ] || { echo "apt wants to install nothing, QEMU would be missing from the VMs" >&2; exit 1; }
echo "fetched $count packages"
