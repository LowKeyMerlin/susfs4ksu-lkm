#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# One-button triage dump: the module state, the kernel SUSFS nodes, the health checks and this
# module's kernel-log lines, collected into a single text file to hand to a developer when a
# detection or leak needs looking at. Reads only (the report is the one thing it writes) and
# prints "path=<file>" on the last line so the WebUI can show where it went.
MODDIR=${0%/*}
PROC=${SUSFS_PROC:-/proc}
NAME=susfs_guard_lkm
DMESG=${SUSFS_DMESG:-dmesg}
SUSFS_BIN=${SUSFS_BIN:-/data/adb/ksu/bin/ksu_susfs}
STAMP=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo unknown)
MODEL=$(getprop ro.product.model 2>/dev/null | tr -c 'A-Za-z0-9._-' _)

# /sdcard/Download is where a user can reach the file to share it. Fall back inward if it is not
# writable from here. The write test avoids naming a file in a directory we cannot write to.
OUT=
for base in ${CAPTURE_DIR:+"$CAPTURE_DIR"} /sdcard/Download /sdcard /data/local/tmp; do
  if mkdir -p "$base" 2>/dev/null && : >"$base/.susfs_wtest.$$" 2>/dev/null; then
    rm -f "$base/.susfs_wtest.$$"
    OUT="$base/susfs_guard_report_${MODEL:-device}_$STAMP.txt"
    break
  fi
done
[ -n "$OUT" ] || { echo "no writable location for the report" >&2; exit 1; }

sec() { printf '\n==== %s ====\n' "$1"; }

{
  echo "SUSFS Guard (LKM) diagnostics"
  echo "generated: $(date 2>/dev/null)"
  echo "note: reads only; attach this file when reporting a detection or leak."

  sec "Device"
  for p in ro.product.manufacturer ro.product.model ro.product.device \
           ro.build.fingerprint ro.build.version.release ro.build.version.security_patch \
           ro.boot.verifiedbootstate; do
    printf '%-34s %s\n' "$p" "$(getprop "$p" 2>/dev/null)"
  done
  printf '%-34s %s\n' selinux "$(getenforce 2>/dev/null)"
  printf '%-34s %s\n' kernel "$(cat "$PROC/sys/kernel/osrelease" 2>/dev/null)"

  sec "Module status (status.sh)"
  sh "$MODDIR/status.sh" 2>&1

  sec "Health checks (check.sh)"
  sh "$MODDIR/check.sh" 2>&1

  sec "Storage as root, and the mount hook counters"
  for p in / /data /storage/emulated/0; do
    printf -- '--- stat -f %s ---\n' "$p"
    stat -f "$p" 2>&1
  done
  printf -- '--- mount_stat ---\n'
  cat "/sys/module/$NAME/parameters/mount_stat" 2>&1

  sec "Mounts of init"
  cat "$PROC/1/mountinfo" 2>&1

  sec "module.prop"
  cat "$MODDIR/module.prop" 2>&1

  sec "SUSFS kernel nodes"
  for p in "$PROC"/susfs*; do
    [ -e "$p" ] || continue
    printf -- '--- %s ---\n' "${p##*/}"
    cat "$p" 2>&1
    printf '\n'
  done

  sec "SUSFS feature report (ksu_susfs)"
  if [ -x "$SUSFS_BIN" ]; then
    for q in version variant enabled_features; do
      printf -- '--- show %s ---\n' "$q"
      "$SUSFS_BIN" show "$q" 2>&1
      printf '\n'
    done
  else
    echo "ksu_susfs not present at $SUSFS_BIN"
  fi

  sec "Hidden mounts and SELinux types"
  echo "--- hide_mounts ---"
  sh "$MODDIR/hide_mounts.sh" list 2>&1
  echo "--- selinux_ctx ---"
  sh "$MODDIR/selinux_ctx.sh" list 2>&1

  sec "Other SUSFS components on the device (found from what they ship)"
  # shellcheck source=/dev/null
  . "$MODDIR/clients.sh" 2>/dev/null
  echo "clients:   $(cl_clients 2>/dev/null | tr '\n' ' ')"
  echo "providers: $(cl_providers 2>/dev/null | tr '\n' ' ')"

  sec "load.log"
  tail -n 80 "$MODDIR/load.log" 2>&1

  sec "guard.log (last lines)"
  tail -n 40 "$MODDIR/guard.log" 2>&1

  sec "Kernel log: module lines (last 400)"
  "$DMESG" 2>/dev/null | grep "$NAME:" | tail -n 400
} >"$OUT" 2>&1

chmod 0644 "$OUT" 2>/dev/null
echo "path=$OUT"
