#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the probes the VM runs from one source each: prio_probe and kstat_probe, with a 32-bit build of both.
#
# Usage: probes.sh OUT_DIR
set -euo pipefail

out=${1:?OUT_DIR}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"

common=(-O2 -Wall -Werror -nostdlib -fno-stack-protector -fno-builtin -fuse-ld=lld -Wl,-e,_start)
clang --target=aarch64-linux-gnu -static-pie "${common[@]}" -o "$out/prio_probe" "$here/prio_probe.c"
clang --target=armv7-linux-gnueabi -marm -static "${common[@]}" -o "$out/prio_probe32" "$here/prio_probe.c"
clang --target=aarch64-linux-gnu -static-pie "${common[@]}" -o "$out/kstat_probe" "$here/kstat_probe.c"
clang --target=armv7-linux-gnueabi -marm -static "${common[@]}" -o "$out/kstat_probe32" "$here/kstat_probe.c"
file "$out"/*_probe*
