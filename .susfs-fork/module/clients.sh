# SPDX-License-Identifier: GPL-2.0-only
# Which other modules talk to SUSFS, found from what they ship and not from what they are called.
# Sourced by status.sh, check.sh and toggle.sh; it defines functions and runs nothing.
#
# A client is an enabled module whose boot script has a live line (not a comment) naming susfs, and
# the owner of a setting is the first client whose script has a live line running that SUSFS command.
# A provider is an enabled module shipping a kernel object that carries SUSFS code.
#
# The caller sets MODDIR. SUSFS_MODULES_DIR moves the search for tests.
CL_DIR=${SUSFS_MODULES_DIR:-${MODDIR%/*}}
CL_SELF=${MODDIR##*/}
CL_STAGES="post-fs-data.sh service.sh boot-completed.sh"

# Ids of the other modules that are neither disabled nor marked for removal.
cl_others() {
  for d in "$CL_DIR"/*/; do
    [ -d "$d" ] || continue
    id=${d%/}
    id=${id##*/}
    [ "$id" != "$CL_SELF" ] || continue
    [ ! -f "$d/disable" ] && [ ! -f "$d/remove" ] || continue
    echo "$id"
  done
}

# cl_live <id> <extended regex> [script...]: does a boot script of that module (or just the named
# ones) have a line matching the pattern that is not a comment?
cl_live() {
  id=$1
  pat=$2
  shift 2
  # shellcheck disable=SC2086
  [ $# -gt 0 ] || set -- $CL_STAGES
  for s in "$@"; do
    [ -f "$CL_DIR/$id/$s" ] || continue
    grep -i -E "$pat" "$CL_DIR/$id/$s" 2>/dev/null | grep -q -v '^[[:space:]]*#' && return 0
  done
  return 1
}

# Modules that send SUSFS commands at some boot stage.
cl_clients() {
  cl_others | while read -r id; do
    cl_live "$id" susfs && echo "$id"
  done
}

# The ones among them that send before the module loads on its own, in post-fs-data.
cl_early_clients() {
  cl_others | while read -r id; do
    cl_live "$id" susfs post-fs-data.sh && echo "$id"
  done
}

# cl_owner <susfs command>: the id of the module that runs that command at boot, if any.
cl_owner() {
  cl_others | while read -r id; do
    cl_live "$id" "(^|[[:space:]])$1([[:space:]]|\$)" && { echo "$id"; break; }
  done
}

# The SUSFS command behind each toggle this module keeps.
cl_toggle_owner() {
  case $1 in
    enable_log) cl_owner enable_log ;;
    avc_spoof) cl_owner enable_avc_log_spoofing ;;
  esac
}

# Modules that ship a kernel object with SUSFS code in it: a second implementation, not a client.
cl_providers() {
  cl_others | while read -r id; do
    [ -n "$(find "$CL_DIR/$id" -maxdepth 3 -name '*.ko' -exec grep -l -a -i susfs {} \; 2>/dev/null | head -n 1)" ] && echo "$id"
  done
}
