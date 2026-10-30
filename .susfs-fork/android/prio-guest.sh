#!/system/bin/sh
# The priority uid filter on an Android guest, after guest-test.sh has loaded KernelSU and the module.
# The packages are installed ones, and the uid to hide is found through /data/data under SELinux, as
# on a device. Prints one "ANDROID key=value" line per fact.
T=/data/local/tmp
P=$T/prio_probe

say() { echo "ANDROID $*"; }

# A row is what getpriority, setpriority, ioprio_get, ioprio_set and ioprio_set with an invalid class
# returned, with "ok" for any success. row CALLER_UID TARGET_UID, CALLER_UID root for uid 0.
row() {
  if [ "$1" = root ]; then "$P" user "$2"; else su "$1" "$P" user "$2"; fi |
    sed 's/^[a-z_]*=//; s/^[0-9][0-9]*$/ok/' | tr '\n' ',' | sed 's/,$//'
}
# The reboot result and the err the kernel wrote back.
pset() { "$P" set "$1" | tr '\n' ' ' | sed 's/^set_rc=\(-*[0-9]*\) set_err=\(-*[0-9]*\) *$/\1,\2/'; }

chmod 755 "$P"
say "selinux=$(getenforce)"
say "layer=$(dmesg | grep -c 'priority/[a-z_]*) armed')"
say "layer_failed=$(dmesg | grep -c 'priority_filter init failed')"

# Three packages with an app uid of their own: two to hide or not, and one to ask from.
cmd package list packages -U | sed -n 's/^package:\([^ ]*\) uid:\(1[0-9][0-9][0-9][0-9]\).*/\1 \2/p' | sort -k2,2 -u |
  while read -r name uid; do [ -d "/data/data/$name" ] && echo "$name $uid"; done | head -n 3 > $T/pkgs
PKG_A=$(sed -n 1p $T/pkgs | cut -d' ' -f1); UID_A=$(sed -n 1p $T/pkgs | cut -d' ' -f2)
PKG_B=$(sed -n 2p $T/pkgs | cut -d' ' -f1); UID_B=$(sed -n 2p $T/pkgs | cut -d' ' -f2)
UID_C=$(sed -n 3p $T/pkgs | cut -d' ' -f2)
say "packages=$(wc -l < $T/pkgs)"
say "pkg_a=$PKG_A uid_a=$UID_A pkg_b=$PKG_B uid_b=$UID_B uid_c=$UID_C"
# The filter takes the owner of the data directory, which has to be the uid the package manager reports.
say "owner_a=$([ "$(stat -c %u "/data/data/$PKG_A")" = "$UID_A" ] && echo yes || echo no)"
say "owner_b=$([ "$(stat -c %u "/data/data/$PKG_B")" = "$UID_B" ] && echo yes || echo no)"
say "data_is_link=$([ -L /data/data ] && echo yes || echo no)"
say "caller_uid=$(su "$UID_C" id -u)"

# A uid without a process is answered with ESRCH whatever the filter says, so each target has one.
su "$UID_A" sleep 3600 > /dev/null 2>&1 &
su "$UID_B" sleep 3600 > /dev/null 2>&1 &
sleep 2

dmesg -c > /dev/null 2>&1
say "before=$(row "$UID_C" "$UID_A")"
say "set_a=$(pset "$PKG_A")"
say "hidden_a=$(row "$UID_C" "$UID_A")"
say "visible_b=$(row "$UID_C" "$UID_B")"
say "own_a=$(row "$UID_A" "$UID_A")"
say "root_a=$(row root "$UID_A")"
say "missing=$(pset com.example.nosuchpackage)"
say "kept_after_refused=$(row "$UID_C" "$UID_A")/$(row "$UID_C" "$UID_B")"
say "set_both=$(pset "$PKG_A,$PKG_B")"
say "both_hidden=$(row "$UID_C" "$UID_A")/$(row "$UID_C" "$UID_B")"
say "set_b=$(pset "$PKG_B")"
say "replaced=$(row "$UID_C" "$UID_A")/$(row "$UID_C" "$UID_B")"
# The package manager rewrites packages.list when a package is installed, and the filter follows the
# package to the uid it has then. The data directory of PKG_A changes owner as it does when an app comes back
# under another uid, so the uid of PKG_A is now UID_B. Nothing changes until the package manager writes.
H="-3,-3,-3,-3,-22"
say "set_a_again=$(pset "$PKG_A")"
ls -l /data/system/packages.list* > $T/pl.before 2>&1
chown "$UID_B" "/data/data/$PKG_A"
say "refresh_stale=$(row "$UID_C" "$UID_A")/$(row "$UID_C" "$UID_B")"
APK=$(ls /system/app/*/*.apk 2>/dev/null | head -n 1)
say "reinstall_apk=$APK"
say "reinstall_out=$(pm install -r -d "$APK" 2>&1 | tr '\n' ' ')"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ "$(row "$UID_C" "$UID_B")" = "$H" ] && break
  sleep 1
done
say "refresh_followed=$(row "$UID_C" "$UID_A")/$(row "$UID_C" "$UID_B")"
say "owner_after=$(stat -c %u "/data/data/$PKG_A")"
ls -l /data/system/packages.list* > $T/pl.after 2>&1
say "list_changed=$(cmp -s $T/pl.before $T/pl.after && echo no || echo yes)"
chown "$UID_A" "/data/data/$PKG_A"
say "avc_probe=$(dmesg | grep 'avc: *denied' | grep -c prio_probe)"
echo "---- avc denials after the filter was set"
dmesg | grep 'avc: *denied' | tail -n 10
echo "---- priority_filter messages"
dmesg | grep -i priority_filter | tail -n 10
