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

# Another module or the root manager itself may set the kernel log or the AVC spoof switch at every
# boot. The page then shows who does, instead of offering a switch the next boot overrides.
# shellcheck source=/dev/null
. "$MODDIR/clients.sh"
echo "susfs_clients=$(cl_clients | tr '\n' ',' | sed 's/,$//')"
# owner_<k> is the module whose boot script runs the command, found from what it ships (no name is
# hardcoded). external_<k> marks a setting that is on in the kernel but set by neither this module
# nor a module we can name (the root manager's own SUSFS screen, or a provider .ko) so the page
# shows it as set elsewhere rather than as a free switch that would be fought every boot.
TOGGLE_CONF=${SUSFS_TOGGLE_CONF:-/data/adb/susfs_guard_lkm/toggles}
toggle_on() { read -r _v _ <"$PROC/susfs_$1" 2>/dev/null && [ "$_v" = 1 ]; }
toggle_ours() { [ -f "$TOGGLE_CONF" ] && grep -q "^$1=" "$TOGGLE_CONF"; }
for _k in enable_log avc_spoof; do
  _owner=$(cl_toggle_owner "$_k")
  echo "owner_$_k=$_owner"
  if [ -z "$_owner" ] && toggle_on "$_k" && ! toggle_ours "$_k"; then
    echo "external_$_k=1"
  else
    echo "external_$_k=0"
  fi
done

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
# "armed=1 types=1", empty when the layer did not load at all (an older kernel build).
ctx=$(head -n 1 "$PROC/susfs_selinux_ctx" 2>/dev/null)
echo "selinux_ctx_armed=$(printf '%s' "$ctx" | sed -n 's/^armed=\([01]\).*/\1/p')"
echo "selinux_ctx_types=$(printf '%s' "$ctx" | sed -n 's/.*types=\([0-9]*\).*/\1/p')"
