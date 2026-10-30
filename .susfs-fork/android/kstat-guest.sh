#!/system/bin/sh
# A sus_kstat rule on an Android guest, after guest-test.sh has loaded KernelSU and the module and
# prio-guest.sh has picked the packages. A smaller tmpfs is mounted over the path of the rule, so
# what statfs answers for it changes, and a real app uid must still be given the numbers from
# before the mount. Prints one "ANDROID key=value" line per fact.
T=/data/local/tmp
P=$T/kstat_probe
KS=$T/ks
APP=$(sed -n 3p $T/pkgs | cut -d' ' -f2)

say() { echo "ANDROID $*"; }
yesno() { if "$@"; then echo yes; else echo no; fi; }

# CMD_SUSFS_ADD_SUS_KSTAT and CMD_SUSFS_UPDATE_SUS_KSTAT: struct st_susfs_sus_kstat has its path at
# byte 16 and is 376 bytes long.
kstat_cmd() {
  "$T/mod/bin/susfs_sc" "$1" "$(printf '%032d' 0)$(printf '%s' "$2" | od -An -v -tx1 | tr -d ' \n')$(printf "%0$((2 * (360 - ${#2})))d" 0)" 2>&1 |
    sed -n 's/^susfs_sc: err=\(-*[0-9]*\) .*/\1/p'
}
# ksb WHO MODE: the f_blocks one caller gets from one call
ksb() {
  if [ "$1" = root ]; then "$P" "$2" "$KS"; else su "$1" "$P" "$2" "$KS"; fi | sed -n 's/^blocks=//p'
}
# which of the two answers that was, or the number if neither
kwho() { case $1 in "$2") echo real ;; "$3") echo covered ;; *) echo "other:$1" ;; esac; }

chmod 755 "$P"
say "app_uid=$APP"
umount "$KS" > /dev/null 2>&1
mkdir -p "$KS"
chmod 755 "$KS"
kreal=$(ksb root statfs)
say "add_err=$(kstat_cmd 0x55570 "$KS")"
mount -t tmpfs -o size=1m tmpfs "$KS"
ksmall=$(ksb root statfs)
say "mounts_differ=$(yesno [ "$kreal" != "$ksmall" ])"
say "before_update_app=$(kwho "$(ksb "$APP" statfs)" "$kreal" "$ksmall")"
say "update_err=$(kstat_cmd 0x55571 "$KS")"
say "statfs_app=$(kwho "$(ksb "$APP" statfs)" "$kreal" "$ksmall")"
say "fstatfs_app=$(kwho "$(ksb "$APP" fstatfs)" "$kreal" "$ksmall")"
say "statfs_root=$(kwho "$(ksb root statfs)" "$kreal" "$ksmall")"
echo clear > /proc/susfs_kstat
say "cleared_app=$(kwho "$(ksb "$APP" statfs)" "$kreal" "$ksmall")"
umount "$KS"
say "avc_probe=$(dmesg | grep 'avc: *denied' | grep -c kstat_probe)"
