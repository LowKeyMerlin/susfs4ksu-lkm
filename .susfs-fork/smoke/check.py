#!/usr/bin/env python3
"""Judge the console of one smoke-test boot.

Usage: check.py CONSOLE_LOG --variant KMI [--qemu-rc N] [--ksu-cfg release|debug]

init.sh prints "SMOKE key=value" lines while it runs the module's own scripts in the VM. This
reads them and prints a markdown report. The exit status is the verdict:

  0  pass          the module loaded, answers the SUSFS probe and the guard behaved
  1  fail          the kernel booted and something the module is responsible for went wrong
  2  error         the checker itself could not run, which says nothing about the module
  3  inconclusive  the test could not run: the kernel never reached userspace, the scripts
                   could not be given an Android kernel release, or SUSFS already answered
                   before the module was loaded

An inconclusive boot says nothing about the module, but it is not a pass either, a kernel that
could not be tried is not covered. The workflow retries it once and fails when it stays that
way. Once userspace runs, anything missing or wrong is a failure, including a console that stops
before the final line.
"""
import argparse
import pathlib
import re
import sys
import traceback

PASS, FAIL, ERROR, INCONCLUSIVE = 0, 1, 2, 3
NAMES = {PASS: "PASS", FAIL: "FAIL", INCONCLUSIVE: "INCONCLUSIVE"}

FACT = re.compile(r"^SMOKE (\w+)=(.*)$")
# Other CPUs print while the test writes, so a console line can run into a kernel message that
# started before its newline. The value ends where the timestamp starts.
# What the scripts print can say "Kernel panic" in a sentence of its own, as the installer credits do.
SCRIPT_LINE = re.compile(r"^(SMOKE |LOG |INSTALL[\w-]*: )")
LAYER_FAILED = re.compile(r"\b\w+ init failed -?\d+ - that feature stays off")
KERNEL_TAIL = re.compile(r"\[\s*\d+\.\d{6}\]")
CRASH = re.compile(r"Kernel panic|Oops[:\s]|BUG:|Call trace:|Unable to handle kernel|Internal error:")

# What a healthy run reports: key, expected value, what it shows.
EXPECTED = [
    ("load_rc", "0", "post-fs-data.sh exits 0"),
    ("probe_after", "0", "SUSFS answers the version probe after the load"),
    ("sysfs", "present", "/sys/module/susfs_guard_lkm exists"),
    ("armed", "yes", "the guard armed its marker for the load"),
    ("disabled", "no", "the guard did not disable the module"),
    ("tripped", "no", "the guard did not trip"),
    ("armed_after_settle", "no", "service.sh cleared the marker once the boot settled"),
    ("second_load_rc", "0", "a second load in the same boot exits 0"),
    ("second_load_count", "1", "a second load did not stack another module"),
    ("disabled_after", "no", "the second load did not disable the module"),
    ("app_uid", "10000", "the test can run a command as an app uid"),
    ("map_rule_missing_err", "-2", "a sus_map rule for a path that does not exist is refused with ENOENT"),
    ("map_rule_err", "0", "a sus_map rule for an existing path is accepted"),
    ("maps_root_sees", "yes", "root still sees the mapping of the file with a sus_map rule"),
    ("maps_app_sees", "no", "an app does not see the mapping of the file with a sus_map rule"),
    ("maps_hook_ran", "yes", "the maps hook skipped lines"),
    ("sus_path_add_rc", "0", "a sus_path rule for an existing directory is accepted"),
    ("sus_path_create_root", "EEXIST", "root making the same directory again sees it exists"),
    ("sus_path_create_app", "EACCES",
     "an app making the same directory is refused as an absent name under an unwritable parent would be"),
    ("or_add_rc", "0", "an open_redirect rule is accepted"),
    ("or_read_root", "ORIGINAL", "root reading the target sees the real file"),
    ("or_read_app", "FAKE", "an app reading the target is redirected"),
    ("or_del_rc", "0", "the rule is removed"),
    ("or_read_app_after_del", "ORIGINAL", "an app reads the real file once the rule is gone"),
    ("modules_cleared_lists", "yes", "/proc/modules lists the module once the hide list is cleared"),
    ("kallsyms_cleared_lists", "yes", "/proc/kallsyms lists the module's symbols once the hide list is cleared"),
    ("modules_lists", "no", "/proc/modules does not list a module on the hide list"),
    ("kallsyms_lists", "no", "/proc/kallsyms does not list the symbols of a module on the hide list"),
    ("installer_rc", "0", "the installer of the zip succeeds on a kernel the zip covers"),
    ("installer_credits", "yesyesyes", "the installer credits SUSFS, the LKM port and this fork"),
    ("installer_logo", "yes", "the installer shows the logo with Installer next to it"),
    ("installer_title", "yesyes", "the installer shows its title and says what it supports"),
    ("installer_steps", "5", "the installer shows its five steps"),
    ("installer_results", "ok,ok,ok", "the first three steps of a good install report ok"),
    ("installer_log_result", "ok", "a good install ends its log with result ok"),
    ("installer_log_mode", "600", "the install log can be read by root only"),
    ("installer_log_kernel", "1", "the install log names the kernel release once"),
    ("installer_log_upstream", "yes", "the install log holds what the installer of upstream said"),
    ("installer_log_missing", "none", "the install log has every section a report needs"),
    ("installer_scope", "all", "the installer keeps the default of disabling all modules without a key press"),
    ("installer_kmi", "ok", "the installer installs the .ko of the kernel it runs on"),
    ("installer_hook", "yes", "the installer put the early dispatcher in place"),
    ("installer_arm_rc", "1", "the installer refuses a device that is not arm64"),
    ("installer_arm_reason", "yes", "the refusal of a non arm64 device says why"),
    ("installer_arm_failed", "yes", "the refusal of a non arm64 device ends in the failure line"),
    ("installer_arm_done", "no", "the installer does not report done after a refusal"),
    ("installer_noksu_rc", "1", "the installer refuses a manager that is not KernelSU"),
    ("installer_noksu_reason", "yes", "the refusal of a manager that is not KernelSU says why"),
    ("installer_noksu_done", "no", "the installer does not report done after that refusal"),
    ("installer_arm_results", "failed,ok,failed", "a non arm64 device fails the device check and the install"),
    ("installer_arm_log_result", "failed", "the log of a refused install says that it failed"),
    ("installer_arm_log_reason", "yes", "the log of a refused install says why"),
    ("installer_noksu_results", "failed,ok,failed", "a manager that is not KernelSU fails the device check and the install"),
    ("installer_noksu_log_result", "failed", "the log of that refusal says that it failed"),
    ("installer_log_rotated", "yes", "the log of the install before is kept as .old"),
]


# The number of page-table callbacks one walk makes is a kernel-version detail (seen as 1 on some
# kernels, 4 on others), so these ask only whether the skip fired at all, not how many times.
AT_LEAST_ONE = [
    ("kms_redirects", "statfs of a marked mount was redirected at least once"),
    ("map_walk_skipped", "the pagemap read of a hidden mapping skipped at least one walk"),
    ("map_mem_hides", "the /proc/self/mem read of a hidden mapping was refused at least once"),
]

# A sus_kstat rule on a path that a smaller tmpfs was mounted over.
KSTAT_EXPECTED = [
    ("kstat_add_err", "0", "a sus_kstat rule for an existing path is accepted"),
    ("kstat_mounts_differ", "yes", "the mount over the path changes what statfs answers"),
    ("kstat_before_update_app", "covered", "the rule matches nothing until it is updated for the new mount"),
    ("kstat_update_err", "0", "the rule is updated for the new mount"),
    ("kstat_statfs_app", "real", "an app is answered by statfs with what the path answered before the mount"),
    ("kstat_fstatfs_app", "real", "the same through fstatfs"),
    ("kstat_statfs_app_compat", "real", "the same through the 32-bit statfs64"),
    ("kstat_fstatfs_app_compat", "real", "the same through the 32-bit fstatfs64"),
    ("kstat_statfs_root", "covered", "root is answered with the mount that is there"),
    ("kstat_fstatfs_opath_app", "real", "fstatfs of an O_PATH descriptor is answered like one of a plain descriptor"),
    ("kstat_fstatfs_opath_app_compat", "real", "the same through the 32-bit fstatfs64"),
    ("kstat_fstatfs_opath_root", "covered", "and root still gets the mount that is there"),
    ("kfd_mounts_differ", "yes", "the mount over the path changes what fdinfo prints for a descriptor on it"),
    ("kfd_root", "covered", "root reads the mount id and inode that are there"),
    ("kfd_app", "real", "an app reads the mount id and inode the path had when the rule was added"),
    ("kfd_other_path_app", "yes", "a descriptor on /proc is read the same by an app and by root"),
    ("kfd_other_path_app_sys", "yes", "and one on /sys"),
    ("kin_mounts_differ", "yes", "an inotify watch on the path lists the real device, which differs from the covered one"),
    ("kin_root", "covered", "root reads the real inode and device of the watched path"),
    ("kin_app", "real", "an app is given the inode and device the path had when the rule was added"),
    ("kin_app_compat", "real", "the 32-bit app is given the same"),
    ("kin_other_path_app", "yes", "a watch on a path with no rule is not rewritten"),
    ("kin_bind_app", "real", "a watch on a bind mount of the path is answered as the path is"),
    ("kms_mounts_differ", "yes", "a small tmpfs under /data/adb has other blocks than its parent"),
    ("kms_root", "covered", "root reads the real numbers of a marked mount"),
    ("kms_app", "real", "an app is answered with the numbers of the mount above it, as upstream does"),
    ("kms_fstatfs_app", "real", "fstatfs of a descriptor on a marked mount is answered the same way"),
    ("kms_app_compat", "real", "the 32-bit app is given the same"),
    ("kms_errors_app", "nullpath=-14,badbuf=-14,missing=-2,badfd=-9,",
     "the calls that must fail fail the kernel's way on a marked mount"),
    ("kms_errors_app_compat", "nullpath=-14,badbuf=-14,missing=-2,badfd=-9,badsize=-22,",
     "the same through the 32-bit entries"),
    ("kms_other_path_app", "yes", "a path on no marked mount is not redirected"),
    ("kms_other_path_counted", "yes", "and it is not counted as a redirect"),
    ("kms_ident_root", "covered", "root reads the real numbers of a bind mount of a marked mount"),
    ("kms_ident_app", "real", "an app is answered for it from the mount it sits on: it is recognised by identity"),
    ("kms_race_bad_answers", "0", "no answer outside the two a mount can give while it is unmounted and mounted again"),
    ("kin_cleared_app", "covered", "an app reads the real inode and device again once the rules are cleared"),
    ("kfd_bind_root_differs", "yes", "root reads the real mount id of a bind mount of the path"),
    ("kfd_bind_app", "real", "an app is answered for a bind mount of the path as for the path, as upstream does"),
    ("kfd_other_dev_app", "yes", "a descriptor on another filesystem is not rewritten even if its inode number is the same"),
    ("kfd_race_bad_answers", "0", "readers racing a cleared and re-added rule only ever see one of the two answers"),
    ("kfd_hook_armed", "all", "the fdinfo hook armed on every seq_show symbol it found, and found some"),
    ("kfd_cleared_app", "covered", "with the rule cleared an app reads what is there"),
    ("kstat_errors_root", "nullpath=-14,badbuf=-14,missing=-2,badfd=-9,",
     "the kernel's own errors for a null path, a bad buffer, a missing path and a bad descriptor"),
    ("kstat_errors_app", "nullpath=-14,badbuf=-14,missing=-2,badfd=-9,",
     "an app that the rules apply to is failed in the same way"),
    ("kstat_errors_app_compat", "nullpath=-14,badbuf=-14,missing=-2,badfd=-9,badsize=-22,",
     "the same through the 32-bit calls, and statfs64 of the wrong size is EINVAL"),
    ("kstat_exact_app", "yes",
     "on paths no rule names an app gets, byte for byte, what root gets (statfs and fstatfs, two paths, both ABIs)"),
    ("kstat_other_path_app", "yes", "a path without a rule is answered as before"),
    ("kstat_cleared_app", "covered", "an app is answered with the mount once the rules are cleared"),
]

# The rules the supercall added are managed through /proc/susfs_map. Counts are listed rules, the
# same number as the listing header and map_stat.
MAPPROC_EXPECTED = [
    ("mapproc_listed", "1/1/1", "the listing, its header and map_stat agree on the supercall rule"),
    ("mapproc_add", "yes", "add of an existing path is accepted"),
    ("mapproc_count_after_add", "2", "the added path is a second rule"),
    ("mapproc_add_again", "yes/2", "adding a path twice keeps one rule"),
    ("mapproc_add_missing", "no", "add of a path that does not exist is refused"),
    ("mapproc_bad_verb", "no", "an unknown command is refused"),
    ("mapproc_del", "yes/1", "del removes the rule"),
    ("mapproc_del_again", "no", "del of a path without a rule is refused"),
    ("mapproc_churn_failures", "0", "adding and removing 70 times does not fill the 64 entries"),
    ("mapproc_app_write", "no", "an app cannot change the rules"),
    ("mapproc_app_read", "no", "an app cannot read the rules"),
    ("mapproc_count_after_app", "1", "the app's write changed nothing"),
    ("mapproc_clear", "yes/0", "clear drops every rule"),
    ("mapproc_sees_cleared", "yes", "an app sees the mapping once the rules are cleared"),
    ("mapproc_hide", "yes/no", "a rule added through the node hides the mapping from an app"),
    ("mapproc_unhide", "yes/yes", "deleting the rule shows the mapping again"),
]


# With KernelSU loaded first (kernelsu.ko given to boot.sh). The values are KernelSU's own
# answers, so a module that hides from the wrong uid is caught.
# What the priority calls answer about another user: "ok" or the negated errno, for getpriority,
# setpriority, ioprio_get, ioprio_set and ioprio_set with an invalid class, which fails the same
# way for every uid because the kernel checks the class first. A uid nobody hides gets EPERM on
# the writes and a value on the reads.
PRIO_TRUTH = "ok,-1,ok,-1,-22"
PRIO_HIDDEN = "-3,-3,-3,-3,-22"
PRIO_OWN = "ok,ok,ok,ok,-22"
# ioprio_set with who 0 names uid 0 instead of the caller's own uid, so it is EPERM for an app.
PRIO_WHO0 = "ok,ok,ok,-1,-22"

PRIO_EXPECTED = [
    ("prio_before_app", PRIO_TRUTH, "before the list is set an app sees the uid it asks about"),
    ("prio_before_compat_app", PRIO_TRUTH, "the same through the 32-bit syscall numbers"),
    ("prio_set_hid", "0,0", "root set the list"),
    ("prio_hid_app", PRIO_HIDDEN, "an app is told that a listed uid has no processes"),
    ("prio_hid_compat_app", PRIO_HIDDEN, "the same through the 32-bit syscall numbers"),
    ("prio_visible_app", PRIO_TRUTH, "a uid that is not listed is answered as before"),
    ("prio_visible_compat_app", PRIO_TRUTH, "the same through the 32-bit syscall numbers"),
    ("prio_hid_own", PRIO_OWN, "an app is answered for its own uid whatever the list says"),
    ("prio_hid_own_compat", PRIO_OWN, "the same through the 32-bit syscall numbers"),
    ("prio_who0_app", PRIO_WHO0, "asking about who 0 is answered by the kernel, as it does without the filter"),
    ("prio_hid_root", PRIO_OWN, "root is answered for a listed uid"),
    ("prio_by_pid_app", "ok,ok", "a process asked for by pid is not filtered"),
    ("prio_set_vis", "0,0", "a second list is accepted"),
    ("prio_replaced", f"{PRIO_TRUTH}/{PRIO_HIDDEN}", "the second list replaced the first"),
    ("prio_set_missing", "0,-2", "a name with no directory is refused with ENOENT"),
    ("prio_set_dotdot", "0,-22", "the name .. is refused"),
    ("prio_set_slash", "0,-22", "a name with a slash is refused"),
    ("prio_set_empty", "0,-22", "an empty list is refused"),
    ("prio_set_low_uid", "0,-22", "a uid below the app range is refused"),
    ("prio_set_high_uid", "0,-22", "a uid above the range the filter covers is refused"),
    ("prio_set_unterminated", "0,-22", "a list that fills the buffer without an end is refused"),
    ("prio_set_by_app", "-1,126", "the command is not handled for an app, which stays at the 126 sentinel"),
    ("prio_refused_keeps", f"{PRIO_TRUTH}/{PRIO_HIDDEN}", "a refused list leaves the list as it was"),
    ("prio_set_list", "0,0", "blanks and empty items in a list are skipped"),
    ("prio_list_hides", f"{PRIO_HIDDEN}/{PRIO_HIDDEN}", "both names of the list are hidden"),
    ("prio_list_hides_compat", f"{PRIO_HIDDEN}/{PRIO_HIDDEN}", "the same through the 32-bit syscall numbers"),
    ("prio_race_bad_rows", "0", "a caller sees the old list or the new one while the list is replaced"),
    ("prio_after_race", "0,0", "the list can still be set after being replaced in a loop"),
    ("prio_refresh_stale", f"{PRIO_HIDDEN}/{PRIO_TRUTH}", "nothing changes until the package list is written"),
    ("prio_refresh_not_event", f"{PRIO_HIDDEN}/{PRIO_TRUTH}",
     "a file of that name in another directory and another file of /data/system are not the event"),
    ("prio_refresh_followed", f"{PRIO_TRUTH}/{PRIO_HIDDEN}",
     "writing packages.list makes the filter follow the package to the uid it has now"),
    ("prio_refresh_removed", f"{PRIO_TRUTH}/{PRIO_TRUTH}",
     "a package that is gone is not hidden any more, and a burst of writes is harmless"),
]
KSU_EXPECTED = [
    ("policy_load_rc", "0", "the SELinux policy KernelSU needs was loaded"),
    ("ksu_load_rc", "0", "kernelsu.ko loaded"),
    ("ksu_post_fs_data", "event rc=0 value=0", "the post-fs-data stage was reported to KernelSU"),
    ("ksu_boot_completed", "event rc=0 value=0", "the boot-completed stage was reported to KernelSU"),
    ("ksu_umount_10000", "1", "KernelSU unmounts modules for an app without a profile"),
    ("ksu_sees_10000", "no", "an app without a profile does not see the mapping of a sus_map file"),
]
# A debug build of KernelSU, where the test names the manager and can set profiles.
KSU_DEBUG_EXPECTED = [
    ("ksu_manager_method", ("param", "toolkit"), "the test could name the manager app"),
    ("ksu_nonmanager_profile_refused", "yes", "KernelSU refuses a profile from an app that is not the manager"),
    ("ksu_nonroot_event_refused", "yes", "KernelSU refuses a boot stage report from an app"),
    ("ksu_profile_keep", "profile rc=0 value=0", "the manager set a profile that keeps modules mounted"),
    ("ksu_profile_allow", "profile rc=0 value=0", "the manager granted root to an app"),
    ("ksu_profile_deny", "profile rc=0 value=0", "the manager set a profile that unmounts modules"),
    ("ksu_umount_10001", "0", "KernelSU does not unmount modules for the manager"),
    ("ksu_sees_10001", "yes", "the manager sees the mapping of a sus_map file"),
    ("ksu_umount_10002", "0", "KernelSU does not unmount modules for a profile that keeps them"),
    ("ksu_granted_10002", "0", "an app that only keeps modules has no root"),
    ("ksu_sees_10002", "yes", "an app that keeps modules sees the mapping of a sus_map file"),
    ("ksu_umount_10003", "0", "KernelSU does not unmount modules for an app with root"),
    ("ksu_granted_10003", "1", "KernelSU grants root to the app the manager allowed"),
    ("ksu_sees_10003", "yes", "an app with root sees the mapping of a sus_map file"),
    ("ksu_umount_10004", "1", "KernelSU unmounts modules for a profile that asks for it"),
    ("ksu_granted_10004", "0", "an app that only unmounts modules has no root"),
    ("ksu_sees_10004", "no", "an app whose profile unmounts modules does not see the mapping"),
    ("prio_ksu_mgr", PRIO_TRUTH, "the manager sees a listed uid"),
    ("prio_ksu_root_app", PRIO_TRUTH, "an app with root sees a listed uid"),
    ("prio_ksu_keep", PRIO_HIDDEN, "an app that only keeps modules mounted does not see a listed uid"),
    ("prio_ksu_deny", PRIO_HIDDEN, "an app whose profile unmounts modules does not see a listed uid"),
]


def split_tail(line):
    """Return (line without a kernel message that ran into it, that message)."""
    m = KERNEL_TAIL.search(line)
    return (line[:m.start()], line[m.start():]) if m else (line, "")


def facts_of(lines):
    found = {}
    for line in lines:
        m = FACT.match(split_tail(line)[0])
        if m:
            found[m[1]] = m[2].strip()
    return found


# listmount(2)/statmount(2) exist from 6.12 on the KMIs here. A marked mount is hidden from an app;
# root is the control. lm_app_one_leaks=yes is the documented residual (a page of one that is
# entirely ours cannot be shortened to zero), so it is expected, and counted as full_leak.
LISTMOUNT_EXPECTED = [
    ("lm_listmount_probe", "1", "the __arm64_sys_listmount probe armed"),
    ("lm_id_read", "yes", "the test read the unique id of the marked mount"),
    ("lm_root_sees_big", "yes", "root listing the tree sees the marked mount"),
    ("lm_root_sees_one", "yes", "root listing one id per call sees the marked mount"),
    ("lm_app_sees_big", "no", "an app listing the tree with a roomy buffer does not see the marked mount"),
    ("lm_root_tail_shows", "yes", "root's whole-buffer listing contains the marked id, so the tail check below is not vacuous"),
    ("lm_app_tail_hidden", "0", "no slot past an app's returned count still holds the marked id"),
    ("lm_app_one_leaks", "yes", "a page of one that is only the marked mount goes out (documented residual)"),
    ("lm_app_one_full_counted", "yes", "that residual is counted as full_leak"),
    ("lm_statmount_app", "-2", "an app's statmount of the marked id fails with ENOENT"),
    ("lm_statmount_app_compat", "-2", "the same through the 32-bit table"),
    ("lm_statmount_root_matches", "yes", "root's statmount of the marked id answers that mount"),
    ("lm_statmount_app_other", "0", "an app's statmount of an unmarked mount still works"),
    ("lm_app_parent_rc", "-2", "an app's listmount under the marked mount fails with ENOENT"),
    ("lm_root_parent_count", "0", "root's listmount under the marked mount succeeds (no children)"),
]


def listmount_problems(facts):
    m = re.match(r"(\d+)\.(\d+)", facts["kernel"])
    if not (m and (int(m[1]), int(m[2])) >= (6, 12)):
        got = facts.get("lm_mntroot_probe")
        return [] if got == "absent" else [
            f"a kernel without listmount reports no listmount probes: expected lm_mntroot_probe=absent, got {got}"]
    problems = []
    # grab_requested_root is the primary hook; the statmount wrapper stands in only when it is missing.
    modes = (facts.get("lm_mntroot_probe"), facts.get("lm_statmount_fallback_probe"))
    if modes not in (("1", "0"), ("0", "1")):
        problems.append("exactly one of grab_requested_root and the statmount fallback armed: expected "
                        f"lm_mntroot_probe/lm_statmount_fallback_probe=1/0 or 0/1, got {modes[0]}/{modes[1]}")
    for key, want, shows in LISTMOUNT_EXPECTED:
        got = facts.get(key)
        if got != want:
            problems.append(f"{shows}: expected {key}={want}, got {got if got is not None else 'nothing'}")
    got = facts.get("lm_app_count_big")
    if not (got and got.isdigit() and int(got) > 0):
        problems.append(f"an app listing the tree still gets the real mounts: expected lm_app_count_big>0, got {got}")
    return problems


def judge(lines, qemu_rc, ksu_cfg=None):
    """Return (verdict, problems, facts)."""
    facts = facts_of(lines)
    if "kernel" not in facts:
        return INCONCLUSIVE, ["the kernel did not reach userspace, so the module was not tried"], facts
    if facts.get("osrelease") != "ok":
        return INCONCLUSIVE, ["the scripts could not be given an Android kernel release "
                              f"(osrelease={facts.get('osrelease', 'missing')})"], facts
    if facts.get("probe_before") != "1":
        return INCONCLUSIVE, [f"SUSFS did not read as absent before the load (probe_before="
                              f"{facts.get('probe_before', 'missing')}), so a load proves nothing"], facts

    expected = list(EXPECTED) + PRIO_EXPECTED + KSTAT_EXPECTED + MAPPROC_EXPECTED
    if ksu_cfg:
        expected += KSU_EXPECTED
    if ksu_cfg == "debug":
        expected += KSU_DEBUG_EXPECTED
    problems = []
    for key, want, shows in expected:
        got = facts.get(key)
        allowed = want if isinstance(want, tuple) else (want,)
        if got not in allowed:
            problems.append(f"{shows}: expected {key}={'|'.join(allowed)}, got {got if got is not None else 'nothing'}")
    for key, shows in AT_LEAST_ONE:
        got = facts.get(key)
        if not (got is not None and got.lstrip("-").isdigit() and int(got) > 0):
            problems.append(f"{shows}: expected {key}>0, got {got if got is not None else 'nothing'}")
    problems += listmount_problems(facts)
    seen = crashed = False
    for line in lines:
        seen = seen or line.startswith("SMOKE kernel=")
        # Only the kernel's own console lines count, not what the scripts print about themselves.
        # A kernel message that ran into a line of the test is looked at as well.
        own, tail = split_tail(line) if SCRIPT_LINE.match(line) else ("", line)
        kernel_line = tail if own else line
        if seen and not crashed and CRASH.search(kernel_line):
            problems.append(f"the console shows a crash: {(tail or line).strip()[:160]}")
            crashed = True
        # A layer that cannot start leaves the module loaded and the feature off, which no fact above
        # shows unless it is tested for. android14-5.15 ran that way, with three layers off, until this.
        m = LAYER_FAILED.search(kernel_line)
        if seen and m:
            problems.append(f"a layer of the module did not start: {m.group(0)}")
    if "done" not in facts:
        how = "timed out" if qemu_rc == 124 else f"qemu exited with {qemu_rc}" if qemu_rc is not None else "stopped"
        problems.append(f"the test did not reach its last line, the VM {how}")
    return (FAIL if problems else PASS), problems, facts


def report(variant, verdict, problems, facts, lines):
    out = [f"### {variant}: {NAMES[verdict]}", ""]
    if facts.get("kernel"):
        out.append(f"Kernel `{facts['kernel']}`, scripts saw `{facts.get('osrelease_value', 'the real release')}`.")
        out.append("")
    out += [f"- {p}" for p in problems]
    if verdict == PASS:
        out.append("The module loaded through its own scripts, answers the probe, and the guard cleared its marker.")
    if verdict != PASS:
        tail = "\n".join(line.rstrip()[:200] for line in lines[-60:])
        out += ["", "<details><summary>Last console lines</summary>", "", "```", tail, "```", "", "</details>"]
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("console", type=pathlib.Path)
    ap.add_argument("--variant", required=True)
    ap.add_argument("--qemu-rc", type=int)
    ap.add_argument("--ksu-cfg", choices=["release", "debug"])
    args = ap.parse_args()

    try:
        text = args.console.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        print(f"check.py: cannot read the console: {e}", file=sys.stderr)
        return ERROR
    lines = [line.rstrip("\r") for line in text.split("\n")]
    verdict, problems, facts = judge(lines, args.qemu_rc, args.ksu_cfg)
    sys.stdout.write(report(args.variant, verdict, problems, facts, lines))
    return verdict


if __name__ == "__main__":
    # An unexpected exception must not exit with 1, which is the verdict for a failed test.
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(ERROR)
