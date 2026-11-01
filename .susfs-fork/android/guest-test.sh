#!/system/bin/sh
# Loads KernelSU and the SUSFS module on an Android guest the way a root
# manager would, and prints one "ANDROID key=value" line per fact.
T=/data/local/tmp
M=/data/adb/modules/susfs_guard_lkm
CTL=$T/ksu/ksuctl

say() { echo "ANDROID $*"; }
flag() { [ -d "$1" ] && echo yes || echo no; }

say "kernel=$(uname -r)"
say "selinux=$(getenforce)"
say "context=$(id -Z)"
say "sdk=$(getprop ro.build.version.sdk)"
say "avc_before=$(dmesg | grep -c 'avc: *denied')"

chmod 755 "$T/mod/bin/susfs_insmod" "$T/mod/bin/susfs_sc" "$CTL"

# KernelSU first: the module resolves its symbols by name.
"$T/mod/bin/susfs_insmod" -v "$T/ksu/kernelsu-release.ko"
say "ksu_insmod_rc=$?"
say "ksu_loaded=$(grep -qi '^kernelsu' /proc/modules && echo yes || echo no)"
say "ksu_post_fs_data=$("$CTL" event post-fs-data)"

# Install the module where the manager keeps it, then run its boot scripts.
rm -rf "$M"
mkdir -p "$M"
cp -r "$T/mod/." "$M/"
chmod 755 "$M"/*.sh "$M"/bin/*
cd "$M" || exit 1

# A saved WebUI choice that differs from the defaults on both nodes, so the check after the load
# shows whether the loader's context may write them at boot.
mkdir -p /data/adb/susfs_guard_lkm
printf 'enable_log=0\navc_spoof=1\n' > /data/adb/susfs_guard_lkm/toggles

/system/bin/sh ./post-fs-data.sh
say "post_fs_data_rc=$?"
say "susfs_loaded=$(flag /sys/module/susfs_guard_lkm)"
say "toggle_enable_log_after_boot=$(cat /proc/susfs_enable_log 2>&1)"
say "toggle_avc_spoof_after_boot=$(cat /proc/susfs_avc_spoof 2>&1 | cut -d' ' -f1)"
say "toggle_load_log=$(grep -c 'not applied' "$M/load.log" 2>/dev/null)"
# Both nodes go back to their defaults, through the same script the WebUI calls, so the lines that
# read the log below are not silenced and the AVC spoof does not hide what they look for.
/system/bin/sh ./toggle.sh set enable_log 1
say "toggle_set_enable_log_rc=$?"
/system/bin/sh ./toggle.sh set avc_spoof 0
say "toggle_set_avc_spoof_rc=$?"
say "toggle_get=$(/system/bin/sh ./toggle.sh get | tr '\n' ' ')"
/system/bin/sh ./toggle.sh set avc_spoof 2 2>/dev/null
say "toggle_bad_value_rc=$?"
say "selinux_hide_node=$(cat /proc/susfs_selinux_hide 2>&1)"
/system/bin/sh ./toggle.sh set selinux_hide 1 2>/dev/null
say "toggle_set_selinux_hide_rc=$?"
# The watcher in service.sh would reboot the guest if the framework restarted often, which is not
# what the tests after this one are meant to find. A trip is still logged in guard.log.
GUARD_REBOOT=true /system/bin/sh ./service.sh
say "service_rc=$?"
sleep 5

# The boot scripts run again on a later boot in the same state.
/system/bin/sh ./post-fs-data.sh
say "post_fs_data_again_rc=$?"
say "susfs_still_loaded=$(flag /sys/module/susfs_guard_lkm)"

say "ksu_boot_completed=$("$CTL" event boot-completed)"
say "ksu_umount_10000=$("$CTL" umount 10000)"
say "avc_after=$(dmesg | grep -c 'avc: *denied')"

echo "---- guard.log"
tail -n 25 "$M/guard.log" 2>/dev/null
echo "---- kernel messages from KernelSU and SUSFS"
dmesg | grep -iE 'susfs|kernelsu|ksu' | tail -n 40
echo "---- avc denials that name KernelSU or SUSFS"
dmesg | grep -E 'avc: *denied' | grep -iE 'ksu|susfs|kernelsu' | head -n 10