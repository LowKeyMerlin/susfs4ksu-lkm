#!/system/bin/sh
# /proc/susfs_map on an Android guest, after guest-test.sh has loaded KernelSU and the module and
# prio-guest.sh has picked the packages. The rule is for a library every app maps, reached through a
# symlink, and the reader is a real app uid under SELinux. Prints one "ANDROID key=value" line per fact.
T=/data/local/tmp
N=/proc/susfs_map
LIB=/system/lib64/libc.so
APP=$(sed -n 3p $T/pkgs | cut -d' ' -f2)

say() { echo "ANDROID $*"; }
yesno() { if "$@"; then echo yes; else echo no; fi; }
count() { sed -n 's/^rules: \([0-9]*\)\/.*/\1/p' $N; }
# wr LINE: yes if root's write was accepted
wr() { if { echo "$1" > $N; } 2> /dev/null; then echo yes; else echo no; fi; }
sees() { yesno [ "$(su "$APP" grep -c 'libc\.so' /proc/self/maps)" -gt 0 ]; }

say "app_uid=$APP"
echo clear > $N
say "start=$(count)"
say "sees_before=$(sees)"
say "add=$(wr "add $LIB")/$(count)"
say "listed=$(grep -c '^ino=' $N)"
say "sees_hidden=$(sees)"
say "root_sees=$(yesno [ "$(grep -c 'libc\.so' /proc/self/maps)" -gt 0 ])"
say "app_write=$(yesno su "$APP" sh -c "echo clear > $N" 2> /dev/null)"
say "count_after_app=$(count)"
say "del=$(wr "del $LIB")/$(count)"
say "sees_after_del=$(sees)"
say "missing=$(wr 'add /nonexistent')"
echo clear > $N
say "avc_app=$(dmesg | grep 'avc: *denied' | grep -c 'susfs_map')"
