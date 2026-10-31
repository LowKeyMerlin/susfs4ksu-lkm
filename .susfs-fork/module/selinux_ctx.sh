#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Hide an admin-chosen list of SELinux context types from apps (see kernel/susfs_selinux_ctx.c).
# Empty by default: the kernel does not know what any ROM or module calls its own domains, so
# nothing is hidden until an entry is added here.
#   selinux_ctx.sh apply    add each type of the list that the kernel does not hold yet
#   selinux_ctx.sh list     print the types of the list
#   selinux_ctx.sh add <type>      add a type to the list and to the kernel
#   selinux_ctx.sh remove <type>   take a type from both
# The list holds one type per line, '#' starts a comment. Do not add a type that su tooling
# itself transitions into for real work (su, ksu, ...): the kernel-side gate hides a type from
# every app-side process asking about it, it does not know why a given process is asking.
NODE=${CTX_NODE:-/proc/susfs_selinux_ctx}
LIST=${CTX_LIST:-/data/adb/susfs_guard_lkm/selinux_ctx.txt}
CR=$(printf '\r')

seed() {
  [ -f "$LIST" ] && return 0
  mkdir -p "${LIST%/*}" || return 1
  printf '%s\n' \
    '# SELinux context types to hide from apps, one per line. Empty by default.' \
    '# The third field of user:role:TYPE:level, e.g. a type a custom ROM sepolicy adds:' \
    '#   adbroot' \
    >"$LIST"
}

# A type name only ever has to look like a short identifier: SELinux itself restricts type
# names to this shape, and a blank or over-length entry would be ambiguous in the held list.
valid() {
  case $1 in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  [ ${#1} -le 63 ]
}

case $1 in
  list)
    seed && tr -d '\r' <"$LIST" | grep -v -e '^#' -e '^$'
    ;;
  apply)
    [ -w "$NODE" ] || { echo "the module is not loaded" >&2; exit 2; }
    seed || exit 1
    # The node's own lines other than its two fixed ones ("armed=... types=..." and "hits: ...")
    # are the held types, one per line - joined with spaces the same way hide_mounts.sh checks
    # its own held list, which a type name (no spaces, ever) can always be matched against safely.
    held=$(tr -d '\r' <"$NODE" 2>/dev/null | grep -v '^armed=' | grep -v '^hits:' | tr '\n' ' ')
    added=0 kept=0 bad=0 failed=0
    while IFS= read -r t || [ -n "$t" ]; do
      t=${t%"$CR"}
      case $t in ''|'#'*) continue ;; esac
      if ! valid "$t"; then
        bad=$((bad + 1))
      else
        case " $held " in
          *" $t "*) kept=$((kept + 1)) ;;
          *) if echo "add $t" >"$NODE" 2>/dev/null; then added=$((added + 1)); else failed=$((failed + 1)); fi ;;
        esac
      fi
    done <"$LIST"
    echo "added=$added kept=$kept invalid=$bad failed=$failed"
    [ "$failed" -eq 0 ]
    ;;
  add)
    valid "$2" || { echo "not a usable context type" >&2; exit 64; }
    seed || exit 1
    # The kernel goes first, so a type it refuses (the list is full) is not kept in the file.
    if [ -w "$NODE" ]; then
      echo "add $2" >"$NODE" 2>/dev/null || { echo "the kernel refused the type" >&2; exit 1; }
    fi
    tr -d '\r' <"$LIST" | grep -qxF -- "$2" && exit 0
    [ -z "$(tail -c 1 "$LIST")" ] || echo >>"$LIST"
    printf '%s\n' "$2" >>"$LIST"
    ;;
  remove)
    valid "$2" || { echo "not a usable context type" >&2; exit 64; }
    seed || exit 1
    tr -d '\r' <"$LIST" | grep -vxF -- "$2" >"$LIST.tmp"
    mv "$LIST.tmp" "$LIST" || exit 1
    if [ -w "$NODE" ]; then echo "del $2" >"$NODE" 2>/dev/null; fi
    exit 0
    ;;
  *)
    echo "usage: selinux_ctx.sh apply|list|add <type>|remove <type>" >&2
    exit 64
    ;;
esac
