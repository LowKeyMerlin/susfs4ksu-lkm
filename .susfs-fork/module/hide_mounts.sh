#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Hide other modules' bind mounts (a hosts file, dex2oat) from apps, by mount point. The module
# covers mounts under /data/adb by itself; anything else has to be named.
#   hide_mounts.sh apply   add each path of the list that the kernel does not hold yet
#   hide_mounts.sh list    print the paths of the list
#   hide_mounts.sh add <path>      add a path to the list and to the kernel
#   hide_mounts.sh remove <path>   take a path from both
# The list holds one absolute path per line, '#' starts a comment. Adding a path rescans the
# mounts, so ones that exist already are picked up. This does not touch the
# hide_sus_mnts_for_non_su_procs switch, which belongs to the manager (BRENE sets it).
NODE=${HIDE_NODE:-/proc/susfs_hide_mounts}
LIST=${HIDE_LIST:-/data/adb/susfs_guard_lkm/hide_mounts.txt}
LEGACY=${HIDE_LEGACY:-/data/adb/hide_module_mounts.txt}
CR=$(printf '\r')
TAB=$(printf '\t')

seed() {
  [ -f "$LIST" ] && return 0
  mkdir -p "${LIST%/*}" || return 1
  if [ -r "$LEGACY" ]; then
    cp "$LEGACY" "$LIST"
  else
    printf '%s\n' '# Mount points to hide from apps, one per line.' \
      '/system/etc/hosts' '/apex/com.android.art/bin/dex2oat64' >"$LIST"
  fi
}

# The kernel takes the rest of the line as the path. Blanks would be ambiguous in the held list,
# and a path that climbs out of its directory names something else.
valid() {
  case $1 in
    /*) ;;
    *) return 1 ;;
  esac
  case $1 in
    *" "*|*"$TAB"*|*/../*|*/..) return 1 ;;
  esac
  [ ${#1} -le 255 ]
}

case $1 in
  list)
    seed && tr -d '\r' <"$LIST" | grep -v -e '^#' -e '^$'
    ;;
  apply)
    [ -w "$NODE" ] || { echo "the module is not loaded" >&2; exit 2; }
    seed || exit 1
    held=$(sed -n 's/^prefixes: //p' "$NODE")
    added=0 kept=0 bad=0 failed=0
    while IFS= read -r p || [ -n "$p" ]; do
      p=${p%"$CR"}
      case $p in ''|'#'*) continue ;; esac
      if ! valid "$p"; then
        bad=$((bad + 1))
      else
        case " $held " in
          *" $p "*) kept=$((kept + 1)) ;;
          *) if echo "add $p" >"$NODE" 2>/dev/null; then added=$((added + 1)); else failed=$((failed + 1)); fi ;;
        esac
      fi
    done <"$LIST"
    echo "added=$added kept=$kept invalid=$bad failed=$failed"
    [ "$failed" -eq 0 ]
    ;;
  add)
    valid "$2" || { echo "not a usable absolute path" >&2; exit 64; }
    seed || exit 1
    # The kernel goes first, so a path it refuses (the list is full) is not kept in the file.
    if [ -w "$NODE" ]; then
      echo "add $2" >"$NODE" 2>/dev/null || { echo "the kernel refused the path" >&2; exit 1; }
    fi
    tr -d '\r' <"$LIST" | grep -qxF -- "$2" && exit 0
    [ -z "$(tail -c 1 "$LIST")" ] || echo >>"$LIST"
    printf '%s\n' "$2" >>"$LIST"
    ;;
  remove)
    valid "$2" || { echo "not a usable absolute path" >&2; exit 64; }
    seed || exit 1
    tr -d '\r' <"$LIST" | grep -vxF -- "$2" >"$LIST.tmp"
    mv "$LIST.tmp" "$LIST" || exit 1
    if [ -w "$NODE" ]; then echo "del $2" >"$NODE" 2>/dev/null; fi
    exit 0
    ;;
  *)
    echo "usage: hide_mounts.sh apply|list|add <path>|remove <path>" >&2
    exit 64
    ;;
esac
