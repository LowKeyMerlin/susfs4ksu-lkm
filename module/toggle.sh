#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# The only writer of the on/off /proc nodes and of the file that keeps them across boots.
#   toggle.sh get                 print "<key>=<0|1|unavailable>" for each toggle
#   toggle.sh set <key> <0|1>     write the node, then remember it
#   toggle.sh apply               write every remembered value (load.sh runs this after a load)
# Only keys the user set are stored, so a toggle never touched keeps the kernel's own default.
# The WebUI builds its command line from constants, but a script that writes /proc as root
# checks its own arguments anyway.
PROC=${TOGGLE_PROC:-/proc}
CONF=${TOGGLE_CONF:-/data/adb/susfs_guard_lkm/toggles}

# Another module may run the same SUSFS command at every boot; apply leaves that one to it, so a
# value kept here cannot flip the setting for the moment before the other module overrides it.
# The helper ships beside this script; without it nothing counts as owned.
MODDIR=${0%/*}
if [ -r "$MODDIR/clients.sh" ]; then
  # shellcheck source=/dev/null
  . "$MODDIR/clients.sh"
else
  cl_toggle_owner() { :; }
fi

is_key() {
  case $1 in
    enable_log|avc_spoof) return 0 ;;
  esac
  return 1
}

is_value() {
  case $1 in
    0|1) return 0 ;;
  esac
  return 1
}

node_path() { echo "$PROC/susfs_$1"; }

# The nodes appear only while the module is loaded.
write_node() {
  n=$(node_path "$1")
  [ -w "$n" ] || return 2
  echo "$2" > "$n" 2>/dev/null || return 1
}

# A node reads "0" or "1 (su_sid=...)": the first word is the state.
read_node() {
  n=$(node_path "$1")
  [ -r "$n" ] || { echo unavailable; return; }
  read -r first _ < "$n" 2>/dev/null
  is_value "$first" && echo "$first" || echo unavailable
}

remember() {
  umask 077
  mkdir -p "${CONF%/*}" || return 1
  tmp="$CONF.tmp"
  { [ -f "$CONF" ] && grep -v "^$1=" "$CONF"; echo "$1=$2"; } > "$tmp" || return 1
  mv "$tmp" "$CONF"
}

# Read-only: selinux_hide is never a key is_key()/write_node() accept, so "set selinux_hide ..."
# is refused the same way an unknown key is. There is nothing to write - see susfs_selinux_hide.c.
read_selinux_hide() {
  n=$(node_path selinux_hide)
  [ -r "$n" ] || { echo unavailable; return; }
  read -r line _ < "$n" 2>/dev/null
  case "$line" in
    native_supported=1*) echo native ;;
    native_supported=0*) echo none ;;
    *) echo unavailable ;;
  esac
}

case $1 in
  get)
    for k in enable_log avc_spoof; do
      echo "$k=$(read_node "$k")"
    done
    echo "selinux_hide=$(read_selinux_hide)"
    ;;
  set)
    is_key "$2" && is_value "$3" || { echo "usage: toggle.sh set enable_log|avc_spoof 0|1" >&2; exit 64; }
    write_node "$2" "$3" || exit $?
    remember "$2" "$3" || exit 1
    ;;
  apply)
    [ -f "$CONF" ] || exit 0
    # A hand-edited or damaged line is skipped, the rest still applies.  The `|| [ -n "$k" ]`
    # keeps the last line when a hand-edited file ends without a trailing newline: read returns
    # non-zero at EOF but still fills k/v, so without it that line would be dropped.
    while IFS='=' read -r k v || [ -n "$k" ]; do
      is_key "$k" && is_value "$v" || continue
      [ -z "$(cl_toggle_owner "$k")" ] || continue
      write_node "$k" "$v" || echo "toggle: $k=$v not applied" >&2
    done < "$CONF"
    exit 0
    ;;
  *)
    echo "usage: toggle.sh get | set <key> <0|1> | apply" >&2
    exit 64
    ;;
esac
