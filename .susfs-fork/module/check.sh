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

kernel_log=$("$DMESG" 2>/dev/null)

if [ -d "$SYS_MODULE" ]; then
  out loaded ok "Module is loaded" "The kernel module is running."
else
  card=$(sed -n 's/^description=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
  out loaded fail "Module is not loaded" "${card:-No reason was recorded.} See load.log in the module folder."
fi

# A layer that fails to start leaves the module up with that feature off, which nothing else shows.
off=$(printf '%s\n' "$kernel_log" |
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
  if grep -qiE '^(id|name)=.*(susfs|brene|resusfs)' "$dir/module.prop" 2>/dev/null; then
    others="$others $id"
  fi
done
if [ -n "$others" ]; then
  out conflicts warn "Other SUSFS or mount-hiding modules are enabled" "Found:${others}. Two modules that hide the same mounts can undo each other. Keep one."
else
  out conflicts ok "No overlapping module found" "No other enabled module declares SUSFS, BRENE or ReSUSFS."
fi

# Failed layer starts are reported above, so they are not counted again here.
bad=$(printf '%s\n' "$kernel_log" | grep -v 'that feature stays off' | grep -ciE "$NAME:.*(warn|bug|oops|panic|fail)")
if [ "${bad:-0}" -gt 0 ]; then
  out kernel_log warn "The kernel log has module warnings" "$bad line(s) from $NAME mention a warning or failure. Run dmesg | grep $NAME."
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
