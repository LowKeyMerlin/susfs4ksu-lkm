#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Host test of the bootloop guard. Runs the real load.sh, service.sh and guard.sh against a
# scratch module directory, with getprop, date, rmmod, pidof, reboot, the SUSFS probe and the
# loader stubbed.
#
# Usage: guard_test.sh [SHELL]   (default: sh)
# Run it with dash and busybox sh as well, Android's shell is neither bash nor GNU sh.

SH=${1:-sh}
SRC=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
M=$T/modules/susfs_guard_lkm
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
  { printf '#!%s\n' "$GUARD_SH"; cat; } >"$1"
  chmod 0755 "$1"
}

# A module directory in the state of a fresh install.
fresh() {
  rm -rf "$T/modules" "$T/bin" "$T/props" "$T/pids" "$T/sys" "$T"/probe_rc "$T"/load_rc "$T"/rmmod.log "$T"/reboot.log "$T"/skip
  mkdir -p "$M/bin" "$T/bin" "$T/props" "$T/pids" "$T/modules/other_a" "$T/modules/other_b" "$T/modules/with space"
  : >"$T/modules/other_b/disable"
  echo "not a module" >"$T/modules/notes.txt"
  cp "$SRC/guard.sh" "$SRC/load.sh" "$SRC/service.sh" "$M/"
  printf 'description=initial\nsusfsBase=2.3.0\n' >"$M/module.prop"
  rm -f "$T/dmesg.out" "$T/hook"
  echo "boot-A" >"$T/boot_id"
  echo "6.6.30-android15-8-g0123456-ab1" >"$T/osrelease"
  echo 1800000000 >"$T/now"
  echo 1 >"$T/props/sys.boot_completed"

  cat >"$M/kmi.sh" <<'EOF'
select_kmi() { echo android15-6.6; }
EOF
  put "$M/bin/susfs_sc" <<'EOF'
[ ! -f "$T/probe_rc" ] || exit "$(cat "$T/probe_rc")"
[ -d "$GUARD_SYS_MODULE" ] && exit 0
exit 1
EOF
  cat >"$M/load.upstream.sh" <<'EOF'
[ ! -f "$T/load_rc" ] || exit "$(cat "$T/load_rc")"
mkdir -p "$GUARD_SYS_MODULE"
EOF
  put "$T/bin/getprop" <<'EOF'
[ -f "$T/props/$1" ] && cat "$T/props/$1"
exit 0
EOF
  put "$T/bin/date" <<'EOF'
case $1 in +%s) cat "$T/now" ;; *) echo fake-date ;; esac
EOF
  put "$T/bin/rmmod" <<'EOF'
echo "$@" >>"$T/rmmod.log"
rm -rf "$GUARD_SYS_MODULE"
EOF
  put "$T/bin/dmesg" <<'EOF'
cat "$T/dmesg.out" 2>/dev/null
exit 0
EOF
  put "$T/bin/reboot" <<'EOF'
echo reboot >>"$T/reboot.log"
EOF
  # One file per process name holds its pids, a missing file means it is not running.
  put "$T/bin/pidof" <<'EOF'
for name in "$@"; do cat "$T/pids/$name" 2>/dev/null; done
exit 0
EOF
}

env_setup() {
  export T MODDIR="$M" PATH="$T/bin:$PATH"
  export GUARD_SH="$(command -v "$SH")"
  export GUARD_BOOT_ID_FILE="$T/boot_id" GUARD_OSRELEASE_FILE="$T/osrelease"
  export GUARD_SYS_MODULE="$T/sys/susfs_guard_lkm"
  export GUARD_DMESG="$T/bin/dmesg" GUARD_EARLY_HOOK="$T/hook"
  export GUARD_SETTLE=0 GUARD_POLL=1 GUARD_BOOT_WAIT=2
  export GUARD_SKIP_FILE="$T/skip" GUARD_REBOOT="$T/bin/reboot" GUARD_PIDOF="$T/bin/pidof"
}
env_setup

boot() { echo "$1" >"$T/boot_id"; }
# What the boot after this one reads as the reason the last one ended. Empty means none.
reason() { printf '%s' "$1" >"$T/props/sys.boot.reason"; }
waitfor() {
  n=0
  while [ ! -e "$1" ] && [ "$n" -lt 60 ]; do
    sleep 1
    n=$((n + 1))
  done
}
load() { "$SH" "$M/load.sh" >/dev/null 2>&1; }
# The next boot, which comes up with nothing loaded.
failboot() {
  boot "$1"
  rm -rf "$T/sys"
  load
}
# Run the settle job and give it a few seconds to clear the marker.
settle() {
  "$SH" "$M/service.sh" >/dev/null 2>&1
  n=0
  while [ -f "$M/guard.armed" ] && [ "$n" -lt 60 ]; do
    sleep 1
    n=$((n + 1))
  done
}
loaded() { [ -d "$GUARD_SYS_MODULE" ]; }
armed() { [ -f "$M/guard.armed" ]; }
tripped() { [ -f "$M/guard.tripped" ]; }
disabled() { [ -f "$M/disable" ]; }
described() { grep -q "^description=$1" "$M/module.prop"; }

# Some shells (busybox ash built with applet preference) run their own date and rmmod instead of
# the stubs on PATH. The tests that need a controlled clock or a recorded rmmod are skipped there.
fresh
"$SH" -c 'rmmod probe' >/dev/null 2>&1
if [ "$("$SH" -c 'date +%s')" = "$(cat "$T/now")" ] && [ -s "$T/rmmod.log" ]; then
  stubs_ok=yes
else
  stubs_ok=no
  echo "note: $SH ignores PATH stubs for date or rmmod, clock and unload tests are skipped"
fi

# A boot that loads and settles normally.
fresh
load
check "first load loads the module" loaded
check "first load arms the marker" armed
check "first load does not trip" '! tripped'
settle
check "settling clears the marker" '! armed'
check "settling leaves the module enabled" '! disabled'

# Loading again in the same boot (early loader and post-fs-data) must not stack or trip.
fresh
load
load
check "same boot, second load keeps the module loaded" loaded
check "same boot, second load does not trip" '! tripped'

# One boot that never finished is counted and the module loads again. Two in a row disable the
# module and load nothing.
fresh
load
failboot boot-B1
check "one unfinished boot does not trip" '! tripped'
check "one unfinished boot still loads" loaded
check "one unfinished boot is counted" '[ "$(cat "$M/guard.fails")" = 1 ]'
failboot boot-B
check "unsettled boot trips the guard" tripped
check "unsettled boot disables the module" disabled
check "unsettled boot loads nothing" '! loaded'
check "unsettled boot clears the marker" '! armed'
check "trip reason is recorded" 'grep -q "ended early" "$M/guard.tripped"'
check "trip is shown on the module card" 'described "Disabled · bootloop guard tripped"'
check "trip disables other modules by default" '[ -f "$T/modules/other_a/disable" ]'
check "trip disables a module with a space in its name" '[ -f "$T/modules/with space/disable" ]'
check "trip lists the modules it disabled" '[ "$(sort "$M/guard.disabled" | tr "\n" ,)" = "other_a,with space," ]'
check "trip leaves files in the modules directory alone" '[ "$(cat "$T/modules/notes.txt")" = "not a module" ]'
check "trip tells the module card about the other modules" 'described ".*other modules disabled too"'

# A disabled module is left alone on every later boot, and enabling it again starts over.
boot boot-C
load
check "disabled module is not loaded on a later boot" '! loaded'
check "disabled module keeps the trip record" tripped
rm -f "$M/disable"
boot boot-D
load
check "re-enabled module loads" loaded
check "re-enabled module clears the trip record" '! tripped'
check "re-enabled module arms again" armed

# A boot that settles does not count against the next one.
settle
boot boot-E
rm -rf "$T/sys"
load
check "settled boot does not trip the next" '! tripped'
check "next boot loads" loaded

# A boot that reached boot_completed and was rebooted by the user before the settle time ended is
# not a failed boot. Without a request, or with the record of another boot, it still is.
reached() {
  ( MODDIR=$M GUARD_SETTLE=30; . "$M/guard.sh"; guard_settle ) >/dev/null 2>&1 &
  pid=$!
  n=0
  while [ ! -f "$M/guard.up" ] && [ "$n" -lt 60 ]; do
    sleep 1
    n=$((n + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}
fresh
load
reached
check "boot_completed is recorded before the settle time" '[ -f "$M/guard.up" ]'
check "the marker stays armed until the boot has settled" armed
reason reboot,userrequested
boot boot-R
rm -rf "$T/sys"
load
check "reboot after boot_completed does not trip" '! tripped'
check "reboot after boot_completed loads the module" loaded
check "reboot after boot_completed arms for the new boot" '[ "$(cat "$M/guard.armed")" = boot-R ]'
check "reboot after boot_completed drops the old record" '[ ! -f "$M/guard.up" ]'
fresh
load
echo boot-other >"$M/guard.up"
failboot boot-S1
echo boot-other >"$M/guard.up"
failboot boot-S
check "a record of another boot does not excuse the marker" tripped

# A boot that finished and ended on request starts the count over, so cut-off boots that are not
# in a row never trip.
fresh
load
failboot boot-P1
check "a cut-off boot is counted" '[ "$(cat "$M/guard.fails")" = 1 ]'
reached
reason reboot,userrequested
failboot boot-P2
check "a finished boot that ended on request clears the count" '[ ! -f "$M/guard.fails" ]'
reason
failboot boot-P3
check "cut-off boots that are not in a row keep the guard quiet" '! tripped'
check "the count restarts after a request" '[ "$(cat "$M/guard.fails")" = 1 ]'
fresh
load
echo junk >"$M/guard.fails"
failboot boot-J1
check "a damaged count restarts at one" '[ "$(cat "$M/guard.fails")" = 1 ]'
check "a damaged count does not trip" '! tripped'
fresh
export GUARD_FAILS=3
load
failboot boot-T1
failboot boot-T2
check "GUARD_FAILS raises the number of boots" '! tripped'
failboot boot-T3
check "GUARD_FAILS trips at its value" tripped
unset GUARD_FAILS
fresh
load
settle
check "settling removes the boot_completed record" '[ ! -f "$M/guard.up" ]'

# Settling waits for boot_completed and leaves the marker armed when it never comes.
fresh
load
rm -f "$T/props/sys.boot_completed"
settle
check "no boot_completed keeps the marker armed" armed
echo 1 >"$T/props/sys.boot_completed"
settle
check "boot_completed later clears it" '! armed'

# A load whose marker belongs to a different boot is never cleared by that boot's settle.
fresh
load
boot boot-other
settle
check "another boot id does not clear the marker" armed

# The reason lists below are long and every case starts many processes. GUARD_TEST_QUICK keeps the
# first few for a slow target such as an emulated Android guest, the host runs the full lists.
if [ -n "${GUARD_TEST_QUICK:-}" ]; then
  requested="reboot,shell reboot,"
  unclean="- reboot kernel_panic"
else
  requested="reboot,shell reboot, reboot,userrequested shutdown,userrequested recovery bootloader REBOOT,SHELL"
  unclean="- reboot cold unknown kernel_panic watchdog,sw reboot,hung reboot,rescueparty"
fi

# Whatever the vendor calls it, a reboot someone asked for never counts, even many in a row.
for r in $requested; do
  fresh
  load
  for n in 1 2 3 4; do
    reached
    reason "$r"
    failboot "boot-$n"
  done
  check "reason '$r' is a request, four reboots in a row do not trip" '! tripped'
  check "reason '$r' leaves no count" '[ ! -f "$M/guard.fails" ]'
  check "reason '$r' still loads" loaded
done

# Anything else ends the boot without being asked: two in a row trip, finished or not.
for r in $unclean; do
  [ "$r" != - ] || r=
  for done_boot in reached true; do
    fresh
    load
    $done_boot
    reason "$r"
    failboot boot-1
    check "reason '$r' ($done_boot) is counted once" '[ "$(cat "$M/guard.fails")" = 1 ]'
    $done_boot
    reason "$r"
    failboot boot-2
    check "reason '$r' ($done_boot) trips on the second" tripped
  done
done

# A boot that never finished and ended on request is neither good nor bad, the user may have
# rebooted a stuck boot by hand.
fresh
load
reason reboot,shell
failboot boot-1
check "an unfinished boot that ended on request is not counted" '[ ! -f "$M/guard.fails" ]'
reason
failboot boot-2
check "and it does not excuse the next cut-off boot" '[ "$(cat "$M/guard.fails")" = 1 ]'

# ro.boot.bootreason is used when sys.boot.reason is empty.
fresh
load
reached
echo reboot,shell >"$T/props/ro.boot.bootreason"
failboot boot-1
check "the bootloader reason is used when there is no system one" '[ ! -f "$M/guard.fails" ]'

# A boot that settled is good, whatever ends it later.
fresh
load
settle
reason reboot
failboot boot-1
check "a settled boot is not counted when it ends" '[ ! -f "$M/guard.fails" ]'

# A vendor that reports a plain "reboot" for a user reboot is covered by the shutdown the watcher
# saw begin.
fresh
load
GUARD_SETTLE=30 "$SH" "$M/service.sh" >/dev/null 2>&1
waitfor "$M/guard.up"
echo reboot,userrequested >"$T/props/sys.powerctl"
waitfor "$M/guard.clean"
check "the watcher records a shutdown" '[ "$(cat "$M/guard.clean")" = boot-A ]'
rm -f "$T/props/sys.powerctl"
for n in 1 2 3; do
  reason reboot
  failboot "boot-$n"
  check "a recorded shutdown outweighs a plain reboot reason ($n)" '[ ! -f "$M/guard.fails" ]'
  GUARD_SETTLE=30 "$SH" "$M/service.sh" >/dev/null 2>&1
  waitfor "$M/guard.up"
  echo reboot >"$T/props/sys.powerctl"
  waitfor "$M/guard.clean"
  rm -f "$T/props/sys.powerctl"
done
check "repeated recorded shutdowns do not trip" '! tripped'

# A crash reason wins over a recorded shutdown.
fresh
load
printf '%s' boot-A >"$M/guard.clean"
reason kernel_panic
failboot boot-1
check "a panic reason is counted even with a recorded shutdown" '[ "$(cat "$M/guard.fails")" = 1 ]'
# A record of another boot is not this boot's shutdown.
fresh
load
printf '%s' boot-other >"$M/guard.clean"
reason reboot
failboot boot-1
check "the shutdown record of another boot does not count" '[ "$(cat "$M/guard.fails")" = 1 ]'

# A shutdown between two polls reaches the watcher as TERM. Any other TERM records nothing.
term_job() {
  ( MODDIR=$M GUARD_SETTLE=300 GUARD_POLL=30; . "$M/guard.sh"; guard_settle ) >/dev/null 2>&1 &
  pid=$!
  waitfor "$M/guard.up"
  [ -z "$1" ] || echo "$1" >"$T/props/sys.powerctl"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}
fresh
load
term_job reboot
check "TERM during a shutdown records it" '[ "$(cat "$M/guard.clean" 2>/dev/null)" = boot-A ]'
fresh
load
term_job
check "TERM outside a shutdown records nothing" '[ ! -f "$M/guard.clean" ]'

# A userspace reboot runs the watcher again in the same boot, the old record is dropped.
fresh
load
printf '%s' boot-A >"$M/guard.clean"
settle
check "a new watcher drops a stale shutdown record" '[ ! -f "$M/guard.clean" ]'

# A restart replaces a pid. A process that only appears or only ends is not one.
fresh
replaced() { ( MODDIR=$M; . "$M/guard.sh"; guard_replaced "$1" "$2" ); }
check "a new pid for the same process is a restart" 'replaced "100" "101"'
check "one of two pids replaced is a restart" 'replaced "100 300" "100 301"'
check "a second pid appearing is not a restart" '! replaced "100" "100 300"'
check "a pid ending is not a restart" '! replaced "100 300" "100"'
check "the same pids are not a restart" '! replaced "100 300" "100 300"'

# zygote or SystemUI restarting over and over trips the guard and reboots.
# Change the pid of a process and wait until the watcher has logged the restart, so the test does
# not depend on how fast the machine is. $3 is the number of restarts logged once it has seen this.
bump() {
  echo "$2" >"$T/pids/$1"
  n=0
  while c=$(grep -c 'restart seen' "$M/guard.log" 2>/dev/null || true); [ "${c:-0}" -lt "$3" ] && [ "$n" -lt 40 ]; do
    sleep 1
    n=$((n + 1))
  done
}
# What the watcher saw, printed when a restart test fails so the cause is in the log.
churn_debug() {
  echo "--- churn debug"
  tail -n 15 "$M/guard.log" 2>/dev/null
  echo "pidof stub: $(command -v "$GUARD_PIDOF")"
  echo "zygote64 pids: $("$GUARD_PIDOF" zygote64 2>&1)"
  echo "guard_pids: [$( ( MODDIR=$M; . "$M/guard.sh"; guard_pids zygote64 zygote ) 2>&1)]"
  echo "watchers: $(ps -A 2>/dev/null | grep -c ' sh$')"
  echo "--- end churn debug"
}
churn_job() {
  GUARD_SETTLE=300 GUARD_CRASHES=${1:-3} "$SH" "$M/service.sh" >/dev/null 2>&1
  waitfor "$M/guard.up"
}
fresh
load
echo 100 >"$T/pids/zygote64"
echo 200 >"$T/pids/com.android.systemui"
churn_job 3
bump zygote64 101 1
bump zygote64 102 2
bump zygote64 103 3
waitfor "$M/guard.tripped"
waitfor "$T/reboot.log"
[ -f "$M/guard.tripped" ] || churn_debug
check "zygote restarting trips the guard" tripped
check "zygote restarting reboots" '[ -s "$T/reboot.log" ]'
check "the churn reason is recorded" 'grep -q "restarted 3 times" "$M/guard.tripped"'
check "the churn trip disables the module" disabled
check "the churn trip disables other modules" '[ -f "$T/modules/other_a/disable" ]'
fresh
load
echo 100 >"$T/pids/zygote64"
echo 200 >"$T/pids/com.android.systemui"
churn_job 3
bump com.android.systemui 201 1
bump com.android.systemui 202 2
bump com.android.systemui 203 3
waitfor "$M/guard.tripped"
check "SystemUI restarting trips the guard" tripped

# One restart, a process that is gone for a moment and then back, or no pidof are not crashes.
fresh
load
echo 100 >"$T/pids/zygote64"
echo 200 >"$T/pids/com.android.systemui"
churn_job 3
bump com.android.systemui 201 1
bump com.android.systemui 202 2
rm -f "$T/pids/zygote64"
sleep 3
echo 100 >"$T/pids/zygote64"
sleep 3
echo 300 >"$T/pids/zygote"
sleep 3
rm -f "$T/pids/zygote"
sleep 3
check "a second zygote appearing and ending is not a restart" '! grep -q "restart seen: zygote" "$M/guard.log"'
check "two restarts and a gap do not trip" '! tripped'
check "and do not reboot" '[ ! -f "$T/reboot.log" ]'
# The watcher stops when its marker is gone.
rm -f "$M/guard.armed"
fresh
load
( export GUARD_PIDOF=/nonexistent; settle )
check "no pidof still settles" '! armed'
check "no pidof does not trip" '! tripped'

# A skip file keeps the module from loading, without a trip or any state.
fresh
: >"$T/skip"
load
check "skip file loads nothing" '! loaded'
check "skip file does not arm" '! armed'
check "skip file does not trip" '! tripped'
rm -f "$T/skip"
load
check "removing the skip file loads again" loaded

# With the scope set to this module only, other modules are left alone.
fresh
echo self >"$M/guard.scope"
load
failboot boot-B1
failboot boot-B
check "scope self still trips" tripped
check "scope self disables this module" disabled
check "scope self leaves other modules enabled" '[ ! -f "$T/modules/other_a/disable" ]'
check "scope self lists no modules" '[ ! -s "$M/guard.disabled" ]'
fresh
echo "garbage" >"$M/guard.scope"
load
failboot boot-B1
failboot boot-B
check "an unreadable scope means all modules" '[ -f "$T/modules/other_a/disable" ]'

# Every kind of trip applies the scope.
fresh
echo 1 >"$T/probe_rc"
load
check "silent module trip disables other modules" '[ -f "$T/modules/other_a/disable" ]'

# The volume key prompt of the installer.
key_stub() {
  echo "$1" | put "$T/bin/getevent"
}
pick() { ( MODDIR=$M GUARD_KEY_WAIT=${1:-10}; . "$M/guard.sh"; guard_pick_key ) 2>/dev/null; }
fresh
key_stub 'echo "/dev/input/event1: EV_KEY       KEY_VOLUMEUP         DOWN"'
check "volume up is read as up" '[ "$(pick)" = up ]'
key_stub 'echo "/dev/input/event1: EV_KEY       KEY_VOLUMEDOWN       DOWN"'
check "volume down is read as down" '[ "$(pick)" = down ]'
key_stub 'echo "/dev/input/event1: EV_KEY       KEY_POWER            DOWN"; echo "/dev/input/event1: EV_KEY       KEY_VOLUMEUP         UP"'
check "other keys and key releases are ignored" '! pick >/dev/null'
key_stub 'echo "/dev/input/event0: EV_ABS       ABS_MT_POSITION_X    00000100"; echo "/dev/input/event1: EV_KEY       KEY_VOLUMEDOWN       DOWN"'
check "key events are found among other events" '[ "$(pick)" = down ]'
key_stub 'sleep 30'
check "no key press gives up after the wait" '! pick 1 >/dev/null'
rm -f "$T/bin/getevent"
check "no getevent means no choice" '! pick >/dev/null'

# The kernel release has to be of the GKI form.
nrel=0
for rel in "6.6.30-android15-8-g0123456-ab1" "6.6.30-android15-8" "6.6.0-android15-0-x"; do
  nrel=$((nrel + 1))
  [ -z "${GUARD_TEST_QUICK:-}" ] || [ "$nrel" -le 1 ] || continue
  fresh
  echo "$rel" >"$T/osrelease"
  load
  check "GKI release $rel loads" loaded
done
nrel=0
for rel in "6.6.30-android15-8-g1 extra" "6.6.x-android15-8-g1" "6.6.30-ANDROID15-8-g1" "6.6.30-vendor-android15-8-g1" "6.6.30-android15-g1"; do
  nrel=$((nrel + 1))
  [ -z "${GUARD_TEST_QUICK:-}" ] || [ "$nrel" -le 1 ] || continue
  fresh
  echo "$rel" >"$T/osrelease"
  load
  check "odd release '$rel' is refused" '! loaded'
  check "odd release '$rel' does not arm" '! armed'
  check "odd release '$rel' does not trip" '! tripped'
done

# A valid kmi_override is trusted, whatever the release looks like.
fresh
echo "6.6.30-vendor-android15-8-g1" >"$T/osrelease"
echo 'select_kmi_override() { echo android15-6.6; }' >>"$M/kmi.sh"
load
check "a valid kmi_override loads an odd release" loaded
fresh
echo "6.6.x-android15-8-g1" >"$T/osrelease"
echo 'select_kmi_override() { return 1; }' >>"$M/kmi.sh"
load
check "an override that does not apply leaves the release judged" '! loaded'

# The override rules of upstream's kmi.sh, which the checks above stub: empty, unknown, missing
# .ko and valid. Anything but a valid one must fail so callers fall back to detection.
K=$T/kmi_mod
rm -rf "$K"
mkdir -p "$K/lib"
printf 'android15-6.6\nandroid14-6.1\n' >"$K/kmis"
echo x >"$K/lib/susfs_guard_lkm-android15-6.6.ko"
override() { printf '%s' "$1" >"$K/kmi_override"; ( . "$SRC/../../module/kmi.sh"; select_kmi_override "$K" ) 2>/dev/null; }
check "a valid override is chosen" '[ "$(override "android15-6.6")" = android15-6.6 ]'
check "an override with a trailing newline is chosen" '[ "$(override "android15-6.6 
")" = android15-6.6 ]'
check "an empty override means automatic" '! override "" >/dev/null'
check "an unknown override is not used" '! override "android99-9.9" >/dev/null'
check "a listed KMI without its .ko is not used" '! override "android14-6.1" >/dev/null'
rm -f "$K/kmi_override"
check "no override file means automatic" '! ( . "$SRC/../../module/kmi.sh"; select_kmi_override "$K" ) >/dev/null 2>&1'

# Android safe mode, and a module that was removed or disabled by the user.
for prop in persist.sys.safemode ro.sys.safemode; do
  fresh
  echo 1 >"$T/props/$prop"
  load
  check "$prop=1 loads nothing" '! loaded'
  check "$prop=1 does not arm" '! armed'
done
fresh
: >"$M/disable"
load
check "disable file loads nothing" '! loaded'
fresh
: >"$M/remove"
load
check "remove file loads nothing" '! loaded'

# Without a boot id the boot cannot be told apart, so nothing loads.
fresh
: >"$T/boot_id"
load
check "no boot id loads nothing" '! loaded'
check "no boot id does not arm" '! armed'
check "no boot id is shown on the module card" 'described "Not loaded · "'

# A probe that cannot run, or a SUSFS that already answers, loads nothing.
fresh
rm -f "$M/bin/susfs_sc"
load
check "missing probe loads nothing" '! loaded'
check "missing probe does not arm" '! armed'
fresh
echo 2 >"$T/probe_rc"
load
check "probe that cannot run loads nothing" '! loaded'
fresh
echo 0 >"$T/probe_rc"
load
check "SUSFS already answering loads nothing" '! loaded'
check "SUSFS already answering does not arm" '! armed'

# A marker that cannot be written stops the load.
fresh
mkdir "$M/guard.armed.tmp"
load
check "unwritable marker loads nothing" '! loaded'
check "unwritable marker is shown on the module card" 'described "Not loaded · "'

# A loader that fails leaves the marker armed, so a crash inside it is caught next boot.
fresh
echo 7 >"$T/load_rc"
"$SH" "$M/load.sh" >/dev/null 2>&1
check "failed loader exits with its status" '[ $? -eq 7 ]'
check "failed loader leaves the marker armed" armed

# A module that loaded but does not answer is unloaded and disabled.
fresh
echo 1 >"$T/probe_rc"
load
[ "$stubs_ok" != yes ] || check "silent module is unloaded" '[ -s "$T/rmmod.log" ]'
check "silent module is disabled" disabled
check "silent module is recorded" tripped

# The guard log is rotated before it grows without bound.
fresh
dd if=/dev/zero of="$M/guard.log" bs=1024 count=70 2>/dev/null
load
check "large guard log is rotated" '[ -f "$M/guard.log.old" ]'

# A module directory with spaces or characters sed treats specially.
fresh
load
check "description is plain text after a trip" '! grep -q "[&]" "$M/module.prop"'

# The module card after a load: a state word, then the facts that are true of this boot.
card() { sed -n 's/^description=//p' "$M/module.prop"; }
fresh
load
check "card of a plain load" '[ "$(card)" = "Active · boot load · android15-6.6 · SUSFS 2.3.0" ]'
fresh
: >"$M/early_load"
: >"$T/hook"
load
check "card of an early load" '[ "$(card)" = "Active · early load · android15-6.6 · SUSFS 2.3.0" ]'
fresh
: >"$M/early_load"
load
check "early load needs the hook as well as the marker" '[ "$(card)" = "Active · boot load · android15-6.6 · SUSFS 2.3.0" ]'
fresh
printf '%s\n' '[   12.3] susfs_guard_lkm: sus_mount init failed -22 - that feature stays off' \
  '[   12.4] susfs_guard_lkm: kstat init failed -2 - that feature stays off' \
  '[   12.5] susfs_guard_lkm: sus_mount init failed -22 - that feature stays off' >"$T/dmesg.out"
load
check "card of a load with layers off" '[ "$(card)" = "Degraded · kstat, sus_mount off · android15-6.6 · SUSFS 2.3.0" ]'
fresh
for n in a b c d e; do echo "[ 1.0] susfs_guard_lkm: l_$n init failed -1 - that feature stays off" >>"$T/dmesg.out"; done
load
check "card names three layers and counts the rest" 'card | grep -q "^Degraded · l_a, l_b, l_c +2 off · "'
fresh
echo 7 >"$T/load_rc"
load
check "card of a failed loader" '[ "$(card)" = "Not loaded · the loader failed with error 7 · android15-6.6 · SUSFS 2.3.0" ]'
fresh
echo 124 >"$T/load_rc"
load
check "card of a load that timed out" '[ "$(card)" = "Not loaded · the load did not finish in 60s · android15-6.6 · SUSFS 2.3.0" ]'
fresh
printf 'select_kmi() { return 1; }\n' >"$M/kmi.sh"
echo 1 >"$T/load_rc"
echo "6.6.30-android15-8-g0123456-ab1" >"$T/osrelease"
load
check "card of a kernel with no build" '[ "$(card)" = "Not loaded · no build for kernel 6.6.30-android15-8-g0123456-ab1 · SUSFS 2.3.0" ]'
fresh
echo 0 >"$T/probe_rc"
load
check "card when SUSFS already answers" 'card | grep -q "^Standing by · SUSFS already answers"'
check "cards carry nothing sed would treat specially" '! card | grep -q "[&#\\]"'

echo "guard_test ($SH): $pass passed, $fail failed"
[ "$fail" -eq 0 ]
