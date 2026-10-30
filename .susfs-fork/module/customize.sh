#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Installer, sourced by KernelSU after unpacking the zip. The upstream installer ships unchanged
# as customize.upstream.sh (see pack_extra.py) and does the real work. This script prints the
# steps around it and writes the install log. Output is plain ASCII for the narrow manager window.
# shellcheck disable=SC2154

UPSTREAM="$MODPATH/customize.upstream.sh"
MODULE=susfs_guard_lkm
STEPS=5
# Columns of the manager window.
WIDTH=36
# Kept outside the module directory, which a failed install removes. One previous log is kept.
LOGFILE=/data/adb/$MODULE-install.log
START=$(date +%s 2> /dev/null || echo 0)

# A log that cannot be written must not stop the install.
log_open() {
  [ ! -f "$LOGFILE" ] || mv -f "$LOGFILE" "$LOGFILE.old" 2> /dev/null
  # printf, not ':', because a failed redirect ends a shell running a special built-in.
  if printf '' 2> /dev/null > "$LOGFILE"; then
    chmod 0600 "$LOGFILE"
  else
    LOGFILE=
  fi
}

log() {
  [ -n "$LOGFILE" ] || return 0
  printf '%s\n' "$*" 2> /dev/null >> "$LOGFILE"
}

section() {
  log ""
  log "== $1 =="
}

field() {
  log "$(printf '%-32s %s' "$1" "$2")"
}

# Log the output of a command, indented. A missing or failing command shows up as its error.
block() {
  [ -n "$LOGFILE" ] || return 0
  log "$1:"
  shift
  "$@" 2>&1 | sed 's/^/    /' 2> /dev/null >> "$LOGFILE"
}

# Close the log with how the install ended.
finish() {
  log ""
  log "result=$1 status=$2 seconds=$(($(date +%s 2> /dev/null || echo 0) - START))"
}

say() {
  ui_print "$1"
  log "$1"
}

prop() {
  sed -n "s/^$1=//p" "$MODPATH/module.prop" | head -n 1
}

# Step header with its result.
step() {
  say " "
  say "[$1/$STEPS] $2${3:+ ... $3}"
}

# Print the words of $3 in lines of at most WIDTH columns, the first starting with $1 and the
# rest with $2. fold is not on every Android.
wrap() {
  _line=$1
  _empty=1
  set -f
  # shellcheck disable=SC2086
  for _word in $3; do
    if [ "$_empty" = 1 ]; then
      _line=$_line$_word
    elif [ $((${#_line} + 1 + ${#_word})) -le "$WIDTH" ]; then
      _line="$_line $_word"
    else
      say "$_line"
      _line=$2$_word
    fi
    _empty=0
  done
  set +f
  say "$_line"
}

# Say where the log is.
tell_log() {
  if [ -n "$LOGFILE" ]; then
    wrap "  " "  " "Attach the install log to a report of a problem:"
    say "  $LOGFILE"
  else
    say "  The install log could not be written."
  fi
}

# Log what the install runs on. The kernel command line is left out, it can carry the serial number.
log_environment() {
  section "Installer"
  field date "$(date '+%Y-%m-%d %H:%M:%S %z' 2>&1)"
  field module "$(prop id) $(prop version) code $(prop versionCode)"
  field zip "${ZIPFILE:-unknown}"
  field modpath "$MODPATH"

  section "KernelSU"
  for _name in KSU KSU_VER KSU_VER_CODE KSU_KERNEL_VER_CODE BOOTMODE API ARCH IS64BIT; do
    eval "_value=\${$_name:-unset}"
    field "$_name" "$_value"
  done
  block "ksud" /data/adb/ksud --version

  section "Device"
  for _name in ro.product.manufacturer ro.product.model ro.product.device ro.build.fingerprint \
    ro.build.version.release ro.build.version.sdk ro.build.version.security_patch \
    ro.product.cpu.abi ro.boot.verifiedbootstate; do
    field "$_name" "$(getprop "$_name" 2>&1)"
  done

  section "Kernel"
  field osrelease "$rel"
  block "/proc/version" cat /proc/version
  field selinux "$(getenforce 2>&1)"

  section "Zip"
  block "files" ls -l "$MODPATH" "$MODPATH/lib"
  block "kernels in the zip" cat "$MODPATH/kmis"
  block "sha256 of the .ko files" sha256sum "$MODPATH"/lib/*.ko
  block "provenance" cat "$MODPATH/provenance.json"

  section "State before the install"
  block "installed module.prop" cat "/data/adb/modules/$MODULE/module.prop"
  block "files of the installed module" ls -l "/data/adb/modules/$MODULE"
  block "guard.log of the installed module, last lines" tail -n 40 "/data/adb/modules/$MODULE/guard.log"
  block "modules" ls /data/adb/modules
  block "boot hooks" ls -l /data/adb/post-fs-data.d
  block "susfs entries in /proc" sh -c "ls /proc | grep '^susfs'"
  block "susfs in /proc/modules" grep susfs /proc/modules

  section "What the installer showed"
}

# Log what the upstream installer printed and left behind.
log_upstream() {
  section "Upstream installer"
  field status "$status"
  block "output" printf '%s\n' "$output"
  block "boot hooks after" ls -l /data/adb/post-fs-data.d
  block "files of the module after" ls -l "$MODPATH"
}

log_open
rel=$(cat /proc/sys/kernel/osrelease 2> /dev/null)
log_environment

if [ ! -f "$UPSTREAM" ]; then
  log "customize.upstream.sh is missing from the zip"
  finish failed 1
  abort "- the installer of the module is missing from the zip."
fi

version=$(prop version)
ui_print " "
ui_print ' ___ _   _ ___ ___ ___'
ui_print '/ __| | | / __| __/ __|'
ui_print '\__ \ |_| \__ \ _|\__ \'
ui_print '|___/\___/|___/_| |___/ Installer'
say " "
say "SUSFS Guard (LKM)${version:+ $version}"
say "Supports: Only KernelSU and its forks"
say " "
say "Credits:"
say "  simonpunk     SUSFS"
say "  inforcqb      LKM port"
say "  LowKeyMerlin  Bootloop guard,"
say "                Kernel panic fixes,"
say "                Upstream SUSFS sync,"
say "                Boot and GKI tests"

# Drop the build commit, it only makes the line wrap.
shown=${rel%%-g[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*}
check=failed
if [ "$KSU" = true ] && [ "$ARCH" = arm64 ] && [ -n "$rel" ]; then
  check=ok
fi
step 1 "Device check" "$check"
say "  Kernel  ${shown:-unknown}"
say "  Arch    ${ARCH:-unknown}"
if [ "$KSU" = true ]; then
  say "  Root    KernelSU${KSU_VER:+ $KSU_VER}"
else
  say "  Root    not KernelSU"
fi

kmi=
if [ -f "$MODPATH/kmi.sh" ]; then
  # shellcheck source=/dev/null
  . "$MODPATH/kmi.sh"
  # The loader tries the override first, so the screen must too.
  kmi=$(select_kmi_override "$MODPATH" 2> /dev/null) || kmi=$(select_kmi "$rel" "$MODPATH")
fi
if [ -n "$kmi" ]; then
  step 2 "Kernel module" ok
  say "  KMI     $kmi"
else
  step 2 "Kernel module" failed
  say "  Nothing in this zip fits the kernel"
fi

# Run in a subshell so an abort ends only that and its output can be shown first.
output=$(
  # shellcheck source=/dev/null
  . "$UPSTREAM" 2>&1
)
status=$?
if [ "$status" = 0 ]; then
  mark=-
  step 3 "Install" ok
else
  mark=x
  step 3 "Install" failed
fi
printf '%s\n' "$output" | while IFS= read -r line; do
  [ -n "$line" ] || continue
  wrap "  $mark " "    " "${line#- }"
done

if [ "$status" != 0 ]; then
  say " "
  tell_log
  log_upstream
  finish failed "$status"
  abort "- Installation failed."
fi

step 4 "Bootloop guard"
# shellcheck source=/dev/null
MODDIR=$MODPATH . "$MODPATH/guard.sh"
scope=all
if [ "$(cat "/data/adb/modules/$MODULE/guard.scope" 2> /dev/null)" = self ]; then
  scope=self
fi
wrap "  " "  " "If a boot fails the guard disables modules until you enable this one again."
say "  Vol UP    all modules"
say "  Vol DOWN  this module only"
say "  Choose within ${GUARD_KEY_WAIT}s,"
say "  else: $scope"
case $(guard_pick_key) in
  up) scope=all ;;
  down) scope=self ;;
esac
printf '%s\n' "$scope" > "$MODPATH/guard.scope"
if [ "$scope" = self ]; then
  say "  Chosen: this module only"
else
  say "  Chosen: all modules"
fi

step 5 "Done"
wrap "  " "  " "Reboot to load the module. Its card in the manager then shows whether it loaded."
say " "
wrap "  " "  " "Two boots in a row that end early turn the module off. Enable it again in the manager to retry."
say " "
tell_log
say " "
log_upstream
finish ok 0
