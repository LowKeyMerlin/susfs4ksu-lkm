#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Load the module under the bootloop guard (guard.sh). The loader is the unchanged upstream
# script, shipped as load.upstream.sh.
MODDIR=${0%/*}
# shellcheck source=/dev/null
. "$MODDIR/guard.sh"
[ ! -f "$MODDIR/disable" ] || exit 0
[ ! -f "$MODDIR/remove" ] || exit 0
[ "$(getprop persist.sys.safemode)" != 1 ] || exit 0
[ "$(getprop ro.sys.safemode)" != 1 ] || exit 0
umask 077
# The upstream loader truncates load.log on every run, so keep a separate log.
if [ -f "$MODDIR/guard.log" ] && [ "$(wc -c <"$MODDIR/guard.log")" -gt 65536 ]; then
  mv -f "$MODDIR/guard.log" "$MODDIR/guard.log.old"
fi
exec >>"$MODDIR/guard.log" 2>&1
echo "== $(date) boot $(guard_boot_id)"

guard_check || exit 0

# Never stack a second copy of SUSFS on one that already answers. If the probe cannot run,
# load nothing rather than guess.
guard_probe
case $? in
  0)
    echo "SUSFS already answers, nothing to load."
    guard_card "Standing by" "SUSFS already answers on this kernel (built in, or loaded earlier)"
    exit 0
    ;;
  1) ;;
  *)
    echo "the probe could not run"
    guard_card "Not loaded" "cannot tell whether SUSFS is already present"
    exit 0
    ;;
esac

# shellcheck source=/dev/null
. "$MODDIR/kmi.sh"
guard_kernel || exit 0

guard_arm || {
  echo "cannot write the guard marker"
  guard_card "Not loaded" "the bootloop guard cannot write its state"
  exit 0
}

"$GUARD_SH" "$MODDIR/load.upstream.sh"
rc=$?
# The upstream loader words the card its own way, this is the one the fork shows. A module that
# loaded but is unloaded below because it does not answer is described by guard_trip instead.
guard_status "$rc"

# A module that loaded but does not answer only adds risk, so unload and disable it. The marker
# is still armed, so a crash during the unload is caught on the next boot.
if [ "$rc" = 0 ] && [ -d "$GUARD_SYS_MODULE" ]; then
  guard_probe
  case $? in
    0) echo "loaded, SUSFS answers." ;;
    1)
      echo "loaded, but SUSFS does not answer, unloading."
      rmmod susfs_guard_lkm
      guard_trip "loaded, but SUSFS did not answer"
      ;;
    *) echo "loaded, the probe could not run, leaving it loaded." ;;
  esac
fi
exit "$rc"
