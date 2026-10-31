# SPDX-License-Identifier: GPL-2.0-only
# Bootloop guard, sourced by load.sh and service.sh.
#
# A marker is armed before the .ko loads and cleared once the boot has been up for GUARD_SETTLE
# seconds. A marker still there at the next boot means the boot ended too early. It counts as a
# failure unless the user or the system asked for the end: the watcher in service.sh records a
# shutdown it saw, and the boot reason is the second opinion. Any other end, a power cut, a panic,
# a forced power-off, counts, and GUARD_FAILS in a row disable the module instead of loading it.
# No single boot reason string is relied on, since vendors differ in what they report.
#
# The watcher also counts restarts of zygote and SystemUI. A crash loop that never reboots trips
# the guard and reboots the device.
#
# State lives in MODDIR, so updating or removing the module resets it. GUARD_* can be
# overridden from the environment.
# shellcheck disable=SC2154

GUARD_ARMED="$MODDIR/guard.armed"
GUARD_TRIPPED="$MODDIR/guard.tripped"
# Holds the boot id once boot_completed was seen, before the settle time has passed.
GUARD_UP="$MODDIR/guard.up"
# Holds the boot id when the watcher saw a shutdown or reboot begin.
GUARD_CLEAN="$MODDIR/guard.clean"
# Boots in a row that ended too early without a request for it.
GUARD_FAILS_FILE="$MODDIR/guard.fails"
# What a trip disables: "all" modules (default) or only "self". "none" turns the boot watch off.
# Chosen at install (see customize.sh) and changed later by scope.sh.
GUARD_SCOPE_FILE="$MODDIR/guard.scope"
GUARD_DISABLED="$MODDIR/guard.disabled"

# Boots in a row that ended too early before the guard trips.
: "${GUARD_FAILS:=2}"
# Seconds up after boot_completed before the boot counts as good. A crash after that is not ours.
: "${GUARD_SETTLE:=600}"
# Max wait for boot_completed and the poll step. Past it the marker stays armed.
: "${GUARD_BOOT_WAIT:=900}"
: "${GUARD_POLL:=5}"
# Restarts of zygote or SystemUI while watching that trip the guard and reboot.
: "${GUARD_CRASHES:=4}"
: "${GUARD_REBOOT:=reboot}"
: "${GUARD_PIDOF:=pidof}"
# Create this file to keep the module from loading, for instance from recovery or adb.
: "${GUARD_SKIP_FILE:=/data/adb/susfs_skip}"
: "${GUARD_SH:=/system/bin/sh}"
: "${GUARD_MODULES_DIR:=${MODDIR%/*}}"
# Volume key prompt of the installer: the tool that reports key events and how long to wait.
: "${GUARD_GETEVENT:=getevent}"
: "${GUARD_KEY_WAIT:=10}"
: "${GUARD_BOOT_ID_FILE:=/proc/sys/kernel/random/boot_id}"
: "${GUARD_SYS_MODULE:=/sys/module/susfs_guard_lkm}"
: "${GUARD_OSRELEASE_FILE:=/proc/sys/kernel/osrelease}"
: "${GUARD_DMESG:=dmesg}"
# The hook that loads the module before the manager's own post-fs-data stage.
: "${GUARD_EARLY_HOOK:=/data/adb/post-fs-data.d/00-susfs-guard-lkm.sh}"

guard_log() {
  echo "guard: $*"
}

# The manager shows the module.prop description on the module card.
guard_describe() {
  prop="$MODDIR/module.prop"
  [ -f "$prop" ] || return 0
  sed -i "s#^description=.*#description=$1#" "$prop" 2>/dev/null
}

# A card line: a state word, then facts, separated by a middle dot. Empty facts are left out.
# No '#', '&' or backslash may reach guard_describe, which hands the text to sed.
guard_card() {
  line=$1
  shift
  for part in "$@"; do
    [ -z "$part" ] || line="$line | $part"
  done
  guard_describe "$line"
}

# The KMI this kernel runs, from the same sources the loader uses. Needs kmi.sh sourced.
guard_kmi() {
  k=$(select_kmi_override "$MODDIR" 2>/dev/null) || k=""
  [ -n "$k" ] || k=$(select_kmi "$1" "$MODDIR" 2>/dev/null) || k=""
  if [ -z "$k" ] && command -v select_kmi_from_ksud >/dev/null 2>&1; then
    k=$(select_kmi_from_ksud "$MODDIR" 2>/dev/null) || k=""
  fi
  printf '%s' "$k" | tr -c 'A-Za-z0-9._-' '?'
}

# Layers the module could not start, which it reports in the kernel log and leaves off. At most
# three names, then a count.
guard_layers_off() {
  all=$("$GUARD_DMESG" 2>/dev/null |
    sed -n 's/.* \([a-z0-9_]*\) init failed -\{0,1\}[0-9]* - that feature stays off.*/\1/p' | sort -u)
  [ -n "$all" ] || return 0
  n=$(printf '%s\n' "$all" | wc -l | tr -d ' ')
  shown=$(printf '%s\n' "$all" | head -n 3 | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  [ "$n" -le 3 ] || shown="$shown +$((n - 3))"
  printf '%s' "$shown"
}

# What the module card says after the loader ran. $1 is the loader's exit status.
guard_status() {
  base=$(sed -n 's/^susfsBase=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9._-')
  [ -z "$base" ] || base="SUSFS $base"
  rel=$(cat "$GUARD_OSRELEASE_FILE" 2>/dev/null)
  kmi=$(guard_kmi "$rel")
  case $1 in
    0)
      if [ ! -d "$GUARD_SYS_MODULE" ]; then
        guard_card "Standing by" "another SUSFS is active (built in, or from another module)" "$base"
        return 0
      fi
      off=$(guard_layers_off)
      if [ -n "$off" ]; then
        guard_card "Degraded" "$off off" "$kmi" "$base"
      elif [ -f "$MODDIR/early_load" ] && [ -f "$GUARD_EARLY_HOOK" ]; then
        guard_card "Active" "early load" "$kmi" "$base"
      else
        guard_card "Active" "boot load" "$kmi" "$base"
      fi
      ;;
    124) guard_card "Not loaded" "the load did not finish in 60s" "$kmi" "$base" ;;
    *)
      if [ -z "$kmi" ]; then
        shown=$(printf '%s' "$rel" | tr -c 'A-Za-z0-9._+-' '?')
        guard_card "Not loaded" "no build for kernel ${shown:-unknown}" "$base"
      else
        guard_card "Not loaded" "the loader failed with error $1" "$kmi" "$base"
      fi
      ;;
  esac
}

guard_boot_id() {
  cat "$GUARD_BOOT_ID_FILE" 2>/dev/null
}

guard_scope() {
  case $(cat "$GUARD_SCOPE_FILE" 2>/dev/null) in
    self) echo self ;;
    none) echo none ;;
    *) echo all ;;
  esac
}

# Disable every other module and list the ones this changed in guard.disabled. A disabled module
# is skipped from the next boot, one that already ran this boot is not undone.
guard_disable_others() {
  : >"$GUARD_DISABLED"
  for dir in "$GUARD_MODULES_DIR"/*; do
    [ -d "$dir" ] || continue
    [ "${dir%/}" != "${MODDIR%/}" ] || continue
    [ ! -f "$dir/disable" ] || continue
    if : >"$dir/disable" 2>/dev/null; then
      echo "${dir##*/}" >>"$GUARD_DISABLED"
      guard_log "disabled module ${dir##*/}"
    else
      guard_log "cannot disable module ${dir##*/}"
    fi
  done
}

# Ask which key was pressed, up or down. Fails without a key press in GUARD_KEY_WAIT seconds or
# without the tools to read one.
guard_pick_key() {
  command -v "$GUARD_GETEVENT" >/dev/null 2>&1 || return 1
  command -v timeout >/dev/null 2>&1 || return 1
  key=$(timeout "$GUARD_KEY_WAIT" "$GUARD_GETEVENT" -ql 2>/dev/null |
    grep -m 1 -E 'KEY_VOLUME(UP|DOWN)[[:space:]]+DOWN')
  case $key in
    *VOLUMEUP*) echo up ;;
    *VOLUMEDOWN*) echo down ;;
    *) return 1 ;;
  esac
}

# Disable the module, and with the default scope every other module too, until enabled by hand.
guard_trip() {
  guard_log "tripped: $1"
  echo "$1" >"$GUARD_TRIPPED"
  rm -f "$GUARD_ARMED" "$GUARD_UP" "$GUARD_CLEAN" "$GUARD_FAILS_FILE"
  : >"$MODDIR/disable"
  note=
  if [ "$(guard_scope)" = all ]; then
    guard_disable_others
    note="other modules disabled too"
  fi
  guard_card "Disabled" "bootloop guard tripped: $1" "$note" "enable the module again to retry"
  sync
}

# The boot reason, lower case and with odd characters replaced, so it is safe to log and match.
guard_reason() {
  r=$(getprop sys.boot.reason 2>/dev/null)
  [ -n "$r" ] || r=$(getprop ro.boot.bootreason 2>/dev/null)
  printf '%s' "$r" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._,-' '?'
}

# Reasons that mean the boot was cut off. They win over a shutdown the watcher recorded.
guard_crash_reason() {
  case $1 in kernel_panic* | watchdog* | *hung* | *rescue*) return 0 ;; esac
  return 1
}

# Reasons a user or the system gives for ending a boot. Only the second opinion: a vendor that
# words them differently is still covered by the shutdown the watcher recorded.
guard_requested_reason() {
  case $1 in reboot,* | shutdown* | recovery* | bootloader* | fastboot*) return 0 ;; esac
  return 1
}

# Returns 0 when boot $1 ended because someone asked it to.
guard_ended_by_request() {
  reason=$(guard_reason)
  guard_crash_reason "$reason" && return 1
  [ "$(cat "$GUARD_CLEAN" 2>/dev/null)" != "$1" ] || return 0
  guard_requested_reason "$reason"
}

# Returns 0 when this boot is not the one that failed and the module may load on it.
guard_check() {
  if [ -e "$GUARD_SKIP_FILE" ]; then
    guard_log "not loading, $GUARD_SKIP_FILE exists"
    return 1
  fi
  if [ -f "$GUARD_TRIPPED" ]; then
    # Enabling the module again in the manager removes the disable file.
    [ ! -f "$MODDIR/disable" ] || return 1
    guard_log "enabled again after a trip, starting over"
    rm -f "$GUARD_TRIPPED" "$GUARD_ARMED" "$GUARD_UP" "$GUARD_CLEAN" "$GUARD_FAILS_FILE"
  fi
  # Scope none turns the boot watch off. Nothing is armed, so nothing can trip, and what an
  # earlier scope left behind must not count against the next boot.
  if [ "$(guard_scope)" = none ]; then
    rm -f "$GUARD_ARMED" "$GUARD_UP" "$GUARD_CLEAN" "$GUARD_FAILS_FILE"
    return 0
  fi
  cur=$(guard_boot_id)
  if [ -z "$cur" ]; then
    guard_log "cannot identify the boot"
    guard_card "Not loaded" "the bootloop guard cannot identify this boot"
    return 1
  fi
  if [ -f "$GUARD_ARMED" ]; then
    prev=$(cat "$GUARD_ARMED" 2>/dev/null)
    # Early loading calls the loader twice in one boot, which is not a failed boot.
    [ "$prev" != "$cur" ] || return 0
    finished=no
    [ "$(cat "$GUARD_UP" 2>/dev/null)" != "$prev" ] || finished=yes
    guard_log "the previous boot finished: $finished, boot reason: $(guard_reason)"
    if guard_ended_by_request "$prev"; then
      # A finished boot that ended on request is a good one. An unfinished one proves nothing,
      # the user may have rebooted it by hand.
      [ "$finished" = no ] || rm -f "$GUARD_FAILS_FILE"
    else
      # One cut-off boot can be a flat battery, so only GUARD_FAILS in a row trip.
      fails=$(cat "$GUARD_FAILS_FILE" 2>/dev/null)
      case $fails in '' | *[!0-9]*) fails=0 ;; esac
      fails=$((fails + 1))
      if [ "$fails" -ge "$GUARD_FAILS" ]; then
        guard_trip "$fails boots in a row ended early without being asked to"
        return 1
      fi
      echo "$fails" >"$GUARD_FAILS_FILE"
      guard_log "the previous boot was cut off ($fails of $GUARD_FAILS)"
    fi
    rm -f "$GUARD_ARMED" "$GUARD_UP" "$GUARD_CLEAN"
  fi
  return 0
}

guard_arm() {
  [ "$(guard_scope)" != none ] || return 0
  guard_boot_id >"$GUARD_ARMED.tmp" && mv "$GUARD_ARMED.tmp" "$GUARD_ARMED" || return 1
  sync
}

# Prints the sorted pids of the named processes, nothing when there are none or no pidof.
guard_pids() {
  command -v "$GUARD_PIDOF" >/dev/null 2>&1 || return 0
  p=$("$GUARD_PIDOF" "$@" 2>/dev/null)
  [ -n "$p" ] || return 0
  # shellcheck disable=SC2086
  printf '%s\n' $p | sort | tr '\n' ' '
}

guard_restart() {
  churn=$((churn + 1))
  guard_log "restart seen: $1 ($churn of $GUARD_CRASHES)"
}

# Returns 0 when a pid of $1 is gone from $2 and a pid of $2 is new. A process that restarted does
# both. A second process appearing, or one ending for good, does only one of them.
guard_replaced() {
  gone=no
  fresh_pid=no
  for p in $1; do
    case " $2 " in *" $p "*) ;; *) gone=yes ;; esac
  done
  for p in $2; do
    case " $1 " in *" $p "*) ;; *) fresh_pid=yes ;; esac
  done
  [ "$gone" = yes ] && [ "$fresh_pid" = yes ]
}

# Count a restart each time a pid of zygote or SystemUI is replaced. The first sight is not one.
guard_churn() {
  z=$(guard_pids zygote64 zygote)
  if [ -n "$z" ]; then
    [ -z "$z_last" ] || ! guard_replaced "$z_last" "$z" || guard_restart zygote
    z_last=$z
  fi
  s=$(guard_pids com.android.systemui)
  if [ -n "$s" ]; then
    [ -z "$s_last" ] || ! guard_replaced "$s_last" "$s" || guard_restart systemui
    s_last=$s
  fi
}

# init sets sys.powerctl before it stops anything, for every reboot and power-off.
guard_shutting_down() {
  [ -n "$(getprop sys.powerctl 2>/dev/null)" ]
}

guard_mark_clean() {
  guard_boot_id >"$GUARD_CLEAN"
}

# Watch the boot that armed the marker. It clears the marker once the boot has been up for
# GUARD_SETTLE seconds, records a shutdown it sees begin, and trips and reboots when zygote or
# SystemUI keep restarting. Otherwise the marker stays armed and the next boot judges it.
guard_settle() {
  me=$(guard_boot_id)
  [ -n "$me" ] && [ "$(cat "$GUARD_ARMED" 2>/dev/null)" = "$me" ] || return 0
  # A userspace reboot runs this again in the same boot, with the old record stale.
  rm -f "$GUARD_CLEAN"
  # A shutdown that began between two polls still reaches this job as a TERM.
  trap 'guard_shutting_down && guard_mark_clean; exit 0' TERM
  waited=0
  up=0
  churn=0
  z_last=
  s_last=
  while :; do
    # Another path disarmed or tripped the guard, there is nothing left to watch for.
    [ "$(cat "$GUARD_ARMED" 2>/dev/null)" = "$me" ] || return 0
    if guard_shutting_down; then
      guard_mark_clean
      return 0
    fi
    guard_churn
    if [ "$churn" -ge "$GUARD_CRASHES" ]; then
      guard_trip "zygote or SystemUI restarted $churn times"
      guard_log "rebooting"
      "$GUARD_REBOOT"
      return 1
    fi
    if [ "$up" = 0 ]; then
      if [ "$(getprop sys.boot_completed)" = 1 ]; then
        guard_boot_id >"$GUARD_UP"
        up=1
        waited=0
      elif [ "$waited" -ge "$GUARD_BOOT_WAIT" ]; then
        guard_log "boot_completed never came, the marker stays armed"
        return 1
      fi
    fi
    if [ "$up" = 1 ] && [ "$waited" -ge "$GUARD_SETTLE" ]; then
      break
    fi
    # wait, unlike a foreground sleep, lets the TERM trap run at once.
    sleep "$GUARD_POLL" &
    wait $!
    waited=$((waited + GUARD_POLL))
  done
  rm -f "$GUARD_ARMED" "$GUARD_UP" "$GUARD_CLEAN" "$GUARD_FAILS_FILE"
  sync
  guard_log "boot settled"
}

# Refuse a kernel release that is not the GKI form <version>.<patch>-<tag>-<generation>, such as
# 6.6.118-android15-8-g3a3f1c2-ab1234. The selector in kmi.sh uses wildcards, so a vendor string
# could still pick the .ko of another kernel, and the kernel does not always reject a wrong .ko.
#
# Needs kmi.sh sourced. Returns 1 to refuse. A release the selector rejects goes on, so the
# loader reports it.
guard_kernel() {
  rel=$(cat "$GUARD_OSRELEASE_FILE" 2>/dev/null)
  [ -n "$rel" ] || return 0
  # A valid kmi_override names the .ko by hand, so the release form is not judged.
  select_kmi_override "$MODDIR" >/dev/null 2>&1 && return 0
  kmi=$(select_kmi "$rel" "$MODDIR") || return 0
  # Without an Android tag the selector already requires a numeric patch level.
  case $(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]') in *android[0-9]*) ;; *) return 0 ;; esac
  os=${kmi%-*}
  kver=${kmi#*-}
  patch=${rel#"$kver".}
  patch=${patch%%-*}
  case $patch in '' | *[!0-9]*) ;; *)
    case $rel in
      *[!A-Za-z0-9._+-]*) ;;
      "$kver.$patch-$os-"[0-9]*) return 0 ;;
    esac
    ;;
  esac
  # The description is edited with sed, so keep only plain characters.
  shown=$(printf '%s' "$rel" | tr -c 'A-Za-z0-9._+-' '?')
  guard_log "kernel release $shown is not of the form <version>.<patch>-$os-<generation>"
  guard_card "Not loaded" "kernel release $shown is not a standard GKI release"
  return 1
}

# Does SUSFS answer on this kernel? 0: yes, 1: no, 2: the probe could not run.
# Asks for the version through the supercall the module serves: 16 bytes of reply plus an int
# err. Kernels without SUSFS reject it.
guard_probe() {
  probe="$MODDIR/bin/susfs_sc"
  [ -f "$probe" ] || return 2
  chmod 0755 "$probe" 2>/dev/null
  "$probe" 0x555e1 0000000000000000000000000000000000000000 >/dev/null 2>&1
  case $? in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}
