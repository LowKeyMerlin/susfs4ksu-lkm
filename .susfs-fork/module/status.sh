#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Facts for the WebUI header, one key=value per line. Reads only, writes nothing.
MODDIR=${0%/*}
PROC=${SUSFS_PROC:-/proc}
SYS_MODULE=${SUSFS_SYS_MODULE:-/sys/module/susfs_guard_lkm}
EARLY_HOOK=${SUSFS_EARLY_HOOK:-/data/adb/post-fs-data.d/00-susfs-guard-lkm.sh}

prop() { sed -n "s/^$1=//p" "$MODDIR/module.prop" 2>/dev/null | head -n 1; }
flag() { [ -e "$1" ] && echo 1 || echo 0; }

echo "name=$(prop name)"
echo "version=$(prop version)"
echo "susfs_base=$(prop susfsBase)"
echo "card=$(prop description)"
echo "kernel=$(cat "$PROC/sys/kernel/osrelease" 2>/dev/null)"
echo "loaded=$(flag "$SYS_MODULE")"
# The hook and the marker are both needed: the marker alone makes post-fs-data.sh skip the load
# and nothing else would run it.
if [ -f "$MODDIR/early_load" ] && [ -f "$EARLY_HOOK" ]; then
  echo "early_load=1"
else
  echo "early_load=0"
fi
echo "disabled=$(flag "$MODDIR/disable")"
echo "guard_tripped=$(flag "$MODDIR/guard.tripped")"
echo "guard_fails=$(cat "$MODDIR/guard.fails" 2>/dev/null || echo 0)"
