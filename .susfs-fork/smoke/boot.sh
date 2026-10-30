#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Boot one GKI kernel in QEMU with the module zip and run the module's own scripts from init.sh.
#
# Usage: boot.sh KERNEL KMI MODULE_DIR OUT_DIR BUSYBOX [KERNELSU_KO POLICY KSUCTL]
#
#   KERNEL      a bootable arm64 Image, or the toolchain image the .ko was built in. The latter
#               is turned into an Image from its vmlinux and also leaves kernel.release and
#               kernel.config in OUT_DIR.
#   KMI         the kernel, for example android15-6.6
#   MODULE_DIR  the unpacked module zip
#   OUT_DIR     receives console.log and qemu.rc
#   BUSYBOX     static arm64 busybox (see busybox.sh), with the probes from probes.sh next to it
#   KERNELSU_KO a kernelsu.ko loaded before the module, with the SELinux POLICY it needs and
#               KSUCTL, the client that talks to it
#
# The verdict is check.py's. This script exits non-zero only when the setup failed.
#
# Needs docker, qemu-system-aarch64 and cpio on the host.
set -euo pipefail

kernel=${1:?KERNEL} kmi=${2:?KMI} module=${3:?MODULE_DIR} out=${4:?OUT_DIR} busybox=${5:?BUSYBOX}
ksu=${6:-} policy=${7:-} ksuctl=${8:-}
here=$(cd "$(dirname "$0")" && pwd)
ko="$module/lib/susfs_guard_lkm-$kmi.ko"
[ -s "$ko" ] || { echo "no .ko for $kmi in $module" >&2; exit 1; }
[ -s "$busybox" ] || { echo "no busybox at $busybox" >&2; exit 1; }
for f in post-fs-data.sh service.sh load.sh guard.sh kmis bin/susfs_insmod bin/susfs_sc; do
  [ -f "$module/$f" ] || { echo "the module has no $f" >&2; exit 1; }
done

mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. A bootable Image: the file itself, or one made from the pinned vmlinux.
if [ -f "$kernel" ]; then
  cp "$kernel" "$work/Image"
else
  bash "$here/retry.sh" docker pull --quiet "$kernel"
  docker run --rm -v "$work:/out" -v "$out:/res" "$kernel" sh -ec '
    llvm-objcopy -O binary -R .note -R .note.gnu.build-id -R .comment -S "$KDIR/vmlinux" /out/Image
    cat "$KDIR/include/config/kernel.release" > /res/kernel.release
    grep -E "^CONFIG_(ARM64_BTI_KERNEL|ARM64_PTR_AUTH_KERNEL|CFI_CLANG|SHADOW_CALL_STACK)=" "$KDIR/.config" > /res/kernel.config || true
  '
fi
[ -s "$work/Image" ] || { echo "no kernel Image was produced" >&2; exit 1; }

# 2. The root file system: the module as the installer leaves it, plus what its scripts expect
# from an Android device.
root="$work/root"
mkdir -p "$root"/{bin,proc,sys,tmp,system/bin} "$root/module"
install -m 0755 "$busybox" "$root/bin/busybox"
ln -s /bin/busybox "$root/system/bin/sh"
cp -a "$module/." "$root/module/"
find "$root/module/lib" -name '*.ko' ! -name "susfs_guard_lkm-$kmi.ko" -delete
# Permissions as customize.sh sets them. The probe stays non-executable, the wrapper fixes it.
find "$root/module" -type d -exec chmod 0755 {} +
find "$root/module" -type f -exec chmod 0644 {} +
for f in bin/susfs_insmod early-dispatch.sh load.sh post-fs-data.sh uninstall.sh; do
  [ ! -f "$root/module/$f" ] || chmod 0755 "$root/module/$f"
done
cp "$module/bin/susfs_sc" "$root/bin/sc"
chmod 0755 "$root/bin/sc"
# The probes sit next to busybox.
for p in prio_probe prio_probe32 kstat_probe kstat_probe32; do
  install -m 0755 "$(dirname "$busybox")/probes/$p" "$root/bin/$p"
done
# shellcheck disable=SC2016  # $1 is for the stub to expand
printf '#!/bin/sh\ncase "$1" in sys.boot_completed) echo 1 ;; esac\n' > "$root/bin/getprop"
chmod 0755 "$root/bin/getprop"
echo "VARIANT=$kmi" > "$root/smoke.env"
if [ -n "$ksu" ]; then
  mkdir -p "$root/ksu"
  cp "$ksu" "$root/ksu/kernelsu.ko"
  echo "KSU=/ksu/kernelsu.ko" >> "$root/smoke.env"
  [ -s "$ksuctl" ] || { echo "no ksuctl for the kernelsu.ko" >&2; exit 1; }
  install -m 0755 "$ksuctl" "$root/bin/ksuctl"
fi
if [ -n "$policy" ]; then
  cp "$policy" "$root/policy.bin"
  echo "POLICY=/policy.bin" >> "$root/smoke.env"
fi
cp "$here/init.sh" "$root/init"
chmod 0755 "$root/init"
(cd "$root" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -1) > "$work/initrd.gz"

# 3. Boot. A panic reboots at once and -no-reboot ends QEMU there. A hang is cut off by timeout.
# No NIC: the default one needs a ROM from ipxe-qemu, which --no-install-recommends skips.
rc=0
timeout --foreground -k 10 360 qemu-system-aarch64 \
  -machine virt -cpu max -m 2048 -smp 2 -nographic -no-reboot -nic none \
  -kernel "$work/Image" -initrd "$work/initrd.gz" \
  -append "console=ttyAMA0 panic=-1 loglevel=7 rdinit=/init" \
  > "$out/console.log" 2>&1 || rc=$?
echo "$rc" > "$out/qemu.rc"
echo "qemu exited with $rc after $(grep -c . "$out/console.log") console lines"
