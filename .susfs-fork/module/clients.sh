# SPDX-License-Identifier: GPL-2.0-only
# Which other modules talk to SUSFS, found from what they ship and not from what they are called.
# Sourced by status.sh, check.sh and toggle.sh. It defines functions and runs nothing.
#
# A client is an enabled module whose boot script has a live line (not a comment) naming susfs, and
# the owner of a setting is the first client whose script has a live line running that SUSFS command.
# A provider is an enabled module shipping a kernel object that carries SUSFS code.
#
# Every search runs one grep over all the files it needs, not one per module and stage. On a phone
# with a few dozen modules the per-file form started hundreds of processes each time the WebUI
# opened, and a process start is what costs there. The searches run from inside the modules
# directory so a path never holds a colon, which grep prints between the file and the line.
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

# Reads "<module>/<file>" lines on stdin and prints each module once, in the order first seen.
# The input is grouped by module, as grep prints it for files given module by module.
cl_ids() {
  _last=
  while IFS=: read -r _f _; do
    _i=${_f%%/*}
    [ "$_i" = "$_last" ] || echo "$_i"
    _last=$_i
  done
}

# cl_scan <extended regex> [script...]: the other modules whose boot scripts (or just the named
# ones) have a line matching the pattern that is not a comment.
cl_scan() {
  _pat=$1
  shift
  _stages=${*:-$CL_STAGES}
  _ids=$(cl_others)
  (
    cd "$CL_DIR" 2>/dev/null || exit 0
    set --
    for _m in $_ids; do
      for _s in $_stages; do
        [ -f "$_m/$_s" ] && set -- "$@" "$_m/$_s"
      done
    done
    [ $# -gt 0 ] || exit 0
    grep -H -i -E "$_pat" "$@" 2>/dev/null | grep -v -E '^[^:]*:[[:space:]]*#' | cl_ids
  )
}

# Modules that send SUSFS commands at some boot stage.
cl_clients() {
  cl_scan susfs
}

# The ones among them that send before the module loads on its own, in post-fs-data.
cl_early_clients() {
  cl_scan susfs post-fs-data.sh
}

# cl_owner <susfs command>: the id of the module that runs that command at boot, if any.
cl_owner() {
  cl_scan "(^|[[:space:]])$1([[:space:]]|\$)" | { read -r _o && echo "$_o"; }
}

# The SUSFS command behind each toggle this module keeps.
cl_toggle_owner() {
  case $1 in
    enable_log) cl_owner enable_log ;;
    avc_spoof) cl_owner enable_avc_log_spoofing ;;
  esac
}

# Modules that ship a kernel object with SUSFS code in it: a second implementation, not a client.
# The objects are looked for to three levels down and read in a single grep.
cl_providers() {
  _ids=$(cl_others)
  (
    cd "$CL_DIR" 2>/dev/null || exit 0
    set --
    for _m in $_ids; do
      for _k in "$_m"/*.ko "$_m"/*/*.ko "$_m"/*/*/*.ko; do
        [ -f "$_k" ] && set -- "$@" "$_k"
      done
    done
    [ $# -gt 0 ] || exit 0
    grep -l -a -i -F susfs "$@" 2>/dev/null | cl_ids
  )
}
