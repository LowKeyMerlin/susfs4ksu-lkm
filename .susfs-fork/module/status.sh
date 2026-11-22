#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Facts for the WebUI header, one key=value per line. Reads only, writes nothing.
#
# The WebUI waits on this script before it paints the header, so it runs few processes: each fact
# is read with shell builtins where it can be, and an external tool is left for what has no
# builtin form.
MODDIR=${0%/*}
PROC=${SUSFS_PROC:-/proc}
SYS_MODULE=${SUSFS_SYS_MODULE:-/sys/module/susfs_guard_lkm}
EARLY_HOOK=${SUSFS_EARLY_HOOK:-/data/adb/post-fs-data.d/00-susfs-guard-lkm.sh}

# flag <path>: sets _flag to 1 when the path exists, else 0.
flag() { if [ -e "$1" ]; then _flag=1; else _flag=0; fi; }

# first_line <file>: sets _line to the first line of the file, empty when it cannot be read.
first_line() {
  _line=
  [ -r "$1" ] && { read -r _line <"$1" || :; }
}

# module.prop is read once. The first line that sets a key wins, as it did when each key was
# looked up on its own.
p_name=''
p_version=''
p_author=''
p_base=''
p_card=''
if [ -r "$MODDIR/module.prop" ]; then
  while IFS='=' read -r _k _v || [ -n "$_k" ]; do
    case $_k in
      name) p_name=${p_name:-$_v} ;;
      version) p_version=${p_version:-$_v} ;;
      author) p_author=${p_author:-$_v} ;;
      susfsBase) p_base=${p_base:-$_v} ;;
      description) p_card=${p_card:-$_v} ;;
    esac
  done <"$MODDIR/module.prop"
fi
echo "name=$p_name"
echo "version=$p_version"
echo "author=$p_author"
echo "susfs_base=$p_base"
echo "card=$p_card"
first_line "$PROC/sys/kernel/osrelease"
echo "kernel=$_line"
flag "$SYS_MODULE"
echo "loaded=$_flag"
# The hook and the marker are both needed: the marker alone makes post-fs-data.sh skip the load
# and nothing else would run it.
if [ -f "$MODDIR/early_load" ] && [ -f "$EARLY_HOOK" ]; then
  echo "early_load=1"
else
  echo "early_load=0"
fi
flag "$MODDIR/disable"
echo "disabled=$_flag"
flag "$MODDIR/guard.tripped"
echo "guard_tripped=$_flag"
first_line "$MODDIR/guard.fails"
echo "guard_fails=${_line:-0}"
# Anything but self and none reads as all, as guard.sh does.
first_line "$MODDIR/guard.scope"
case $_line in
  self) echo "guard_scope=self" ;;
  none) echo "guard_scope=none" ;;
  *) echo "guard_scope=all" ;;
esac

# csv <words>: the words joined with commas.
csv() {
  set -f
  # shellcheck disable=SC2086
  set -- $1
  set +f
  _csv=
  for _w; do _csv=${_csv:+$_csv,}$_w; done
}

# field <text> <label>: sets _field to the digits that follow the label in the text, else empty.
field() {
  case $1 in
    *"$2"*)
      _field=${1#*"$2"}
      _field=${_field%%[!0-9]*}
      ;;
    *) _field= ;;
  esac
}

# Another module or the root manager itself may set the kernel log or the AVC spoof switch at every
# boot. The page then shows who does, instead of offering a switch the next boot overrides.
# shellcheck source=/dev/null
. "$MODDIR/clients.sh"
csv "$(cl_clients)"
echo "susfs_clients=$_csv"
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
  "$SUSFS_BIN" show version 2>/dev/null | { read -r _l; echo "susfs_version=$_l"; }
  "$SUSFS_BIN" show variant 2>/dev/null | { read -r _l; echo "susfs_variant=$_l"; }
  "$SUSFS_BIN" show enabled_features 2>/dev/null | {
    _f=
    while read -r _l || [ -n "$_l" ]; do
      case $_l in
        CONFIG_KSU_SUSFS_*) _f=${_f:+$_f,}${_l#CONFIG_KSU_SUSFS_} ;;
      esac
    done
    echo "features=$_f"
  }
fi
# "mount prefixes: 3/64, rescans=0, recorded=0, hidden_by_identity=1886, learned_ids=76"
first_line "$PROC/susfs_hide_mounts"
_prefixes=
case $_line in
  "mount prefixes: "*)
    _prefixes=${_line#"mount prefixes: "}
    _prefixes=${_prefixes%%,*}
    case $_prefixes in
      *[!0-9/]*|"") _prefixes= ;;
    esac
    ;;
esac
echo "mount_prefixes=$_prefixes"
field "$_line" "hidden_by_identity="
echo "mounts_hidden=$_field"
# "armed=1 types=1", empty when the layer did not load at all (an older kernel build).
first_line "$PROC/susfs_selinux_ctx"
_armed=
case $_line in
  armed=0*|armed=1*)
    _armed=${_line#armed=}
    _armed=${_armed%"${_armed#?}"}
    ;;
esac
echo "selinux_ctx_armed=$_armed"
field "$_line" "types="
echo "selinux_ctx_types=$_field"
