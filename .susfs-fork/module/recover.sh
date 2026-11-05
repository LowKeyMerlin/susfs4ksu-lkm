#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Load the module again after the bootloop guard tripped, without a reboot. The guard is not armed
# for the running boot, the next boot arms it as usual.
#
# stdout is one line for the WebUI, the detail goes to guard.log:
#   recovered=<loaded|present|idle|blocked|nokernel|noanswer|failed>
# The exit status is 0 for loaded, present and idle.
MODDIR=${0%/*}
# shellcheck source=/dev/null
. "$MODDIR/guard.sh"
umask 077

result=failed
rc=1

# The conditions under which the boot path refuses to load as well.
blocked() {
  [ -e "$GUARD_SKIP_FILE" ] || [ -f "$MODDIR/remove" ] ||
    [ "$(getprop persist.sys.safemode)" = 1 ] || [ "$(getprop ro.sys.safemode)" = 1 ]
}

recover() {
  if [ ! -f "$GUARD_TRIPPED" ]; then
    echo "the guard has not tripped, nothing to do"
    result=idle
    rc=0
    return
  fi
  if blocked; then
    echo "not loading: skip file, safe mode or pending removal"
    result=blocked
    return
  fi
  # Cleared before the load, so a failed load still leaves the next boot a fresh start.
  guard_untrip
  guard_probe
  if [ $? -eq 0 ]; then
    echo "SUSFS already answers, nothing to load."
    guard_card "Standing by" "SUSFS already answers on this kernel (built in, or loaded earlier)"
    result=present
    rc=0
    return
  fi
  # shellcheck source=/dev/null
  . "$MODDIR/kmi.sh"
  if ! guard_kernel; then
    result=nokernel
    return
  fi
  "$GUARD_SH" "$MODDIR/load.upstream.sh"
  lrc=$?
  guard_status "$lrc"
  if [ "$lrc" != 0 ]; then
    rc=$lrc
    return
  fi
  guard_probe
  probe=$?
  if [ -d "$GUARD_SYS_MODULE" ]; then
    if [ "$probe" = 1 ]; then
      echo "loaded, but SUSFS does not answer, unloading."
      rmmod susfs_guard_lkm
      guard_card "Not loaded" "loaded, but SUSFS did not answer"
      result=noanswer
      return
    fi
    result=loaded
    rc=0
  elif [ "$probe" = 0 ]; then
    # The loader also exits 0 when it skipped the load, so only an answering probe counts.
    result=present
    rc=0
  fi
}

{
  echo "== $(date) recover, boot $(guard_boot_id)"
  recover
} >>"$MODDIR/guard.log" 2>&1
echo "recovered=$result"
exit "$rc"
