#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Load the module in post-fs-data, before the manager sends its SUSFS settings.
#   early.sh status   print early_load=<0|1>
#   early.sh on       install the post-fs-data hook if it is missing, then set the marker
#   early.sh off      remove the marker; the hook stays and exits at once without it
# Without this a module that sets SUSFS options in post-fs-data talks to a kernel that has no
# module yet, and those settings are lost.
MODDIR=${0%/*}
HOOK=${SUSFS_EARLY_HOOK:-/data/adb/post-fs-data.d/00-susfs-guard-lkm.sh}

case $1 in
  status)
    if [ -f "$MODDIR/early_load" ] && [ -f "$HOOK" ]; then echo early_load=1; else echo early_load=0; fi
    ;;
  on)
    if [ -e "$HOOK" ] || [ -L "$HOOK" ]; then
      # A hook that is not ours belongs to something else, as customize.sh also refuses.
      cmp -s "$HOOK" "$MODDIR/early-dispatch.sh" || { echo "another script already owns $HOOK" >&2; exit 1; }
    else
      mkdir -p "${HOOK%/*}" && cp "$MODDIR/early-dispatch.sh" "$HOOK.tmp" && chmod 755 "$HOOK.tmp" &&
        mv "$HOOK.tmp" "$HOOK" || { rm -f "$HOOK.tmp"; echo "cannot install $HOOK" >&2; exit 1; }
    fi
    : >"$MODDIR/early_load" || exit 1
    ;;
  off)
    rm -f "$MODDIR/early_load"
    ;;
  *)
    echo "usage: early.sh status|on|off" >&2
    exit 64
    ;;
esac
