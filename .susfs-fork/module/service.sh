#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Clear the bootloop guard marker once the boot has settled (see guard.sh).
MODDIR=${0%/*}
# shellcheck source=/dev/null
. "$MODDIR/guard.sh"
(guard_settle >>"$MODDIR/guard.log" 2>&1) &

# Keep init.svc.adbd honest across adb toggles.  Where adbd runs as root under its own init service
# (Xiaomi's /system_ext/bin/adb_root), the stock adbd service reads stopped while adbd is in fact
# live, and init rewrites init.svc.adbd on every adbd transition, so a one-shot correction cannot hold.
# susfs_propwait blocks on the property in /dev/__properties__ and re-runs the guard only when it
# changes (event driven, idle in a futex, no polling) so the correction follows each toggle.  The
# guard (adbd_guard.sh) only acts when adbd is genuinely up, so on devices without that quirk it is a
# no-op and the watcher simply sleeps.
WATCH="$MODDIR/bin/susfs_propwait"
if [ -f "$WATCH" ]; then
	chmod 0755 "$WATCH" 2>/dev/null
	# Detach every inherited fd: the watcher never exits, so a subshell wrapper or an inherited
	# stdout would keep this script's output open for good and stall whoever reads it (ksud at
	# boot, adbd under the android test).  Background the binary directly, fds pinned to the log.
	"$WATCH" init.svc.adbd "$MODDIR/adbd_guard.sh" </dev/null >>"$MODDIR/adbd_watch.log" 2>&1 &
fi
