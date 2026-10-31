#!/bin/busybox sh
# SPDX-License-Identifier: GPL-2.0-only
# PID 1 of the smoke VM (see boot.sh). Runs the module's scripts the way KernelSU does and
# prints "SMOKE key=value" lines. check.py does the judging.
/bin/busybox --install -s /bin
export PATH=/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
# The loader reads real addresses from /proc/kallsyms.
echo 0 >/proc/sys/kernel/kptr_restrict

. /smoke.env
M=/module
say() { echo "SMOKE $*"; }
yesno() { if "$@"; then echo yes; else echo no; fi; }
ZERO=0000000000000000000000000000000000000000
# The guard's probe, from an executable copy: the module's copy is not until its scripts fix it.
probe() { /bin/sc 0x555e1 "$ZERO" >/dev/null 2>&1; echo $?; }
# The ksuctl output without its prefix, and the value of a successful answer.
kline() { sed -n 's/^ksuctl: //p'; }
kval() { sed -n 's/^ksuctl: [a-z]* rc=0 value=\(.*\)$/\1/p'; }
refused() { case $1 in *" rc=-"*) echo yes ;; *) echo no ;; esac; }

# Short timings, the VM stands in for a completed boot.
export GUARD_SETTLE=0 GUARD_POLL=1 GUARD_BOOT_WAIT=30

real=$(cat /proc/sys/kernel/osrelease)
say "kernel=$real"
# Observational, not asserted: whether this boot's CPU has BTI, which is what 0001's fix
# (clearing BTYPE before a skipped probe returns) only matters on.
say "cpu_bti=$(grep -c ' bti' /proc/cpuinfo)"

# The build images' kernels have no Android tag in their release but a device does, and the
# scripts pick the .ko by it, so show them one with a tag. The kernel's own vermagic is unaffected.
kver=${VARIANT#*-}
os=${VARIANT%-*}
patch=${real#"$kver".}
patch=${patch%%-*}
case $patch in
'' | *[!0-9]*) fake= ;;
*) fake="$kver.$patch-$os-0-g${real##*-g}" ;;
esac
case $real in *"$os"-[0-9]*) fake=$real ;; esac
if [ -n "$fake" ]; then
  echo "$fake" >/tmp/osrelease
  mount --bind /tmp/osrelease /proc/sys/kernel/osrelease 2>/dev/null
fi
seen=$(cat /proc/sys/kernel/osrelease)
say "osrelease_value=$seen"
case $seen in *"$os"-[0-9]*) say "osrelease=ok" ;; *) say "osrelease=failed" ;; esac

say "probe_before=$(probe)"

if [ -n "$POLICY" ]; then
  say "selinuxfs_listed=$(grep -c selinuxfs /proc/filesystems)"
  mount -t selinuxfs selinuxfs /sys/fs/selinux
  say "selinuxfs_mount_rc=$?"
  say "policyvers=$(cat /sys/fs/selinux/policyvers 2>&1)"
  say "enforce_before=$(cat /sys/fs/selinux/enforce 2>&1)"
  cat "$POLICY" >/sys/fs/selinux/load
  say "policy_load_rc=$?"
  say "enforce_after_policy=$(cat /sys/fs/selinux/enforce 2>&1)"
  say "context_self=$(cat /proc/self/attr/current 2>&1)"
fi

if [ -n "$KSU" ]; then
  say "ksu_load_start=yes"
  "$M/bin/susfs_insmod" -v "$KSU"
  say "ksu_load_rc=$?"
  say "ksu_umount_sym=$(grep -c ' ksu_uid_should_umount' /proc/kallsyms)"
  say "ksu_allow_sym=$(grep -c ' __ksu_is_allow_uid_for_current' /proc/kallsyms)"
  say "ksu_reboot_probes=$(grep -c reboot /sys/kernel/debug/kprobes/list 2>/dev/null)"
  # ksud reports the boot stage before it runs a module script, and a fork may apply its SELinux
  # rules only on that event.
  say "ksu_post_fs_data=$(/bin/ksuctl event post-fs-data | kline)"
fi

cd "$M" || exit 1
# KernelSU runs stage scripts as root with busybox sh.
/system/bin/sh ./post-fs-data.sh
say "load_rc=$?"
say "probe_after=$(probe)"
say "sysfs=$(if [ -d /sys/module/susfs_guard_lkm ]; then echo present; else echo absent; fi)"
say "armed=$(yesno [ -f guard.armed ])"
say "disabled=$(yesno [ -f disable ])"
say "tripped=$(yesno [ -f guard.tripped ])"
say "description=$(sed -n 's/^description=//p' module.prop)"

# Boot settles: service.sh starts the job that clears the marker.
/system/bin/sh ./service.sh
i=0
while [ -f guard.armed ] && [ "$i" -lt 30 ]; do
  sleep 1
  i=$((i + 1))
done
say "armed_after_settle=$(yesno [ -f guard.armed ])"

# Load again in the same boot, as the early loader and post-fs-data.sh may both do.
/system/bin/sh ./post-fs-data.sh
say "second_load_rc=$?"
say "second_load_count=$(find /sys/module -maxdepth 1 -name susfs_guard_lkm | wc -l)"
say "disabled_after=$(yesno [ -f disable ])"

# Hooks that skip a function for the reader. Each is used as in practice: add a rule where one
# is needed and read what the hook filters as an app uid. A skip that leaves the CPU in a wrong
# state shows up as a crash on the console.
mkdir -p /etc
: >/etc/passwd
: >/etc/group
for u in app:10000 mgr:10001 keep:10002 root_app:10003 deny:10004 hid:10005 vis:10006 swp:10007; do
  echo "${u%:*}:x:${u#*:}:${u#*:}::/:/bin/sh" >>/etc/passwd
  echo "${u%:*}:x:${u#*:}:" >>/etc/group
done
# Without randomisation this binary maps at the same address in every process.
echo 0 >/proc/sys/kernel/randomize_va_space
# Run a command line as an app uid. Keep redirections outside, /dev/null is root's here.
as_user() { u=$1; shift; /bin/busybox su -s /bin/sh "$u" -c "$*"; }
as_app() { as_user app "$@"; }
P=/sys/module/susfs_guard_lkm/parameters
# mapstat LINE KEY: one counter of map_stat
mapstat() { sed -n "${1}p" "$P/map_stat" | tr ' ' '\n' | sed -n "s/^$2=//p" | sed -n 1p; }
# The reply of CMD_SUSFS_ADD_SUS_MAP is struct { char path[256]; int err; }, sent as hex.
sus_map_add() {
  /bin/sc 0x60020 "$(printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')$(printf "%0$((2 * (260 - ${#1})))d" 0)" 2>&1 |
    sed -n 's/^susfs_sc: err=\(-*[0-9]*\) .*/\1/p'
}

say "app_uid=$(as_app id -u)"

say "map_rule_missing_err=$(sus_map_add /nonexistent)"
say "map_rule_err=$(sus_map_add /bin/busybox)"
base=$(grep busybox /proc/self/maps | cut -d- -f1 | sed -n 1p)
say "maps_root_sees=$(yesno [ "$(grep -c busybox /proc/self/maps)" -gt 0 ])"
say "maps_app_sees=$(yesno [ "$(as_app grep -c busybox /proc/self/maps)" -gt 0 ])"
say "maps_hook_ran=$(yesno [ "$(mapstat 1 line_hides)" -gt 0 ])"
as_app cat /proc/self/smaps_rollup >/dev/null 2>&1
as_app dd if=/proc/self/pagemap bs=8 skip=$((0x$base / 4096)) count=1 >/dev/null 2>&1
as_app dd if=/proc/self/mem bs=1 skip=$((0x$base)) count=16 >/dev/null 2>&1
say "map_walk_skipped=$(mapstat 1 walk_skipped)"
say "map_mem_hides=$(mapstat 2 hides)"
# Which of the sus_map probes armed, and whether the memory-read ones ran at all.
say "map_probes_armed=$(mapstat 1 armed)"
say "map_gup_calls=$(mapstat 2 gup_calls)/$(mapstat 2 inner_calls)"

# Regression: filename_lookup()+putname() on a sus_path rule for a name that already exists
# panicked (BUG_ON double put) up to 5.12. Upstream fixed it after our patch for it. This also exercises the create gate's split (issue
# #115): root still sees the existing directory, an app is refused as an absent name under an
# unwritable parent would be.
mkdir -p /data/adb/sus_path_dir
echo "add /data/adb/sus_path_dir" >/proc/susfs_path
say "sus_path_add_rc=$?"
root_err=$(mkdir /data/adb/sus_path_dir 2>&1 1>/dev/null)
case $root_err in
*xist*) say "sus_path_create_root=EEXIST" ;;
*) say "sus_path_create_root=other:$root_err" ;;
esac
app_err=$(as_app "mkdir /data/adb/sus_path_dir 2>&1 1>/dev/null")
case $app_err in
*ermission*) say "sus_path_create_app=EACCES" ;;
*xist*) say "sus_path_create_app=EEXIST" ;;
*) say "sus_path_create_app=other:$app_err" ;;
esac
echo "del /data/adb/sus_path_dir" >/proc/susfs_path

# open_redirect: a rule with scheme 3 (umounted app) redirects only the app's own read; root and
# a cleared rule both answer with the real file.
mkdir -p /data/local/tmp
echo ORIGINAL >/data/local/tmp/or_target
echo FAKE >/data/local/tmp/or_fake
echo "add_open_redirect /data/local/tmp/or_target /data/local/tmp/or_fake 3" >/proc/susfs_open_redirect
say "or_add_rc=$?"
say "or_read_root=$(cat /data/local/tmp/or_target)"
say "or_read_app=$(as_app cat /data/local/tmp/or_target)"
echo "del /data/local/tmp/or_target" >/proc/susfs_open_redirect
say "or_del_rc=$?"
say "or_read_app_after_del=$(as_app cat /data/local/tmp/or_target)"

# Who counts as an app to hide from is KernelSU's call, so ask it per uid, then show the
# mapping. Only the manager can set profiles.
if [ -n "$KSU" ]; then
  sees() { yesno [ "$(as_user "$1" grep -c busybox /proc/self/maps)" -gt 0 ]; }
  # The manager is named through the module parameter of a debug build, or through the toolkit
  # call of backslashxx, whose module hides its sysfs entry. It counts only once KernelSU itself
  # stops unmounting modules for that uid.
  DBG=/sys/module/kernelsu/parameters/ksu_debug_manager_appid
  say "ksu_boot_completed=$(/bin/ksuctl event boot-completed | kline)"
  say "ksu_umount_10000=$(/bin/ksuctl umount 10000 | kval)"
  say "ksu_sees_10000=$(sees app)"
  method=none
  if [ -w "$DBG" ]; then
    echo 10001 >"$DBG"
    m=param
  else
    /bin/ksuctl manager-toolkit 10001 >/dev/null
    m=toolkit
  fi
  [ "$(/bin/ksuctl umount 10001 | kval)" = 0 ] && method=$m
  say "ksu_manager_method=$method"
  if [ "$method" != none ]; then
    r=$(as_user app /bin/ksuctl profile 10002 keep | kline)
    say "ksu_nonmanager_profile_refused=$(refused "$r")"
    r=$(as_user app /bin/ksuctl event post-fs-data | kline)
    say "ksu_nonroot_event_refused=$(refused "$r")"
    say "ksu_profile_keep=$(as_user mgr /bin/ksuctl profile 10002 keep | kline)"
    say "ksu_profile_allow=$(as_user mgr /bin/ksuctl profile 10003 allow | kline)"
    say "ksu_profile_deny=$(as_user mgr /bin/ksuctl profile 10004 deny | kline)"
    for u in mgr:10001 keep:10002 root_app:10003 deny:10004; do
      say "ksu_umount_${u#*:}=$(/bin/ksuctl umount "${u#*:}" | kval)"
      say "ksu_granted_${u#*:}=$(/bin/ksuctl granted "${u#*:}" | kval)"
      say "ksu_sees_${u#*:}=$(sees "${u%:*}")"
    done
  fi
fi

# The priority uid filter answers "no such user" when a uid asks about another one. Hidden uids
# are named like packages and looked up under /data/data, so a directory owned by a uid stands in
# for an installed app, and a process of that uid must exist or every uid gets "no such user".
# A row is what getpriority, setpriority, ioprio_get, ioprio_set and ioprio_set with an invalid
# class returned, with "ok" for any success.
PRIO=/bin/prio_probe
PRIO32=/bin/prio_probe32
for d in hid:10005 vis:10006 low:9999 high:20000; do
  mkdir -p "/data/data/${d%:*}"
  chown "${d#*:}" "/data/data/${d%:*}"
done
as_user hid 'exec sleep 3600' >/dev/null 2>&1 &
hidpid=$!
as_user vis 'exec sleep 3600' >/dev/null 2>&1 &
for i in 1 2 3 4 5; do
  [ "$(as_app "$PRIO user 10005" | sed -n 's/^getpriority=//p')" = 20 ] && break
  sleep 1
done
row() {
  { if [ "$1" = root ]; then "${3:-$PRIO}" user "$2"; else as_user "$1" "${3:-$PRIO} user $2"; fi; } |
    sed 's/^[a-z_]*=//; s/^[0-9][0-9]*$/ok/' | tr '\n' ',' | sed 's/,$//'
}
# The reboot result and the err the kernel wrote back, 126 if it did not handle the command.
pset() {
  { if [ "$1" = app ]; then as_user app "$PRIO set $2"; else "$PRIO" set "$2"; fi; } |
    tr '\n' ' ' | sed 's/^set_rc=\(-*[0-9]*\) set_err=\(-*[0-9]*\) *$/\1,\2/'
}
pidrow() { as_app "$PRIO pid $1" | sed 's/^[a-z_]*=//; s/^[0-9][0-9]*$/ok/' | tr '\n' ',' | sed 's/,$//'; }

say "prio_before_app=$(row app 10005)"
say "prio_before_compat_app=$(row app 10005 "$PRIO32")"
say "prio_set_hid=$(pset root hid)"
say "prio_hid_app=$(row app 10005)"
say "prio_hid_compat_app=$(row app 10005 "$PRIO32")"
say "prio_visible_app=$(row app 10006)"
say "prio_visible_compat_app=$(row app 10006 "$PRIO32")"
say "prio_hid_own=$(row hid 10005)"
say "prio_hid_own_compat=$(row hid 10005 "$PRIO32")"
say "prio_who0_app=$(row app 0)"
say "prio_hid_root=$(row root 10005)"
say "prio_by_pid_app=$(pidrow "$hidpid")"
if [ "${method:-none}" != none ]; then
  for u in mgr keep root_app deny; do
    say "prio_ksu_$u=$(row "$u" 10005)"
  done
fi

# A new list replaces the old one. A list that cannot be taken is refused whole.
say "prio_set_vis=$(pset root vis)"
say "prio_replaced=$(row app 10005)/$(row app 10006)"
say "prio_set_missing=$(pset root nosuch)"
say "prio_set_dotdot=$(pset root ..)"
say "prio_set_slash=$(pset root hid/x)"
say "prio_set_empty=$(pset root '')"
say "prio_set_low_uid=$(pset root low)"
say "prio_set_high_uid=$(pset root high)"
say "prio_set_unterminated=$("$PRIO" setfill | tr '\n' ' ' | sed 's/^set_rc=\(-*[0-9]*\) set_err=\(-*[0-9]*\) *$/\1,\2/')"
say "prio_set_by_app=$(pset app hid)"
say "prio_refused_keeps=$(row app 10005)/$(row app 10006)"
say "prio_set_list=$(pset root ' hid, ,vis ,')"
say "prio_list_hides=$(row app 10005)/$(row app 10006)"
say "prio_list_hides_compat=$(row app 10005 "$PRIO32")/$(row app 10006 "$PRIO32")"

# A call made while the list is replaced sees the old list or the new one. The list can change
# between the calls of one row, so judge each column alone: the real answer or "no such user".
race_row_ok() (
  IFS=,
  # shellcheck disable=SC2086  # split on the commas
  set -- $1
  [ $# = 5 ] || exit 1
  case "$1" in ok | -3) ;; *) exit 1 ;; esac
  case "$2" in -1 | -3) ;; *) exit 1 ;; esac
  case "$3" in ok | -3) ;; *) exit 1 ;; esac
  case "$4" in -1 | -3) ;; *) exit 1 ;; esac
  [ "$5" = -22 ]
)
(
  n=0
  while [ "$n" -lt 40 ]; do
    "$PRIO" set hid >/dev/null
    "$PRIO" set vis >/dev/null
    n=$((n + 1))
  done
) &
setter=$!
bad=0
first_bad=
for i in $(seq 1 40); do
  r=$(row app 10005)
  if ! race_row_ok "$r"; then
    bad=$((bad + 1))
    [ -n "$first_bad" ] || first_bad=$r
  fi
done
wait "$setter"
say "prio_race_bad_rows=$bad"
[ "$bad" = 0 ] || say "prio_race_first_bad=$first_bad"
say "prio_after_race=$(pset root vis)"

# The list is resolved again when the package manager writes packages.list, so a package that
# returns under another uid is followed. The owner of "vis" changes as on a reinstall, and a
# process of each uid tells the old one from the new one. Nothing changes until the file is moved
# into /data/system, a move elsewhere or of another name is not the event.
as_user swp 'exec sleep 3600' >/dev/null 2>&1 &
chown 10007 /data/data/vis
say "prio_refresh_stale=$(row app 10006)/$(row app 10007)"
mkdir -p /data/other /data/system
: >/data/other/packages.list.new
mv -f /data/other/packages.list.new /data/other/packages.list
: >/data/system/packages.xml.new
mv -f /data/system/packages.xml.new /data/system/packages.xml
sleep 3
say "prio_refresh_not_event=$(row app 10006)/$(row app 10007)"
: >/data/system/packages.list.new
mv -f /data/system/packages.list.new /data/system/packages.list
for i in 1 2 3 4 5 6; do
  [ "$(row app 10007)" = "-3,-3,-3,-3,-22" ] && break
  sleep 1
done
say "prio_refresh_followed=$(row app 10006)/$(row app 10007)"
# A burst while a pass is waiting is one pass, and a removed package is no longer hidden.
rmdir /data/data/vis
for i in 1 2 3 4 5; do
  : >/data/system/packages.list.new
  mv -f /data/system/packages.list.new /data/system/packages.list
done
sleep 3
say "prio_refresh_removed=$(row app 10006)/$(row app 10007)"
# What is hidden from whom depends on the reader's SELinux domain, which the VM has no policy
# for, so this only has to run.
mkdir -p /data/adb/m
mount -t tmpfs /data/adb/m /data/adb/m
say "mounts_hide_rc=$(/bin/sc 0x55561 0100000000000000 >/dev/null 2>&1; echo $?)"
say "mountinfo_app_lines=$(as_app grep -c /data/adb /proc/self/mountinfo)"

# A sus_kstat rule makes statfs and fstatfs answer an app with what the path answered when the
# rule was added. A smaller tmpfs is then mounted over the path, so the real answer is the other
# one, and update_sus_kstat points the rule at the new mount. A rule for another path, and a
# caller that is not an app, are answered as before.
KS=/ks
KSTAT=/bin/kstat_probe
KSTAT32=/bin/kstat_probe32
# CMD_SUSFS_ADD_SUS_KSTAT and CMD_SUSFS_UPDATE_SUS_KSTAT: struct st_susfs_sus_kstat has its path at
# byte 16 and is 376 bytes long.
kstat_cmd() {
  /bin/sc "$1" "$(printf '%032d' 0)$(printf '%s' "$2" | od -An -v -tx1 | tr -d ' \n')$(printf "%0$((2 * (360 - ${#2})))d" 0)" 2>&1 |
    sed -n 's/^susfs_sc: err=\(-*[0-9]*\) .*/\1/p'
}
# ksb WHO MODE PATH [PROBE]: the f_blocks one caller gets from one call
ksb() {
  { if [ "$1" = root ]; then "${4:-$KSTAT}" "$2" "$3"; else as_user "$1" "${4:-$KSTAT} $2 $3"; fi; } |
    sed -n 's/^blocks=//p'
}
# which of the two answers that was, or the number if neither
kwho() { case $1 in "$2") echo real ;; "$3") echo covered ;; *) echo "other:$1" ;; esac; }
mkdir -p $KS
kreal=$(ksb root statfs $KS)
# kfd WHO PATH: the mnt_id and ino lines of fdinfo, for a descriptor WHO holds open on PATH. The
# reader is the process that asks, so the shell opens the descriptor and reads its own fdinfo.
kfd() {
  kfd_cmd="exec 7<$2; grep -E '^(mnt_id|ino):' /proc/\$\$/fdinfo/7"
  if [ "$1" = root ]; then /bin/sh -c "$kfd_cmd"; else as_user "$1" "$kfd_cmd"; fi | tr '\t\n' ': '
}
# kin WHO PATH [PROBE]: the ino and sdev of an inotify watch on PATH, as WHO's fdinfo lists it. The
# fhandle that follows holds the real inode in a filesystem form and is not looked at.
kcall() { if [ "$1" = root ]; then "$2" "$3" "$4"; else as_user "$1" "$2 $3 $4"; fi; }
kin() { kcall "$1" "${3:-$KSTAT}" inotify "$2" |
  sed -n -e 's/^inotify wd:[0-9a-f]* ino:\([0-9a-f]*\) sdev:\([0-9a-f]*\) .*/\1:\2/p' -e '/^\(inotify_\|fdinfo_\)/p'; }
say "kstat_add_err=$(kstat_cmd 0x55570 $KS)"
kfd_before=$(kfd root $KS)
kin_before=$(kin root $KS)
mount -t tmpfs -o size=1m tmpfs $KS
ksmall=$(ksb root statfs $KS)
say "kstat_mounts_differ=$(yesno [ "$kreal" != "$ksmall" ])"
say "kstat_before_update_app=$(kwho "$(ksb app statfs $KS)" "$kreal" "$ksmall")"
say "kstat_update_err=$(kstat_cmd 0x55571 $KS)"
# fdinfo prints the mount id and inode of the file, so a descriptor on the path shows what is behind
# it, where stat says otherwise. An app is given what the path was when the rule was added.
kfd_after=$(kfd root $KS)
kin_after=$(kin root $KS)
# An inotify watch lists the inode and device of the file, which a rule spoofs for an app as it does
# in stat. Both ABIs, since the 32-bit task reads the same text through the AArch32 table.
say "kin_mounts_differ=$(yesno [ -n "$kin_before" ] && [ "$kin_before" != "$kin_after" ])"
say "kin_root=$(kwho "$(kin root $KS)" "$kin_before" "$kin_after")"
say "kin_app=$(kwho "$(kin app $KS)" "$kin_before" "$kin_after")"
say "kin_app_compat=$(kwho "$(kin app $KS "$KSTAT32")" "$kin_before" "$kin_after")"
say "kin_other_path_app=$(yesno [ -n "$(kin app /proc)" ] && [ "$(kin app /proc)" = "$(kin root /proc)" ])"
say "kfd_mounts_differ=$(yesno [ "$kfd_before" != "$kfd_after" ])"
say "kfd_root=$(kwho "$(kfd root $KS)" "$kfd_before" "$kfd_after")"
say "kfd_app=$(kwho "$(kfd app $KS)" "$kfd_before" "$kfd_after")"
say "kfd_other_path_app=$(yesno [ "$(kfd app /proc)" = "$(kfd root /proc)" ])"
say "kfd_other_path_app_sys=$(yesno [ "$(kfd app /sys)" = "$(kfd root /sys)" ])"
# A bind mount of the same filesystem has the same inode and device under another mount id, and is
# the same file as far as the rule is concerned, as upstream matches on inode and device.
mkdir -p /ks_bind
mount --bind $KS /ks_bind
say "kfd_bind_root_differs=$(yesno [ "$(kfd root /ks_bind)" != "$kfd_before" ])"
say "kfd_bind_app=$(kwho "$(kfd app /ks_bind)" "$kfd_before" "$kfd_after")"
say "kin_bind_app=$(kwho "$(kin app /ks_bind)" "$kin_before" "$kin_after")"
umount /ks_bind
# Another filesystem that may hold the same inode number (the root of a fresh tmpfs) is not the
# rule's file and is left alone: the match is on the device as well.
mkdir -p /ks_other
mount -t tmpfs tmpfs /ks_other
say "kfd_other_dev_app=$(yesno [ "$(kfd app /ks_other)" = "$(kfd root /ks_other)" ])"
say "kfd_other_dev_same_ino=$(yesno [ "$(kfd root /ks_other | sed 's/.*ino:://')" = "$(kfd root $KS | sed 's/.*ino:://')" ])"
umount /ks_other
# "n/m": armed on n of the m seq_show symbols found. Only some of them is a hook that misses
# the one that matters, none is no hook.
say "kfd_hook_armed=$(dmesg | sed -n 's/.*susfs_kstat: fdinfo hook armed (seq_show on \([0-9]*\)\/\([0-9]*\) symbols).*/\1 \2/p' | tail -1 |
  awk '{ print ($1 == $2 && $1 > 0) ? "all" : "partial:" $1 "/" $2 } END { if (NR == 0) print "none" }')"
say "kstat_statfs_app=$(kwho "$(ksb app statfs $KS)" "$kreal" "$ksmall")"
say "kstat_fstatfs_app=$(kwho "$(ksb app fstatfs $KS)" "$kreal" "$ksmall")"
say "kstat_statfs_app_compat=$(kwho "$(ksb app statfs $KS "$KSTAT32")" "$kreal" "$ksmall")"
say "kstat_fstatfs_app_compat=$(kwho "$(ksb app fstatfs $KS "$KSTAT32")" "$kreal" "$ksmall")"
say "kstat_statfs_root=$(kwho "$(ksb root statfs $KS)" "$kreal" "$ksmall")"
# fstatfs takes an O_PATH descriptor (fs/statfs.c fd_statfs() uses fdget_raw), so the module's own
# fd lookup must not reject one: an app and root get the same answers as for a plain descriptor.
say "kstat_fstatfs_opath_app=$(kwho "$(ksb app fstatfs_opath $KS)" "$kreal" "$ksmall")"
say "kstat_fstatfs_opath_app_compat=$(kwho "$(ksb app fstatfs_opath $KS "$KSTAT32")" "$kreal" "$ksmall")"
say "kstat_fstatfs_opath_root=$(kwho "$(ksb root fstatfs_opath $KS)" "$kreal" "$ksmall")"
say "kstat_other_path_app=$(yesno [ "$(ksb app statfs /proc)" = "$(ksb root statfs /proc)" ])"
# A caller the rules apply to is answered by the module and not by the kernel, so what the kernel
# fails with, and the bytes it fills in on the paths no rule names, have to come out the same.
# kcall WHO PROBE MODE PATH: the probe's output as that caller
say "kstat_errors_root=$(kcall root $KSTAT errors $KS | tr '\n' ,)"
say "kstat_errors_app=$(kcall app $KSTAT errors $KS | tr '\n' ,)"
say "kstat_errors_app_compat=$(kcall app $KSTAT32 errors $KS | tr '\n' ,)"
kexact=yes
for kp in $KSTAT $KSTAT32; do
  for km in statfs fstatfs; do
    for kd in /proc /sys; do
      kr=$(kcall root $kp $km $kd | sed -n 's/^csum=//p')
      ka=$(kcall app $kp $km $kd | sed -n 's/^csum=//p')
      [ -n "$kr" ] && [ "$kr" = "$ka" ] || kexact="no:$kp/$km/$kd"
    done
  done
done
say "kstat_exact_app=$kexact"
# Many readers while the rule is cleared and added again: every answer is one of the two the path
# can give, never a half-rewritten line, and nothing crashes. Last, as it leaves the rule on the
# mounted path.
kfd_bad=/data/local/tmp/kfd_bad
rm -f $kfd_bad
kfd_pids=
for r in 1 2 3 4; do
  ( i=0
    while [ "$i" -lt 25 ]; do
      out=$(kfd app $KS)
      [ "$out" = "$kfd_before" ] || [ "$out" = "$kfd_after" ] || echo "$out" >>$kfd_bad
      i=$((i + 1))
    done ) &
  kfd_pids="$kfd_pids $!"
done
for i in 1 2 3 4 5 6; do
  echo clear >/proc/susfs_kstat
  kstat_cmd 0x55570 $KS >/dev/null
  kstat_cmd 0x55571 $KS >/dev/null
done
# only the readers: the sleepers started for the priority test are still running
wait $kfd_pids
say "kfd_race_bad_answers=$([ -f $kfd_bad ] && wc -l <$kfd_bad || echo 0)"
echo clear >/proc/susfs_kstat
say "kstat_cleared_app=$(kwho "$(ksb app statfs $KS)" "$kreal" "$ksmall")"
say "kfd_cleared_app=$(kwho "$(kfd app $KS)" "$kfd_before" "$kfd_after")"
say "kin_cleared_app=$(kwho "$(kin app $KS)" "$kin_before" "$kin_after")"

# A mount under /data/adb is marked. An umounted app's statfs of it is answered with the numbers of
# the first mount above it that is not, as upstream does in vfs_statfs; root keeps the real ones.
# The VM has no KernelSU, so "umounted" is the app half of the gate, as for the rest of the module.
kmsn() { sed -n 's/.*statfs: redirects=\([0-9]*\).*/\1/p' /sys/module/susfs_guard_lkm/parameters/mount_stat; }
# From 6.12 (the first KMI with listmount/statmount) the module reports three probe lines on
# mount_stat.  grab_requested_root is the primary hook (it closes the statmount target and the
# listmount parent); the listmount wrapper compacts the id array; the statmount wrapper is a
# fallback armed only when grab_requested_root could not be.  "absent" means a kernel without them.
MS=/sys/module/susfs_guard_lkm/parameters/mount_stat
probe_of() { sed -n "s/^$1: .*(probe=\([01]\)).*/\1/p" "$MS"; }
if grep -q '^mntroot: ' "$MS" 2>/dev/null; then
  say "lm_mntroot_probe=$(probe_of mntroot)"
  say "lm_listmount_probe=$(probe_of listmount)"
  say "lm_statmount_fallback_probe=$(probe_of statmount_fallback)"
else
  say "lm_mntroot_probe=absent"
fi
mkdir -p /data/adb/ms /ms_bind
kparent=$(ksb root statfs /data/adb)
kroot_fs=$(ksb root statfs /)
mount -t tmpfs -o size=2m tmpfs /data/adb/ms
echo reset >/proc/susfs_hide_mounts
ktmp=$(ksb root statfs /data/adb/ms)
say "kms_mounts_differ=$(yesno [ -n "$kparent" ] && [ "$ktmp" != "$kparent" ])"
say "kms_root=$(kwho "$ktmp" "$kparent" "$ktmp")"
say "kms_app=$(kwho "$(ksb app statfs /data/adb/ms)" "$kparent" "$ktmp")"
say "kms_fstatfs_app=$(kwho "$(ksb app fstatfs /data/adb/ms)" "$kparent" "$ktmp")"
say "kms_app_compat=$(kwho "$(ksb app statfs /data/adb/ms "$KSTAT32")" "$kparent" "$ktmp")"
# Failing calls come out as the kernel's, on a marked mount as anywhere else.
say "kms_errors_app=$(kcall app $KSTAT errors /data/adb/ms | tr '\n' ,)"
say "kms_errors_app_compat=$(kcall app $KSTAT32 errors /data/adb/ms | tr '\n' ,)"
# A path on no marked mount is not redirected, and the counter says so.
kms_n0=$(kmsn)
say "kms_other_path_app=$(yesno [ "$(ksb app statfs /proc)" = "$(ksb root statfs /proc)" ])"
say "kms_other_path_counted=$(yesno [ "$(kmsn)" = "$kms_n0" ])"
# The same mount seen at an ordinary mount id (a bind mount outside /data/adb) is recognised by the
# identity the scan recorded, and the answer is that of the mount it sits on.
mount --bind /data/adb/ms /ms_bind
say "kms_ident_root=$(kwho "$(ksb root statfs /ms_bind)" "$kroot_fs" "$ktmp")"
say "kms_ident_app=$(kwho "$(ksb app statfs /ms_bind)" "$kroot_fs" "$ktmp")"
umount /ms_bind

# listmount(2)/statmount(2) hiding, 6.12+ only.  The marked mount /data/adb/ms has a 64-bit unique
# id; a detector enumerates it with listmount or confirms a held id with statmount.  Root is the
# control: it must still see everything.  lm_id is read as root (the real unique id the module
# recorded); the app half is the hidden reader on this KernelSU-less VM.
# lmc KEY reads a listmount counter off mount_stat.
lmc() { sed -n "s/^listmount: .*$1=\([0-9-]*\).*/\1/p" "$MS"; }
# lids WHO NR [PARENT] lists the ids listmount gives WHO, NR per call, one per line.
lids() {
  if [ "$1" = root ]; then $KSTAT listmount "$2" $3; else as_user "$1" "$KSTAT listmount $2 $3"; fi |
    sed -n 's/^id=//p'
}
# lhas WHO NR ID: yes if listmount gives WHO the id ID (whole pipeline, so yesno reads grep's status).
lhas() { lids "$1" "$2" | grep -qx "$3"; }
if grep -q '^mntroot: ' "$MS" 2>/dev/null; then
  lm_id=$(kcall root $KSTAT mntid /data/adb/ms | sed -n 's/^mntid=//p')
  say "lm_id_read=$(yesno [ -n "$lm_id" ])"
  # Root sees the id when it lists the whole tree; both buffer sizes.
  say "lm_root_sees_big=$(yesno lhas root 4096 "$lm_id")"
  say "lm_root_sees_one=$(yesno lhas root 1 "$lm_id")"
  # A hidden reader with a roomy buffer never sees it, and still reaches the real mounts (a non-zero
  # count, so the list was not truncated to nothing).
  say "lm_app_sees_big=$(yesno lhas app 4096 "$lm_id")"
  say "lm_app_count_big=$(lids app 4096 | grep -c .)"
  # The page is shortened by moving the kept ids down; the slots past the new count must not keep the
  # old values.  lids only prints the reported slots, so listmount_tail reads the whole buffer.
  # /data/adb/ms is the newest mount here, so it is in the last slot of the unfiltered answer.
  say "lm_app_tail_hidden=$(as_app "$KSTAT listmount_tail 4096 $lm_id" | sed -n 's/^tail_hidden=//p')"
  say "lm_root_tail_shows=$($KSTAT listmount_tail 4096 "$lm_id" | sed -n 's/^reported_hidden=.*/yes/p')"
  # A buffer of one is the documented residual: a page that is entirely our id cannot be shortened to
  # zero without ending the walk, so it goes out and the module counts it as full_leak.  The test
  # records both, rather than pretending the leak is closed.
  before_full=$(lmc full_leak)
  say "lm_app_one_leaks=$(yesno lhas app 1 "$lm_id")"
  say "lm_app_one_full_counted=$(yesno [ "$(lmc full_leak)" -gt "${before_full:-0}" ])"
  # statmount of the marked id, held by a detector, is fully closed for the app and open for root.
  say "lm_statmount_app=$(kcall app $KSTAT statmount "$lm_id" | sed -n 's/^rc=//p')"
  say "lm_statmount_root_matches=$(yesno [ -n "$lm_id" ] &&
    [ "$(kcall root $KSTAT statmount "$lm_id" | sed -n 's/^sm_mnt_id=//p')" = "$lm_id" ])"
  say "lm_statmount_app_compat=$(kcall app $KSTAT32 statmount "$lm_id" | sed -n 's/^rc=//p')"
  # A mount the module does not hide is still answered, so statmount is not blanket-denied: root's
  # own id for / proves a normal lookup works.
  root_id=$(kcall root $KSTAT mntid / | sed -n 's/^mntid=//p')
  say "lm_statmount_app_other=$(kcall app $KSTAT statmount "$root_id" | sed -n 's/^rc=//p')"
  # listmount under the hidden mount as the parent is closed too (the mnt_parent_id oracle).
  say "lm_app_parent_rc=$(as_app "$KSTAT listmount 4 $lm_id" | sed -n 's/^rc=//p')"
  # Same request from root has no children to list but succeeds, so the app's error is ours.
  say "lm_root_parent_count=$($KSTAT listmount 4 "$lm_id" | sed -n 's/^count=//p')"
fi
# Readers while the mount is lazily unmounted and mounted again: each answer is one a mount can
# give, an empty one while the path is gone, and nothing crashes.
kms_bad=/data/local/tmp/kms_bad
rm -f $kms_bad
kms_pids=
for r in 1 2 3; do
  ( i=0
    while [ "$i" -lt 40 ]; do
      out=$(ksb app statfs /data/adb/ms)
      case "$out" in "$kparent"|"$ktmp"|"") ;; *) echo "$out" >>$kms_bad ;; esac
      i=$((i + 1))
    done ) &
  kms_pids="$kms_pids $!"
done
for i in 1 2 3 4 5 6; do
  umount -l /data/adb/ms
  mount -t tmpfs -o size=2m tmpfs /data/adb/ms
done
wait $kms_pids
say "kms_race_bad_answers=$([ -f $kms_bad ] && wc -l <$kms_bad || echo 0)"
say "kms_redirects=$(kmsn)"
umount /data/adb/ms

# /proc/susfs_map manages the rules the supercall added above, and the listing and map_stat count
# the same table. A write is judged by its exit status: the shell fails on a negative return.
MAPN=/proc/susfs_map
mapcount() { sed -n 's/^rules: \([0-9]*\)\/.*/\1/p' $MAPN; }
# wr WHO LINE: yes if the write was accepted
wr() {
  if [ "$1" = root ]; then { echo "$2" >$MAPN; } 2>/dev/null; else as_user "$1" "echo '$2' >$MAPN" 2>/dev/null; fi &&
    echo yes || echo no
}
mapsees() { yesno [ "$(as_app grep -c busybox /proc/self/maps)" -gt 0 ]; }
say "mapproc_listed=$(grep -c '^ino=' $MAPN)/$(mapcount)/$(mapstat 1 rules)"
say "mapproc_add=$(wr root 'add /bin/sc')"
say "mapproc_count_after_add=$(mapcount)"
say "mapproc_add_again=$(wr root 'add /bin/sc')/$(mapcount)"
say "mapproc_add_missing=$(wr root 'add /nonexistent')"
say "mapproc_bad_verb=$(wr root bogus)"
say "mapproc_del=$(wr root 'del /bin/sc')/$(mapcount)"
say "mapproc_del_again=$(wr root 'del /bin/sc')"
# Deleted slots are reused, so adding and removing more than the 64 entries never fills the table.
fails=0
for i in $(seq 1 70); do
  [ "$(wr root 'add /bin/sc')" = yes ] && [ "$(wr root 'del /bin/sc')" = yes ] || fails=$((fails + 1))
done
say "mapproc_churn_failures=$fails"
say "mapproc_app_write=$(wr app clear)"
say "mapproc_app_read=$(yesno [ "$(as_app cat $MAPN 2>/dev/null | wc -l)" -gt 0 ])"
say "mapproc_count_after_app=$(mapcount)"
say "mapproc_clear=$(wr root clear)/$(mapcount)"
say "mapproc_sees_cleared=$(mapsees)"
say "mapproc_hide=$(wr root 'add /bin/busybox')/$(mapsees)"
say "mapproc_unhide=$(wr root 'del /bin/busybox')/$(mapsees)"
wr root clear >/dev/null
umount $KS

# The module hides itself from /proc/modules and kallsyms by default.
echo clear >/proc/susfs_hide_modules
say "modules_cleared_lists=$(yesno grep -q susfs_guard_lkm /proc/modules)"
say "kallsyms_cleared_lists=$(yesno grep -q '\[susfs_guard_lkm\]' /proc/kallsyms)"
echo add susfs_guard_lkm >/proc/susfs_hide_modules
say "modules_lists=$(yesno grep -q susfs_guard_lkm /proc/modules)"
say "kallsyms_lists=$(yesno grep -q '\[susfs_guard_lkm\]' /proc/kallsyms)"

# The zip's installer, sourced as KernelSU does with its functions, on a copy of the module.
# First an install that must work, then the two refusals for a device the module cannot serve.
# Every run writes the install log, also after a refusal, which is when it is read.
flat() { printf '%s' "$1" | tr -s '\n ' '  '; }
has() { case $(flat "$2") in *"$1"*) echo yes ;; *) echo no ;; esac; }
results() { printf '%s\n' "$1" | sed -n 's/^\[[1-4]\/5\] .* \.\.\. \(.*\)$/\1/p' | tr '\n' ',' | sed 's/,$//'; }
instlog=/data/adb/susfs_guard_lkm-install.log
logresult() { sed -n 's/^result=\([a-z]*\) .*/\1/p' "$instlog" 2>/dev/null; }
# Show the installer output and log on the console, next to the fact they explain.
show() { printf '%s\n' "$2" | sed "s/^/$1: /"; }
install_try() {
  rm -rf /tmp/inst
  cp -R "$M" /tmp/inst
  (
    MODPATH=/tmp/inst KSU=$1 ARCH=$2
    ui_print() { echo "$1"; }
    abort() { ui_print "$1"; rm -rf "$MODPATH"; exit 1; }
    set_perm() { :; }
    set_perm_recursive() { :; }
    . "$MODPATH/customize.sh"
  ) 2>&1
}
out=$(install_try true arm64)
say "installer_rc=$?"
say "installer_credits=$(has simonpunk "$out")$(has inforcqb "$out")$(has LowKeyMerlin "$out")"
say "installer_logo=$(has '|___/\___/|___/_| |___/ Installer' "$out")"
say "installer_title=$(has 'SUSFS Guard (LKM)' "$out")$(has 'Supports: Only KernelSU and its forks' "$out")"
say "installer_steps=$(printf '%s\n' "$out" | grep -c '^\[[1-5]/5\]')"
say "installer_results=$(results "$out")"
kmi=$(flat "$out" | sed -n 's/.*Kernel module \.\.\. ok KMI \([^ ]*\).*/\1/p')
say "installer_scope=$(cat /tmp/inst/guard.scope 2>/dev/null)"
say "installer_kmi=$(if [ "$kmi" = "$VARIANT" ]; then echo ok; else echo "${kmi:-none}"; fi)"
hook=/data/adb/post-fs-data.d/00-susfs-guard-lkm.sh
say "installer_hook=$(yesno [ "$(cat $hook 2>/dev/null)" = "$(cat /tmp/inst/early-dispatch.sh)" ])"
say "installer_log_result=$(logresult)"
say "installer_log_mode=$(stat -c %a "$instlog" 2>/dev/null)"
say "installer_log_kernel=$(grep -c '^osrelease ' "$instlog" 2>/dev/null)"
say "installer_log_upstream=$(yesno grep -q 'susfs_guard_lkm (arm64)' "$instlog")"
missing=
for s in Installer KernelSU Device Kernel Zip 'State before the install' 'What the installer showed' 'Upstream installer'; do
  grep -qx "== $s ==" "$instlog" 2>/dev/null || missing="$missing[$s]"
done
say "installer_log_missing=${missing:-none}"
show INSTALL "$out"
show INSTALLLOG "$(cat "$instlog" 2>&1)"
out=$(install_try true arm)
say "installer_arm_rc=$?"
show INSTALL-ARM "$out"
say "installer_arm_reason=$(has 'arm64 only' "$out")"
say "installer_arm_failed=$(has 'Installation failed' "$out")"
say "installer_arm_done=$(has '[5/5]' "$out")"
say "installer_arm_results=$(results "$out")"
say "installer_arm_log_result=$(logresult)"
say "installer_arm_log_reason=$(yesno grep -q 'arm64 only' "$instlog")"
out=$(install_try false arm64)
say "installer_noksu_rc=$?"
show INSTALL-NOKSU "$out"
say "installer_noksu_reason=$(has 'KernelSU-compatible manager required' "$out")"
say "installer_noksu_done=$(has '[5/5]' "$out")"
say "installer_noksu_results=$(results "$out")"
say "installer_noksu_log_result=$(logresult)"
say "installer_log_rotated=$(yesno grep -q 'arm64 only' "$instlog.old")"

for f in load.log guard.log; do
  [ -f "$f" ] && sed "s/^/LOG $f: /" "$f"
done
if [ -n "$KSU" ]; then
  dmesg | grep -E 'ksu_umount_gate|ksu_allow_gate|KernelSU|kernelsu|ksu' | sed 's/^/KSULOG: /'
fi
say "done=yes"
sync
poweroff -f
