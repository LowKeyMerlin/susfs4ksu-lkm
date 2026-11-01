#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# What the bootloop guard does when it trips, read and changed after install.
#   scope.sh get            print scope=<all|self|none>
#   scope.sh set <scope>    all: disable every module, self: only this one, none: no boot watch
# The installer asks the same question with the volume keys. A file that holds anything else
# reads as all, the safe default, as guard.sh treats it.
MODDIR=${0%/*}
FILE="$MODDIR/guard.scope"

case $1 in
  get)
    case $(cat "$FILE" 2>/dev/null) in
      self) echo scope=self ;;
      none) echo scope=none ;;
      *) echo scope=all ;;
    esac
    ;;
  set)
    case $2 in
      all|self|none) ;;
      *) echo "usage: scope.sh set all|self|none" >&2; exit 64 ;;
    esac
    echo "$2" >"$FILE.tmp" && mv "$FILE.tmp" "$FILE" || { rm -f "$FILE.tmp"; exit 1; }
    ;;
  *)
    echo "usage: scope.sh get|set <scope>" >&2
    exit 64
    ;;
esac
