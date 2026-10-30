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

case $1 in
  get)
    for k in enable_log avc_spoof; do
      echo "$k=$(read_node "$k")"
    done
    ;;
  set)
    is_key "$2" && is_value "$3" || { echo "usage: toggle.sh set enable_log|avc_spoof 0|1" >&2; exit 64; }
    write_node "$2" "$3" || exit $?
    remember "$2" "$3" || exit 1
    ;;
  apply)
    [ -f "$CONF" ] || exit 0
    # A hand-edited or damaged line is skipped, the rest still applies.
    while IFS== read -r k v; do
      is_key "$k" && is_value "$v" || continue
      write_node "$k" "$v" || echo "toggle: $k=$v not applied" >&2
    done < "$CONF"
    exit 0
    ;;
  *)
    echo "usage: toggle.sh get | set <key> <0|1> | apply" >&2
    exit 64
    ;;
esac
