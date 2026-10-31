#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Health checks for the WebUI. One line per check: id|level|title|detail, level being ok, info,
# warn or fail. Reads only. Each check says what a user can do about it in the detail text, so the
# page has nothing to interpret.
#
# These are the checks root can make. What an app process sees is not among them, because the
# module treats root as the one reader it never hides from.
MODDIR=${0%/*}
PROC=${SUSFS_PROC:-/proc}
SYS_MODULE=${SUSFS_SYS_MODULE:-/sys/module/susfs_guard_lkm}
MODULES_DIR=${SUSFS_MODULES_DIR:-${MODDIR%/*}}
EARLY_HOOK=${SUSFS_EARLY_HOOK:-/data/adb/post-fs-data.d/00-susfs-guard-lkm.sh}
TIMEOUT_LOG=${SUSFS_TIMEOUT_LOG:-/data/adb/susfsload_timeout.log}
DMESG=${SUSFS_DMESG:-dmesg}
GETENFORCE=${SUSFS_GETENFORCE:-getenforce}
NAME=susfs_guard_lkm

# Keeps the output to one line per check and free of the separator.
clean() { printf '%s' "$1" | tr '\n|' '  '; }
out() { printf '%s|%s|%s|%s\n' "$1" "$2" "$(clean "$3")" "$(clean "$4")"; }

# The log is read through pipes and never held in a variable: with logging on it passes 2 MB, and
# Android's sh has no printf builtin, so a variable that large breaks the argument limit.
modlog() { "$DMESG" 2>/dev/null | grep "$NAME:"; }

# What the module prints when a hook could not be placed and the feature is partly or wholly off.
# Lines about an empty rule list are normal at boot, and so is "hook: NOT ours": with mount_dbg on,
# sus_mount names each ordinary system mount its identity test did not claim.
WARN_RE='failed|NOT |not filtered|keeps (showing|printing|returning)|did not|drifted|not found|not resolved|not installed|not recogni[sz]ed'
problems() { modlog | grep -v -e 'that feature stays off' -e ': no rules' -e 'hook: NOT ours' | grep -E "$WARN_RE"; }

if [ -d "$SYS_MODULE" ]; then
  out loaded ok "Module is loaded" "The kernel module is running."
else
  card=$(sed -n 's/^description=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
  out loaded fail "Module is not loaded" "${card:-No reason was recorded.} See load.log in the module folder."
fi

# A layer that fails to start leaves the module up with that feature off, which nothing else shows.
off=$(modlog |
  sed -n 's/.* \([a-z0-9_]*\) init failed -\{0,1\}[0-9]* - that feature stays off.*/\1/p' | sort -u | tr '\n' ' ')
if [ -n "$off" ]; then
  out layers warn "Some features are off" "These layers could not start: ${off}. The rest of the module works. Check the kernel log for the reason."
else
  out layers ok "All feature layers started" "No layer reported a failed start."
fi

if grep -q "$NAME" "$PROC/modules" 2>/dev/null; then
  out hide_modules fail "Module is listed in /proc/modules" "Apps can read this list. Run: echo clear > /proc/susfs_hide_modules, then echo add $NAME > /proc/susfs_hide_modules."
else
  out hide_modules ok "Module is hidden from /proc/modules" "It does not appear in the module list."
fi

if grep -q "\[$NAME\]" "$PROC/kallsyms" 2>/dev/null; then
  out hide_symbols fail "Module symbols are in kallsyms" "Symbols tagged with the module name are readable. Reload the module, the hide runs at load."
else
  out hide_symbols ok "Module symbols are hidden from kallsyms" "No symbol carries the module name."
fi

if [ -f "$MODDIR/guard.tripped" ]; then
  out guard fail "Bootloop guard tripped" "$(cat "$MODDIR/guard.tripped" 2>/dev/null). Enable the module again in the manager to retry."
elif [ "$(cat "$MODDIR/guard.fails" 2>/dev/null || echo 0)" -gt 0 ]; then
  out guard warn "A recent boot ended early" "The guard counts boots that were cut off and disables the module after repeated ones."
else
  out guard ok "Bootloop guard is quiet" "No failed boot is on record."
fi

if [ -f "$MODDIR/early_load" ] && [ -f "$EARLY_HOOK" ]; then
  out early_load ok "Early load is set up" "The module loads before the manager's own boot stage."
else
  out early_load info "Loads at the manager's boot stage" "Early load needs the post-fs-data hook and the early_load marker. Without it, SUSFS commands sent by the manager before the module loads are lost."
fi

if [ -s "$TIMEOUT_LOG" ]; then
  out load_timeout warn "A load timed out before" "$TIMEOUT_LOG holds the report of the last time the load took over a minute."
fi

# Another module that hides mounts or ships its own SUSFS can fight this one for the same hooks.
others=""
for dir in "$MODULES_DIR"/*/; do
  [ -d "$dir" ] || continue
  id=${dir%/}
  id=${id##*/}
  [ "$id" != "$NAME" ] || continue
  [ ! -f "$dir/disable" ] || continue
  [ ! -f "$dir/remove" ] || continue
  # BRENE is a front end that sends commands to this module, not a second SUSFS. Its name says
  # SuSFS, so it has to be skipped by id.
  case $id in brene*) continue ;; esac
  if grep -qiE '^(id|name)=.*(susfs|resusfs)' "$dir/module.prop" 2>/dev/null; then
    others="$others $id"
  fi
done
if [ -n "$others" ]; then
  out conflicts warn "Another SUSFS module is enabled" "Found:${others}. Two modules that hide the same mounts can undo each other. Keep one."
else
  out conflicts ok "No other SUSFS module found" "No other enabled module ships SUSFS."
fi

# BRENE sends its settings in post-fs-data. A module that loads later never receives them, and
# nothing shows it, so compare what BRENE wants with what the kernel holds.
BRENE_CONF=${SUSFS_BRENE_CONF:-/data/adb/brene/config.sh}
if [ -d "$SYS_MODULE" ] && [ -r "$BRENE_CONF" ]; then
  differ=""
  for pair in enable_avc_log_spoofing:avc_spoof enable_log:enable_log; do
    want=$(grep -a "^config_${pair%%:*}=" "$BRENE_CONF" | tail -n 1 | cut -d= -f2 | tr -cd '01')
    read -r have _ <"$PROC/susfs_${pair##*:}" 2>/dev/null
    [ -n "$want" ] && [ -n "$have" ] && [ "$want" != "$have" ] || continue
    differ="$differ ${pair%%:*} (BRENE $want, kernel $have);"
  done
  if [ -n "$differ" ]; then
    out brene_sync warn "BRENE settings did not reach the kernel" "Different:${differ} BRENE sends them before this module loads. Set up early load, or set them under Options."
  else
    out brene_sync ok "BRENE settings match the kernel" "AVC spoofing and kernel logging are as BRENE has them."
  fi
fi

# Failed layer starts are reported above, so they are not counted again here.
bad=$(problems | grep -c '')
if [ "${bad:-0}" -gt 0 ]; then
  first=$(problems | head -n 2 | sed "s/^[^]]*\] *$NAME: //" | tr '\n' ';')
  out kernel_log warn "The kernel log has module warnings" "$bad line(s), first: $first Filter the output of dmesg for $NAME to see all of them."
else
  out kernel_log ok "The kernel log is clean" "No warning from the module."
fi

mode=$("$GETENFORCE" 2>/dev/null)
case $mode in
  Enforcing) out selinux ok "SELinux is enforcing" "Detector apps flag a permissive device." ;;
  Permissive) out selinux fail "SELinux is permissive" "Detector apps report this at once. Set it back with: setenforce 1." ;;
  *) out selinux info "SELinux mode is unknown" "getenforce gave no answer." ;;
esac

read -r log_state _ <"$PROC/susfs_enable_log" 2>/dev/null
if [ "$log_state" = 1 ]; then
  out log_switch info "Kernel logging is on" "The module writes to the kernel log. Turn it off for daily use, it costs a little and adds lines anyone with dmesg access can read."
fi
