#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Host test of update.sh. The real script runs against a scratch directory, with the download tool,
# ksud and reboot stubbed.
#
# Usage: update_test.sh [SHELL]   (default: sh)
# Run it with dash and busybox sh as well, Android's shell is neither bash nor GNU sh.

SH=${1:-sh}
SRC=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
M=$T/module
pass=0
fail=0

check() {
  if eval "$2"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1"
  fi
}

# Write an executable stub. The interpreter is the shell under test, Android has no /bin/sh.
put() {
  { printf '#!%s\n' "$UPDATE_SH"; cat; } >"$1"
  chmod 0755 "$1"
}

TAG=v1.2.3
URL=https://example.test/rel/$TAG/ksu_susfs_lkm-module-$TAG-arm64.zip
printf 'zip bytes' >"$T/fixture.zip"
SHA=$(sha256sum "$T/fixture.zip" | cut -d' ' -f1)
BAD=0000000000000000000000000000000000000000000000000000000000000000

mkdir -p "$M" "$T/bin"
cp "$SRC/update.sh" "$M/"
export T UPDATE_SH="$(command -v "$SH")"
export UPDATE_RELEASES=https://example.test/rel UPDATE_API=https://example.test/api/releases UPDATE_LIST="$T/list"
export UPDATE_STATE="$T/state" UPDATE_LOG="$T/log" UPDATE_ZIP="$T/zip" UPDATE_LOCK="$T/lock"
export UPDATE_CURL="$T/bin/curl" UPDATE_KSUD="$T/bin/ksud" UPDATE_REBOOT="$T/bin/reboot"
export UPDATE_BUSYBOX="$T/bin/busybox"

# curl copies the fixture unless told to fail, and records the call. The release list is JSON.
put "$T/bin/curl" <<'EOF'
echo "$*" >>"$T/curl.log"
[ ! -e "$T/curl.fail" ] || exit 22
eval "out=\${$(($# - 1))}"
case $* in
  *api/releases) printf '[{"tag_name":"v1.2.3"}]' >"$out" ;;
  *) cp "$T/fixture.zip" "$out" ;;
esac
EOF
put "$T/bin/ksud" <<'EOF'
echo "$*" >>"$T/ksud.log"
[ -e "$T/zip" ] && echo "had the zip" >>"$T/ksud.log"
[ ! -e "$T/ksud.fail" ]
EOF
put "$T/bin/reboot" <<'EOF'
: >"$T/rebooted"
EOF

update() { "$SH" "$M/update.sh" "$@" >"$T/out" 2>&1; rc=$?; }
reset() { rm -rf "$T/state" "$T/log" "$T/zip" "$T/lock" "$T/curl.log" "$T/ksud.log" "$T/curl.fail" "$T/ksud.fail" "$T/rebooted"; }
# The background run is finished when it has left a state that is not a step.
settle() {
  n=0
  while [ "$n" -lt 30 ]; do
    case $(sed -n 's/^state=//p' "$T/state" 2>/dev/null) in installed | failed) break ;; esac
    sleep 1
    n=$((n + 1))
  done
  # The lock goes after the last state is written.
  n=0
  while [ -d "$T/lock" ] && [ "$n" -lt 10 ]; do
    sleep 1
    n=$((n + 1))
  done
}
state() { sed -n 's/^state=//p' "$T/state"; }
message() { sed -n 's/^message=//p' "$T/state"; }

reset
update status
check "status without a run says idle" 'grep -qx "state=idle" "$T/out"'

# Nothing that is not a release tag and a checksum gets as far as a download.
for tag in "" v1 1.2.3 'v1.2.3;reboot' 'v1.2.3 x' ../v1.2.3 'v1.2.3/../x' 'v1.2.3$(id)'; do
  update install "$tag" "$SHA"
  check "tag '$tag' is refused" '[ "$rc" -eq 64 ] && [ ! -e "$T/curl.log" ] && [ ! -e "$T/state" ] && [ ! -d "$T/lock" ]'
done
for sha in "" abc "${SHA}0" "$(printf '%s' "$SHA" | tr a-f A-F)" "${SHA%?}g"; do
  update install "$TAG" "$sha"
  check "checksum '$sha' is refused" '[ "$rc" -eq 64 ] && [ ! -e "$T/curl.log" ] && [ ! -e "$T/state" ] && [ ! -d "$T/lock" ]'
done
update install "$TAG"
check "a missing checksum is refused" '[ "$rc" -eq 64 ] && [ ! -e "$T/curl.log" ] && [ ! -d "$T/lock" ]'
update frobnicate
check "an unknown command is refused" '[ "$rc" -eq 64 ] && [ ! -e "$T/curl.log" ]'

reset
update install "$TAG" "$SHA"
check "install returns success" '[ "$rc" -eq 0 ]'
settle
check "a good install ends installed" '[ "$(state)" = installed ]'
check "the message names the tag" '[ "$(message)" = "$TAG" ]'
check "the zip is fetched from the release of the tag" 'grep -q -- "$URL" "$T/curl.log"'
check "ksud installs the verified zip" 'grep -qx "module install $T/zip" "$T/ksud.log" && grep -qx "had the zip" "$T/ksud.log"'
check "the zip is removed" '[ ! -e "$T/zip" ]'
check "the lock is released" '[ ! -d "$T/lock" ]'

reset
mkdir "$T/lock"
update install "$TAG" "$SHA"
check "a second install while one runs is refused" '[ "$rc" -eq 75 ] && [ ! -e "$T/curl.log" ] && [ -d "$T/lock" ]'
rmdir "$T/lock"

reset
update install "$TAG" "$BAD"
settle
check "a zip that does not match the checksum fails" '[ "$(state)" = failed ]'
check "the mismatch is not installed" '[ ! -e "$T/ksud.log" ] && [ ! -e "$T/zip" ] && [ ! -d "$T/lock" ]'
check "the message says it was the checksum" 'message | grep -q checksum'

reset
: >"$T/curl.fail"
update install "$TAG" "$SHA"
settle
check "a failed download fails" '[ "$(state)" = failed ] && [ ! -e "$T/ksud.log" ]'
check "the message points at the log" 'message | grep -q update.log'

reset
: >"$T/ksud.fail"
update install "$TAG" "$SHA"
settle
check "a failed installer fails" '[ "$(state)" = failed ] && [ ! -e "$T/zip" ]'

# Without curl the manager's busybox does the download.
reset
put "$T/bin/busybox" <<'EOF'
echo "$*" >>"$T/curl.log"
cp "$T/fixture.zip" "$4"
EOF
(UPDATE_CURL=$T/bin/missing; export UPDATE_CURL; update install "$TAG" "$SHA")
settle
check "busybox wget is used when curl is missing" '[ "$(state)" = installed ] && grep -q -- "wget -q -O $T/zip $URL" "$T/curl.log"'

reset
rm -f "$T/bin/busybox"
(UPDATE_CURL=$T/bin/missing; export UPDATE_CURL; update install "$TAG" "$SHA")
settle
check "no download tool fails with the reason in the log" '[ "$(state)" = failed ] && grep -q "neither curl" "$T/log"'

reset
update releases
check "releases prints the list the API returned" '[ "$rc" -eq 0 ] && [ "$(cat "$T/out")" = "[{\"tag_name\":\"v1.2.3\"}]" ]'
check "the list is asked from the API url" 'grep -q -- "https://example.test/api/releases" "$T/curl.log"'
check "the list file is removed" '[ ! -e "$T/list" ]'
: >"$T/curl.fail"
update releases
check "a failed list fetch fails with nothing printed on stdout" '[ "$rc" -eq 1 ] && ! grep -q tag_name "$T/out"'
rm -f "$T/curl.fail"

reset
update reboot
check "reboot calls reboot" '[ -e "$T/rebooted" ]'

echo "update_test ($SH): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
