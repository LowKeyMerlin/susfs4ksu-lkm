#!/system/bin/sh
# The SELinux status-page face on an Android guest, after guest-test.sh has loaded KernelSU and the
# module. A KernelSU-origin change (a su shell's setenforce) must leave the page an app watches as it
# was; the probes must be armed. Prints one "ANDROID key=value" line per fact.
N=/proc/susfs_selinux_status
S=/sys/fs/selinux/status

say() { echo "ANDROID $*"; }

# The page is five u32s: version sequence enforcing policyload deny_unknown.
sel_seq() { dd if=$S bs=4 skip=1 count=1 2>/dev/null | od -An -tu4 | tr -d ' \n'; }
sel_se_skip() { sed -n 's/^skips: policyload=[0-9]* setenforce=//p' $N 2>/dev/null; }

say "selinux=$(getenforce)"
say "armed=$(sed -n 's/^armed: policyload=\([01]\) setenforce=\([01]\).*/\1\2/p' $N 2>/dev/null)"

# A su shell runs in the KernelSU domain, so its setenforce is a KernelSU-origin change. Toggling
# off then on makes two real transitions whatever the start state, and the page must not move. The
# global enforcing is set before the status-page writer the face skips, so it is restored by the
# second toggle regardless of the face.
seq0=$(sel_seq)
sk0=$(sel_se_skip)
su 0 setenforce 0
su 0 setenforce 1
seq1=$(sel_seq)
sk1=$(sel_se_skip)
say "su_enforce_bumped=$([ "$seq0" != "$seq1" ] && echo yes || echo no)"
say "su_enforce_skipped=$([ "${sk1:-0}" -gt "${sk0:-0}" ] 2>/dev/null && echo yes || echo no)"
say "enforce_now=$(getenforce)"

echo "---- selinux_status node"
cat $N 2>/dev/null
echo "---- selinux_status messages"
dmesg | grep -i selinux_status | tail -n 10
