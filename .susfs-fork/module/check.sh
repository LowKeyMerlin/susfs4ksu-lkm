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
EARLY_HOOK=${SUSFS_EARLY_HOOK:-/data/adb/post-fs-data.d/00-susfs-guard-lkm.sh}
TIMEOUT_LOG=${SUSFS_TIMEOUT_LOG:-/data/adb/susfsload_timeout.log}
DMESG=${SUSFS_DMESG:-dmesg}
GETENFORCE=${SUSFS_GETENFORCE:-getenforce}
NAME=susfs_guard_lkm
# shellcheck source=/dev/null
. "$MODDIR/clients.sh"

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

early_on=0
[ -f "$MODDIR/early_load" ] && [ -f "$EARLY_HOOK" ] && early_on=1
if [ "$early_on" = 1 ]; then
  out early_load ok "Early load is set up" "The module loads before the manager's own boot stage."
else
  out early_load info "Loads at the manager's boot stage" "Early load needs the post-fs-data hook and the early_load marker. Without it, SUSFS commands sent by the manager before the module loads are lost."
fi

if [ -s "$TIMEOUT_LOG" ]; then
  out load_timeout warn "A load timed out before" "$TIMEOUT_LOG holds the report of the last time the load took over a minute."
fi

# A second SUSFS in the kernel can fight this one for the same hooks. A module that only sends
# SUSFS commands is a client of this one, and is reported below.
others=$(cl_providers | tr '\n' ' ')
if [ -n "$others" ]; then
  out conflicts warn "Another SUSFS kernel module is enabled" "Found: ${others}. Two implementations that hide the same mounts can undo each other. Keep one."
else
  out conflicts ok "No other SUSFS kernel module found" "No other enabled module ships SUSFS kernel code."
fi

# A module that sends its SUSFS commands in post-fs-data runs before this one loads, unless early
# load is on, and the kernel drops what it receives with nobody to answer.
clients=$(cl_clients | tr '\n' ' ')
if [ -n "$clients" ]; then
  early_clients=$(cl_early_clients | tr '\n' ' ')
  if [ -n "$early_clients" ] && [ "$early_on" = 0 ]; then
    out clients warn "SUSFS commands may be sent too early" "Sent in post-fs-data by: ${early_clients}. This module loads after them, so they are lost. Turn on early load."
  else
    out clients ok "Other modules send SUSFS commands" "Found: ${clients}. Their commands arrive after this module has loaded."
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
