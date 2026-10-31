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
echo "author=$(prop author)"
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
# Anything but self and none reads as all, as guard.sh does.
case $(cat "$MODDIR/guard.scope" 2>/dev/null) in
  self) echo "guard_scope=self" ;;
  none) echo "guard_scope=none" ;;
  *) echo "guard_scope=all" ;;
esac

# Another module may set the kernel log or the AVC spoof switch at every boot. The page then shows
# who does, instead of offering a copy that the next boot overrides.
# shellcheck source=/dev/null
. "$MODDIR/clients.sh"
echo "susfs_clients=$(cl_clients | tr '\n' ',' | sed 's/,$//')"
echo "owner_enable_log=$(cl_toggle_owner enable_log)"
echo "owner_avc_spoof=$(cl_toggle_owner avc_spoof)"

# What the kernel side reports. The tool is the one the manager ships, so it may be missing.
SUSFS_BIN=${SUSFS_BIN:-/data/adb/ksu/bin/ksu_susfs}
if [ -x "$SUSFS_BIN" ]; then
  echo "susfs_version=$("$SUSFS_BIN" show version 2>/dev/null | head -n 1)"
  echo "susfs_variant=$("$SUSFS_BIN" show variant 2>/dev/null | head -n 1)"
  echo "features=$("$SUSFS_BIN" show enabled_features 2>/dev/null | sed -n 's/^CONFIG_KSU_SUSFS_//p' | tr '\n' ',' | sed 's/,$//')"
fi
# "mount prefixes: 3/64, rescans=0, recorded=0, hidden_by_identity=1886, learned_ids=76"
mounts=$(head -n 1 "$PROC/susfs_hide_mounts" 2>/dev/null)
echo "mount_prefixes=$(printf '%s' "$mounts" | sed -n 's/^mount prefixes: \([0-9]*\/[0-9]*\),.*/\1/p')"
echo "mounts_hidden=$(printf '%s' "$mounts" | sed -n 's/.*hidden_by_identity=\([0-9]*\).*/\1/p')"
