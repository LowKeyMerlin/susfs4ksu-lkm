#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Install another release of this module. The zip is installed with ksud like a manual install and
# takes effect at the next reboot.
#   update.sh releases             print the release list of the repository as the GitHub API gives it
#   update.sh install TAG SHA256   fetch the zip of release TAG, check it against SHA256, install it
#   update.sh status               state=<idle|downloading|installing|installed|failed> and message=<text>
#   update.sh reboot               restart the device
# install returns at once and the work goes on in the background, status reports its progress.
MODDIR=${0%/*}
# The repository the updateJson of module.prop names as well. The page makes no network call of its
# own, this script is the only thing here that talks to GitHub.
RELEASES=${UPDATE_RELEASES:-https://github.com/LowKeyMerlin/susfs4ksu-lkm/releases/download}
API=${UPDATE_API:-https://api.github.com/repos/LowKeyMerlin/susfs4ksu-lkm/releases?per_page=30}
LIST=${UPDATE_LIST:-/data/local/tmp/susfs_releases.json}
STATE=${UPDATE_STATE:-$MODDIR/update.state}
LOG=${UPDATE_LOG:-$MODDIR/update.log}
ZIP=${UPDATE_ZIP:-/data/local/tmp/susfs_update.zip}
# Held while a run is going. /dev is empty after a boot, so a killed run cannot block the next one.
LOCK=${UPDATE_LOCK:-/dev/.susfs_update.lock}
KSUD=${UPDATE_KSUD:-/data/adb/ksud}
CURL=${UPDATE_CURL:-curl}
BUSYBOX=${UPDATE_BUSYBOX:-/data/adb/ksu/bin/busybox}
SH=${UPDATE_SH:-/system/bin/sh}
umask 077

state() { printf 'state=%s\nmessage=%s\n' "$1" "$2" >"$STATE"; }

# Both values end up in a URL and on a command line, so only what a release uses is accepted.
valid_tag() {
  case $1 in v[0-9]*.[0-9]*.[0-9]*) ;; *) return 1 ;; esac
  case $1 in *[!A-Za-z0-9.-]*) return 1 ;; esac
}
valid_sha() {
  [ "${#1}" -eq 64 ] || return 1
  case $1 in *[!0-9a-f]*) return 1 ;; esac
}

# The manager ships a busybox, curl is not on every Android. The third argument bounds the time.
fetch() {
  if command -v "$CURL" >/dev/null 2>&1; then
    "$CURL" -fsSL --connect-timeout 15 --max-time "${3:-900}" -o "$2" "$1"
  elif [ -x "$BUSYBOX" ]; then
    "$BUSYBOX" wget -q -O "$2" "$1"
  else
    echo "neither curl nor $BUSYBOX is available"
    return 127
  fi
}

work() {
  tag=$1
  want=$2
  state downloading "$tag"
  if ! fetch "$RELEASES/$tag/ksu_susfs_lkm-module-$tag-arm64.zip" "$ZIP" >>"$LOG" 2>&1; then
    state failed "The download failed. See update.log in the module folder."
    return 1
  fi
  got=$(sha256sum "$ZIP" 2>/dev/null)
  if [ "${got%% *}" != "$want" ]; then
    state failed "The download does not match its checksum, nothing was installed."
    return 1
  fi
  state installing "$tag"
  if ! "$KSUD" module install "$ZIP" >>"$LOG" 2>&1; then
    state failed "The installer failed. See update.log in the module folder."
    return 1
  fi
  state installed "$tag"
}

case $1 in
  releases)
    trap 'rm -f "$LIST"' EXIT
    fetch "$API" "$LIST" 30 >&2 || { echo "could not fetch the release list" >&2; exit 1; }
    cat "$LIST"
    ;;
  install)
    valid_tag "$2" && valid_sha "$3" || { echo "usage: update.sh install TAG SHA256" >&2; exit 64; }
    mkdir "$LOCK" 2>/dev/null || { echo "an update is already running" >&2; exit 75; }
    : >"$LOG"
    state downloading "$2"
    # Detached, so the caller does not wait on it.
    ("$SH" "$0" work "$2" "$3" </dev/null >/dev/null 2>&1 &)
    ;;
  work)
    valid_tag "$2" && valid_sha "$3" || exit 64
    trap 'rm -f "$ZIP"; rmdir "$LOCK" 2>/dev/null' EXIT
    work "$2" "$3"
    ;;
  status)
    if [ -f "$STATE" ]; then cat "$STATE"; else echo "state=idle"; fi
    ;;
  reboot)
    exec "${UPDATE_REBOOT:-reboot}"
    ;;
  *)
    echo "usage: update.sh releases|install TAG SHA256|status|reboot" >&2
    exit 64
    ;;
esac
