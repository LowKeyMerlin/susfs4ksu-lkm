#!/usr/bin/env python3
"""Host-side tests for the findings of the 6020cd5..de14a15 review.  Nothing here boots a kernel.

  python tools/test_review_findings.py [--src DIR]

DIR is a susfs4ksu-lkm checkout (default: the one this file is in).  Run it on an unfixed tree and
the tests named below fail, which is the evidence of each finding; on a tree with
tools/review_fixes.patch applied all of them pass.

  test_listmount_tail_cleared     F1  sus_mount_listmount_ret() leaves hidden ids in the caller's array
                                      past the count it returns.  The function is cut out of
                                      kernel/sus_mount.c as it is, compiled against user-space stand-ins
                                      for the few kernel helpers it uses, and run on every position the
                                      hidden ids can be in, across the 32-id chunk boundary, with and
                                      without a fault in the caller's buffer.
  test_listmount_prefix_correct         the shorter page is still the kept ids, in order (guards the fix)
  test_listmount_untouched_if_none      nothing is written when none of the ids is ours
  test_fstatfs_uses_fget_raw          F2  fstatfs on an O_PATH descriptor: fs/statfs.c's fd_statfs() uses
                                      fdget_raw(); fget() rejects FMODE_PATH files (see the comment in
                                      kernel/susfs_opath.c, which makes the same point)
  test_no_fget_on_user_fd_anywhere      the same mistake nowhere else in kernel/
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)

HARNESS = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
/* LP64 as in the kernel: a host where long is 32 bits (Windows) gets the same widths */
#define long long long

typedef uint64_t u64;
typedef uint32_t u32;
#define __user
#define READ_ONCE(x) (x)
#define min_t(t, a, b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
typedef struct { int v; } atomic_t;
#define ATOMIC_INIT(i) { (i) }
static void atomic_inc(atomic_t *a) { a->v++; }
static void atomic_add(int i, atomic_t *a) { a->v += i; }
struct kretprobe_instance { char data[64]; };
struct pt_regs { unsigned long regs[31]; };
#define regs_return_value(r) ((r)->regs[0])
#define SUS_MOUNT_LM_CHUNK 32

/* user memory is host memory, fault_at counts user accesses and fails exactly that one */
static int accesses, fault_at = -1;
static int fault(void) { return accesses++ == fault_at; }
static unsigned long copy_from_user(void *to, const void __user *from, unsigned long n)
{ if (fault()) return n; memcpy(to, from, n); return 0; }
static unsigned long copy_to_user(void __user *to, const void *from, unsigned long n)
{ if (fault()) return n; memcpy(to, from, n); return 0; }
static unsigned long clear_user(void __user *to, unsigned long n)
{ if (fault()) return n; memset(to, 0, n); return 0; }

#define BASE 1000
static bool hidden[256];
static bool sus_mount_uniq_has(u64 id) { return id >= BASE && id < BASE + 256 && hidden[id - BASE]; }
static bool sus_mount_req_id(unsigned long req, u64 *id) { (void)req; (void)id; return false; }
static bool kr_mntroot_ok = true;

struct sus_mount_sc_state { unsigned long req, ubuf, len; };
static atomic_t n_listmount_ret = ATOMIC_INIT(0), n_listmount_dropped = ATOMIC_INIT(0),
		n_listmount_full = ATOMIC_INIT(0), n_listmount_parent = ATOMIC_INIT(0),
		n_listmount_tailfail = ATOMIC_INIT(0);

#include "listmount_ret.inc"

#define SENT 0xdeadbeefULL
static unsigned rng = 12345;
static unsigned rnd(void) { rng = rng * 1103515245u + 12345u; return (rng >> 8) & 0xffff; }

static long tail_leaks, prefix_errors, writes_when_none, scenarios, fault_leaks;

/* one scenario: ret ids built by the kernel in a buffer of len slots, hidden[] marks ours */
static void run(int ret, int len, int fault_k)
{
	u64 buf[300] = {0}, orig[300], kept[300];
	int i, nk = 0, nh = 0, mid_full;
	struct kretprobe_instance ri;
	struct sus_mount_sc_state *st = (struct sus_mount_sc_state *)ri.data;
	struct pt_regs regs;
	long got;

	for (i = 0; i < len; i++)
		buf[i] = i < ret ? BASE + i : SENT;
	memcpy(orig, buf, sizeof(buf));
	for (i = 0; i < ret; i++) {
		if (hidden[i]) nh++; else kept[nk++] = orig[i];
	}
	st->req = 0; st->ubuf = (unsigned long)buf; st->len = (unsigned long)len;
	memset(&regs, 0, sizeof(regs));
	regs.regs[0] = (unsigned long)ret;
	accesses = 0; fault_at = fault_k;
	sus_mount_listmount_ret(&ri, &regs);
	fault_at = -1;
	got = (long)regs.regs[0];
	scenarios++;

	mid_full = (nh == ret && ret == len);	/* the documented page-entirely-ours case: unchanged */
	if (!nh) {
		if (memcmp(buf, orig, sizeof(buf))) writes_when_none++;
		return;
	}
	if (got == ret) {			/* the original answer stands (fault, or full page) */
		if (!mid_full && fault_k < 0) prefix_errors++;
		return;
	}
	/* a shorter page: its prefix must be the kept ids, in order */
	if (got != nk && fault_k < 0) prefix_errors++;
	for (i = 0; i < got; i++)
		if (buf[i] != kept[i]) { prefix_errors++; break; }
	/* and no hidden id may be anywhere in the array, not past the count either */
	for (i = 0; i < len; i++) {
		if (buf[i] >= BASE && buf[i] < BASE + 256 && hidden[buf[i] - BASE]) {
			if (fault_k < 0) tail_leaks++; else if (i < got) fault_leaks++;
			break;
		}
	}
}

int main(void)
{
	int ret, k, i, extra, f;

	for (ret = 1; ret <= 70; ret++) {
		for (extra = 0; extra <= 3; extra += 3) {
			/* each single position */
			for (k = 0; k < ret; k++) {
				memset(hidden, 0, sizeof(hidden)); hidden[k] = true;
				run(ret, ret + extra, -1);
			}
			/* the last d positions: the newest mounts hidden */
			for (k = 1; k <= ret; k++) {
				memset(hidden, 0, sizeof(hidden));
				for (i = ret - k; i < ret; i++) hidden[i] = true;
				run(ret, ret + extra, -1);
			}
			/* random subsets, with and without a fault at every access */
			for (k = 0; k < 40; k++) {
				memset(hidden, 0, sizeof(hidden));
				for (i = 0; i < ret; i++) hidden[i] = (rnd() % 5) == 0;
				run(ret, ret + extra, -1);
				for (f = 0; f < 8; f++) run(ret, ret + extra, f);
			}
			/* nothing hidden */
			memset(hidden, 0, sizeof(hidden));
			run(ret, ret + extra, -1);
		}
	}
	printf("scenarios=%lld tail_leaks=%lld prefix_errors=%lld writes_when_none=%lld fault_leaks=%lld\n",
	       scenarios, tail_leaks, prefix_errors, writes_when_none, fault_leaks);
	return 0;
}
"""


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def read(rel):
    with open(os.path.join(SRC, rel), encoding="utf-8") as f:
        return f.read()


def extract_listmount_ret():
    text = read("kernel/sus_mount.c")
    m = re.search(r"static int sus_mount_listmount_ret\(.*?\n\}\n", text, flags=re.S)
    if not m:
        raise AssertionError(
            "sus_mount_listmount_ret() not found in kernel/sus_mount.c"
        )
    return m.group(0)


class ListmountCompaction(unittest.TestCase):
    result = None

    @classmethod
    def setUpClass(cls):
        gcc = shutil.which("gcc") or shutil.which("cc")
        if not gcc:
            raise unittest.SkipTest("no C compiler on PATH")
        tmp = tempfile.mkdtemp(prefix="susfs_lm_")
        cls.addClassCleanup(shutil.rmtree, tmp, True)
        with open(os.path.join(tmp, "listmount_ret.inc"), "w", encoding="utf-8") as f:
            f.write(extract_listmount_ret())
        with open(os.path.join(tmp, "h.c"), "w", encoding="utf-8") as f:
            f.write(HARNESS)
        exe = os.path.join(tmp, "h.exe")
        subprocess.run(
            [
                gcc,
                "-O1",
                "-Wall",
                "-Wno-unused-function",
                "-Wno-unused-variable",
                "-I",
                tmp,
                "-o",
                exe,
                os.path.join(tmp, "h.c"),
            ],
            check=True,
        )
        out = subprocess.run([exe], check=True, capture_output=True, text=True).stdout
        cls.result = dict(re.findall(r"(\w+)=(\d+)", out))
        cls.raw = out.strip()

    def num(self, key):
        return int(self.result[key])

    def test_listmount_tail_cleared(self):
        self.assertGreater(self.num("scenarios"), 10000)
        self.assertEqual(
            self.num("tail_leaks"),
            0,
            "hidden ids left in the caller's array past the returned count: "
            + self.raw,
        )
        self.assertEqual(self.num("fault_leaks"), 0, self.raw)

    def test_listmount_prefix_correct(self):
        self.assertEqual(self.num("prefix_errors"), 0, self.raw)

    def test_listmount_untouched_if_none(self):
        self.assertEqual(self.num("writes_when_none"), 0, self.raw)


class FstatfsRawFd(unittest.TestCase):
    def test_fstatfs_uses_fget_raw(self):
        text = strip_comments(read("kernel/susfs_kstat.c"))
        body = re.search(r"susfs_kstatfs_answer\(.*?\n\}\n", text, flags=re.S)
        self.assertIsNotNone(body, "susfs_kstatfs_answer() not found")
        self.assertIn(
            "fget_raw(",
            body.group(0),
            "fstatfs by fd must accept O_PATH like fdget_raw()",
        )
        self.assertNotRegex(body.group(0), r"\bfget\(")

    def test_no_fget_on_user_fd_anywhere(self):
        bad = []
        kdir = os.path.join(SRC, "kernel")
        for name in sorted(os.listdir(kdir)):
            if name.endswith(".c"):
                for n, line in enumerate(
                    strip_comments(read(f"kernel/{name}")).splitlines(), 1
                ):
                    if re.search(r"(?<![\w.])fget\(", line):
                        bad.append(f"{name}:{n}: {line.strip()}")
        self.assertEqual(
            bad,
            [],
            "fget() rejects O_PATH descriptors; the syscalls these stand in for "
            "use fdget_raw() or fdget(): check each",
        )


class FdinfoArm(unittest.TestCase):
    def test_fdinfo_arm_is_attempted_once(self):
        """When no seq_show can be probed, every later rule add used to repeat the kallsyms scan and
        the warnings; the attempt is made once."""
        text = strip_comments(read("kernel/susfs_kstat.c"))
        body = re.search(
            r"static void kstat_fdinfo_arm\(void\)\n\{.*?\n\}\n", text, flags=re.S
        )
        self.assertIsNotNone(body)
        self.assertRegex(
            body.group(0),
            r"if \(kstat_maps_exiting \|\| n_kstat_fdinfo \|\| kstat_fdinfo_tried\)",
        )
        self.assertRegex(body.group(0), r"kstat_fdinfo_tried = true;")


class BuildHygiene(unittest.TestCase):
    def test_log_macro_users_include_susfs_log_h(self):
        """de14a15 used SUSFS_LOGI in susfs_selinux_hide.c without the header: every DDK build failed
        with -Wimplicit-function-declaration (CI run 41182120881).  A unit that uses a SUSFS_LOG*
        macro includes susfs_log.h itself, as every other unit does, instead of relying on the
        include order of another header."""
        missing = []
        kdir = os.path.join(SRC, "kernel")
        for name in sorted(os.listdir(kdir)):
            if not name.endswith(".c"):
                continue
            text = read(f"kernel/{name}")
            if re.search(r"\bSUSFS_LOG[A-Z]\(", strip_comments(text)) and not re.search(
                r'#\s*include\s+"susfs_log\.h"', text
            ):
                missing.append(name)
        self.assertEqual(missing, [])

    def test_layer_enum_table_and_plan_agree(self):
        """susfs_main.c keeps three parallel lists: enum susfs_layer_id, susfs_layers[] and
        susfs_load_plan[].  Adding a layer to the table alone broke the BUILD_BUG_ON on all eight
        kernels (CI run 41219355188, selinux_ctx; 04f78a9 did the same with selinux_hide).  The same
        names must appear in the same order in all three."""
        text = strip_comments(read("kernel/susfs_main.c"))

        enum = re.search(r"enum susfs_layer_id \{(.*?)\};", text, flags=re.S).group(1)
        ids = re.findall(r"SUSFS_L_(\w+)", enum)
        self.assertEqual(ids[-1], "COUNT")
        ids = ids[:-1]

        table = re.search(r"susfs_layers\[\] = \{(.*?)\n\};", text, flags=re.S).group(1)
        names = re.findall(r'\{\s*"(\w+)"\s*,', table)

        plan = re.search(r"susfs_load_plan\[\] = \{(.*?)\n\};", text, flags=re.S).group(
            1
        )
        planned = re.findall(r"\{\s*SUSFS_L_(\w+)\s*,", plan)

        self.assertEqual([i.lower() for i in ids], names)
        self.assertEqual(ids, planned)

    def test_selinux_ctx_hooks_the_upstream_dispatchers_not_the_callbacks(self):
        """A KernelSU fork's selinux_hide replaces sel_write_access/sel_write_context in the
        selinuxfs write dispatch and selinux_setprocattr in the LSM static-call slot, but only for
        app uids - so a kprobe on any of those three (or on security_compute_av_user, which it never
        calls for an app) registers and never fires for the caller that matters.  Measured on a 6.12
        device, selinux_transaction_write and security_setprocattr, the kernel's own upstream entry
        points, fire for every caller.  This feature must key off those two and never regress to the
        bypassed callbacks, or it silently stops hiding anything from apps again."""
        text = strip_comments(read("kernel/susfs_selinux_ctx.c"))

        self.assertRegex(text, r'\.symbol_name\s*=\s*"selinux_transaction_write"')
        self.assertRegex(text, r'\.symbol_name\s*=\s*"security_setprocattr"')

        for bypassed in (
            "sel_write_access",
            "sel_write_context",
            "selinux_setprocattr",
            "security_compute_av_user",
        ):
            self.assertNotRegex(
                text,
                r'\.symbol_name\s*=\s*"%s"' % bypassed,
                "selinux_ctx must not hook %s: a fork's selinux_hide bypasses it for apps"
                % bypassed,
            )

    def test_adbd_service_property_is_corrected_by_the_event_driven_watcher(self):
        """Xiaomi's /system_ext/bin/adb_root runs adbd as root under its own service, leaving
        init.svc.adbd reading stopped while adbd is live and still holds /dev/socket/adbd and the
        @jdwp-control listener.  Duck Detector reads that disagreement as an ADB runtime
        contradiction.  init owns init.svc.adbd and rewrites it on every adbd transition, so the
        correction has to follow each change, not run once at boot: service.sh starts susfs_propwait
        to block on the property and re-run adbd_guard.sh when it changes.  The guard still conditions
        on adbd actually being up (pidof adbd), so it only ever reports reality, never fakes a state
        adbd is not in.  A sync that drops the guard's pidof check would fake adbd-running where adb
        is off; one that drops the watcher lets the contradiction return on the next toggle."""
        guard = read(".susfs-fork/module/adbd_guard.sh")
        self.assertIn("pidof adbd", guard)
        self.assertRegex(guard, r"\bresetprop\b")
        self.assertRegex(guard, r"init\.svc\.adbd running")

        # service.sh launches the watcher on init.svc.adbd, pointed at the guard, backgrounded.
        service = read(".susfs-fork/module/service.sh")
        self.assertIn("bin/susfs_propwait", service)
        self.assertRegex(service, r'init\.svc\.adbd\s+"\$MODDIR/adbd_guard\.sh"')
        # The watcher never exits, so it must not run in a subshell wrapper and must detach every
        # inherited fd: a held stdout keeps service.sh's output open and stalls whoever reads it
        # (ksud at boot, adbd under the android test).  Background the binary directly, fds pinned.
        self.assertNotRegex(service, r'\(\s*"\$WATCH"')
        self.assertRegex(service, r'"\$WATCH"[^\n]*</dev/null[^\n]*>>[^\n]*adbd_watch\.log[^\n]*2>&1\s*&')

        # The old one-shot is gone from boot-completed.sh: it could not hold across a toggle.
        self.assertNotRegex(read(".susfs-fork/module/boot-completed.sh"), r"\bresetprop\b")

    def test_adbd_watcher_blocks_on_the_property_serial_not_a_poll(self):
        """The watcher must be event driven: it blocks in a shared futex (FUTEX_WAIT, no PRIVATE
        flag, so init's cross-process wake reaches it) on the prop_info serial bionic bumps, and
        runs the guard only on a change - so it costs nothing while idle and never polls.  It locates
        the property through the shared prop_area trie reader and execs a shell guard on each wake."""
        daemon = strip_comments(read("tools/susfs_propwait.c"))

        self.assertIn('"prop_area_parse.h"', daemon)
        self.assertRegex(daemon, r"#define\s+FUTEX_WAIT\s+0\b")
        self.assertIn("pa_find_prop_offset", daemon)
        # The steady-state loop waits on the serial, then runs the guard. No sleep-based polling.
        self.assertIn("futex_wait(serial, last)", daemon)
        self.assertRegex(daemon, r"run_guard\(")
        self.assertIn("SYS_execve", daemon)

    def test_selinux_ctx_hooks_disarm_when_the_list_empties(self):
        """Both hooks must come down whenever the list goes to empty or the module exits - both
        reach ctx_probes_unregister_locked().  The query node is a kretprobe when its drop helper
        resolved and a kprobe otherwise, so the disarm has to cover whichever is live plus the
        setprocattr kprobe.  A refactor that drops any of them leaves a probe armed after the
        admin's list is cleared."""
        text = strip_comments(read("kernel/susfs_selinux_ctx.c"))

        body = re.search(
            r"static void ctx_probes_unregister_locked\(void\)\n\{(.*?)\n\}\n",
            text,
            flags=re.S,
        )
        self.assertIsNotNone(body)
        # Whichever txn variant is live is unregistered, and the setprocattr kprobe always is.
        self.assertRegex(body.group(1), r"unregister_kretprobe\(&krp_ctx_txn\)")
        self.assertRegex(body.group(1), r"unregister_kprobe\(&kp_ctx_txn\)")
        self.assertRegex(body.group(1), r"unregister_kprobe\(&kp_ctx_attr\)")


class ModuleUx(unittest.TestCase):
    """Static checks on the module scripts and WebUI for the compat/UX work.  Nothing boots a
    kernel or a device; each test pins a behavior a later edit could silently drop."""

    def test_selinux_ctx_seeds_adbroot_by_default(self):
        """adbroot is the adb-root domain stock ROMs add and detectors probe for, so the hide list
        ships with it on.  seed() writes only when the list file is absent, so a user who removes
        adbroot keeps it removed across later runs."""
        text = read(".susfs-fork/module/selinux_ctx.sh")
        seed = re.search(r"seed\(\)\s*\{(.*?)\n\}", text, flags=re.S)
        self.assertIsNotNone(seed)
        body = seed.group(1)
        self.assertRegex(body, r'\[ -f "\$LIST" \]\s*&&\s*return 0')
        # adbroot is a printf argument (single-quoted), not one of the comment lines above it
        self.assertIn("'adbroot'", body)

    def test_early_load_defaults_on_with_opt_out_marker(self):
        """A config manager that sends its SUSFS settings in post-fs-data needs this module already
        up, so early load is on out of the box.  A user who turns it off leaves an early_off marker
        a module update preserves, so the next update does not reset the choice to on.
        """
        cust = read("module/customize.sh")
        self.assertRegex(cust, r'\[ -f "\$INSTALLED/early_off" \]')
        self.assertRegex(cust, r'touch "\$MODPATH/early_off"')
        self.assertRegex(cust, r'touch "\$MODPATH/early_load"')
        early = read(".susfs-fork/module/early.sh")
        # on clears the opt-out and arms, off records the opt-out and disarms
        self.assertRegex(early, r'rm -f "\$MODDIR/early_off"')
        self.assertRegex(early, r': >"\$MODDIR/early_load"')
        self.assertRegex(early, r': >"\$MODDIR/early_off"')

    def test_status_reports_toggle_owner_and_external_source(self):
        """The Controls tab must tell a toggle this module set from one another tool set.  status.sh
        names the owning module from what its boot scripts ship (no name hardcoded) and marks a
        toggle live in the kernel but owned by neither this module nor a found module as external.
        """
        text = read(".susfs-fork/module/status.sh")
        self.assertRegex(text, r'echo "owner_\$_k=\$_owner"')
        self.assertRegex(text, r'echo "external_\$_k=1"')
        self.assertRegex(text, r"toggle_ours\(\)")
        # external only when no owner was found and the setting is not one of ours
        self.assertRegex(text, r'-z "\$_owner" \] && toggle_on "\$_k" && ! toggle_ours')

    def test_card_description_is_decorated_once_and_digit_gated(self):
        """One function adds the per-segment glyphs and guard_describe writes through it, so the card
        the manager shows and the WebUI parses stay in step.  The version glyph keys off a digit
        after SUSFS so a status reason that opens with the word is not mistaken for a version.
        """
        text = read(".susfs-fork/module/guard.sh")
        self.assertRegex(text, r"guard_decorate\(\)")
        self.assertRegex(text, r"description=\$\(guard_decorate ")
        # the digit gate: only a version-shaped word after SUSFS earns the version emoji
        self.assertRegex(text, r"v\[0-9\]\*\) +_d_seg=")
        self.assertRegex(text, r"\[0-9\]\*\) +_d_seg=")
        # the separator is quoted inside ${..%%..}: bare, Android's /system/bin/sh reads the | as
        # pattern alternation and cuts the card at every space
        self.assertNotRegex(text, r"\$\{[A-Za-z_0-9]+(%%?|##?)[^}\"']*\|")
        self.assertRegex(text, r'_d_sep=\' \| \'')
        # the robot emoji was rejected as the kernel/KMI glyph
        self.assertNotIn("\U0001f916", text)

    def test_card_emoji_need_no_variation_selector(self):
        """The module card is drawn by whatever manager is installed, in the device's fonts.  The
        emoji it uses are single code points with default emoji presentation, so the emoji font
        every Android ships draws them as they are.  An emoji that needs U+FE0F to leave text style
        (a gear, a shield, a warning sign) or a joiner is dropped by a font or manager that does not
        know it, which is how the card once lost fields and showed bare separators."""
        for path in (".susfs-fork/module/guard.sh", "module/load.sh"):
            text = read(path)
            self.assertNotIn("\ufe0f", text, f"{path} holds a variation selector")
            self.assertNotIn("\u200d", text, f"{path} holds a zero-width joiner")
            for ch in "\u26a0\u2699\U0001f6e1":
                self.assertNotIn(ch, text, f"{path} writes U+{ord(ch):04X}, which needs U+FE0F")

    def test_capture_script_is_read_only_and_packaged(self):
        """The one-button log capture writes a single report and nothing else, reachable under
        /sdcard/Download to share, and prints its path for the WebUI.  It is in the packed set so a
        build ships and lints it."""
        text = read(".susfs-fork/module/capture.sh")
        self.assertIn("/sdcard/Download", text)
        self.assertRegex(text, r'echo "path=\$OUT"')
        # it reads the device state. It must not write to the live kernel nodes it dumps
        self.assertNotRegex(text, r">\s*/proc/")
        self.assertNotRegex(text, r">\s*/sys/")
        self.assertRegex(read(".susfs-fork/pack_extra.py"), r'"capture\.sh"')

    def test_webui_shows_primary_author_only_not_the_fork_credit(self):
        """The masthead names the author from module.prop's author field, first entry only, so the
        fork-origin credit after the comma stays in module.prop and never renders in the WebUI.  No
        author name is hardcoded in the page."""
        text = read("module/webroot/index.html")
        self.assertIn('id="by"', text)
        self.assertRegex(text, r'String\(f\.author \|\| ""\)\.split\(","\)\[0\]')
        self.assertNotIn("inforcqb", text)

    def test_webui_tints_header_by_state_and_exposes_actions(self):
        """The top bar carries a state-tinted background so Active reads apart from a fault at a
        glance, and the status footer exposes Refresh and Capture as production actions.
        """
        text = read("module/webroot/index.html")
        self.assertRegex(text, r"var HEAD_BG = \{")
        self.assertRegex(text, r'setProperty\("--head-bg"')
        self.assertIn('id="refresh"', text)
        self.assertIn('id="capture"', text)

    def test_webui_buttons_show_a_busy_state_while_running(self):
        """Run check and the refresh/capture buttons mark themselves busy while their script runs,
        so a press is visibly acknowledged instead of looking inert."""
        text = read("module/webroot/index.html")
        self.assertRegex(text, r'classList\.add\("busy"\)')
        self.assertRegex(text, r'classList\.remove\("busy"\)')


CTX_HARNESS = r"""
#include <stdio.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>

/* Stand-in for the kernel list check: the test hides exactly "adbroot", the one privileged type a
 * device's live policy actually carries (Xiaomi adb_root).  The extracted tokenizer decides WHICH
 * bytes reach this, which is what we are testing. */
static bool ctx_type_hidden(const char *type, size_t type_len)
{
    static const char hidden[] = "adbroot";
    return type_len == strlen(hidden) && !memcmp(type, hidden, type_len);
}

#include "ctx_fns.inc"

static int fails;
static void check(const char *label, int got, int want)
{
    if (got != want) { fails++; printf("FAIL %s got=%d want=%d\n", label, got, want); }
}

int main(void)
{
    const char *edge, *sc, *clean, *nonctx;
    char buf[32];

    /* a bare context whose type is hidden: the /sys/fs/selinux/context and attr/current oracle */
    check("bare_hidden", ctx_buf_has_hidden_type("u:r:adbroot:s0", 14), 1);
    /* the adbd -> adbroot access-query edge: adbroot is the tcontext, second token */
    edge = "u:r:adbd:s0 u:r:adbroot:s0 binder call";
    check("access_tcontext", ctx_buf_has_hidden_type(edge, strlen(edge)), 1);
    /* adbroot as the scontext, first token */
    sc = "u:r:adbroot:s0 u:r:foo:s0 binder call";
    check("access_scontext", ctx_buf_has_hidden_type(sc, strlen(sc)), 1);
    /* an access query naming no hidden type stays visible */
    clean = "u:r:adbd:s0 u:r:system_server:s0 binder call";
    check("access_clean", ctx_buf_has_hidden_type(clean, strlen(clean)), 0);
    /* the trailing class number and permission name have no 3rd colon field, so they are skipped */
    nonctx = "1 2 binder call";
    check("non_context_tokens", ctx_buf_has_hidden_type(nonctx, strlen(nonctx)), 0);
    /* a privileged type NOT in the list (absent in this policy) is not touched */
    check("absent_type", ctx_buf_has_hidden_type("u:r:magisk:s0", 13), 0);
    /* the buffer is sized by the caller's write, not NUL-terminated: bytes past len must not leak */
    memcpy(buf, "u:r:adbroot:s0GARBAGE", 21);
    check("len_bound", ctx_buf_has_hidden_type(buf, 14), 1);
    /* a len that cuts the type short must not match the full hidden name */
    check("len_short", ctx_buf_has_hidden_type(buf, 8), 0);

    printf("fails=%d\n", fails);
    return 0;
}
"""


def extract_ctx_fns():
    text = read("kernel/susfs_selinux_ctx.c")
    out = []
    for name in ("ctx_extract_type", "ctx_buf_has_hidden_type"):
        m = re.search(r"static bool %s\(.*?\n\}\n" % name, text, flags=re.S)
        if not m:
            raise AssertionError(name + "() not found in kernel/susfs_selinux_ctx.c")
        out.append(m.group(0))
    return "\n".join(out)


class SusPathInodeReuse(unittest.TestCase):
    """sus_path's identity-fallback match (same dev+ino, a different inode object than the one the
    rule pinned) confirms i_generation, so an inode number reclaimed by a new file in the same
    superblock stops matching the rule.  Every site that records an entry's ino must record its
    generation too, or the fallback would compare a zero/stale generation and lose the guard."""

    def test_entry_carries_a_generation_field(self):
        text = strip_comments(read("kernel/sus_path.c"))
        self.assertRegex(text, r"struct sus_path_entry \{[^}]*\bu64 generation;")

    def test_identity_fallback_confirms_generation(self):
        text = strip_comments(read("kernel/sus_path.c"))
        body = re.search(
            r"static bool sus_path_inode_hidden\(struct inode \*inode\)\n\{.*?\n\}\n",
            text,
            flags=re.S,
        )
        self.assertIsNotNone(body)
        self.assertRegex(body.group(0), r"e->generation && inode->i_generation")
        self.assertRegex(body.group(0), r"e->generation != \(u64\)inode->i_generation")

    def test_every_ino_capture_also_captures_generation(self):
        lines = strip_comments(read("kernel/sus_path.c")).splitlines()
        missing = []
        for i, line in enumerate(lines):
            m = re.search(r"(\w+)->ino = \(u64\)inode->i_ino;", line)
            if m:
                want = "%s->generation = (u64)inode->i_generation;" % m.group(1)
                nxt = lines[i + 1] if i + 1 < len(lines) else ""
                if want not in nxt:
                    missing.append("%d: %s" % (i + 1, line.strip()))
        self.assertEqual(missing, [], "ino captured without generation: " + "; ".join(missing))

    def test_entry_copy_also_copies_generation(self):
        lines = strip_comments(read("kernel/sus_path.c")).splitlines()
        missing = []
        for i, line in enumerate(lines):
            m = re.search(r"(\w+)->ino = (\w+)->ino;", line)
            if m:
                want = "%s->generation = %s->generation;" % (m.group(1), m.group(2))
                nxt = lines[i + 1] if i + 1 < len(lines) else ""
                if want not in nxt:
                    missing.append("%d: %s" % (i + 1, line.strip()))
        self.assertEqual(missing, [], "entry ino copied without generation: " + "; ".join(missing))


class SelinuxCtxTokenizer(unittest.TestCase):
    """The selinux_ctx layer answers an app's context-validity oracle (writes to selinuxfs
    context/access and attr/current) with -EINVAL for a hidden type, so a real type like adbroot
    reads as absent (report: adbroot write_errno flips 13->22; the adbd->adbroot access edge flips
    to INVALID).  ctx_buf_has_hidden_type is what decides a write carries a hidden type; it is cut
    from the kernel source and run on the exact shapes the detector sends."""

    result = None

    @classmethod
    def setUpClass(cls):
        gcc = shutil.which("gcc") or shutil.which("cc")
        if not gcc:
            raise unittest.SkipTest("no C compiler on PATH")
        tmp = tempfile.mkdtemp(prefix="susfs_ctx_")
        cls.addClassCleanup(shutil.rmtree, tmp, True)
        with open(os.path.join(tmp, "ctx_fns.inc"), "w", encoding="utf-8") as f:
            f.write(extract_ctx_fns())
        with open(os.path.join(tmp, "h.c"), "w", encoding="utf-8") as f:
            f.write(CTX_HARNESS)
        exe = os.path.join(tmp, "h.exe")
        subprocess.run(
            [
                gcc,
                "-O1",
                "-Wall",
                "-Wno-unused-function",
                "-I",
                tmp,
                "-o",
                exe,
                os.path.join(tmp, "h.c"),
            ],
            check=True,
        )
        out = subprocess.run([exe], check=True, capture_output=True, text=True).stdout
        cls.result = dict(re.findall(r"(\w+)=(-?\d+)", out))
        cls.raw = out.strip()

    def test_hidden_type_caught_in_every_query_shape(self):
        self.assertEqual(self.result.get("fails"), "0", self.raw)


class SelinuxCtxTimingDefuse(unittest.TestCase):
    """The query node runs the real selinuxfs write_op before redacting, so a hidden type is
    rejected with the same cost a genuinely-absent type shows, closing the pre-reject timing tell.
    That is only safe if the return handler (a) drops the answer the body staged for a follow-up
    read, or the -EINVAL would be belied by a readable canonical context, and (b) only drops it when
    the body succeeded, so the drop cannot fault on an unset private_data.  setprocattr must stay a
    pre-reject (its body commits the transition), and the whole thing must fall back to the
    pre-reject kprobe when the drop helper cannot be resolved, or an unresolvable KMI would leak."""

    def kret(self):
        text = strip_comments(read("kernel/susfs_selinux_ctx.c"))
        body = re.search(r"static int (?:__nocfi )?ctx_txn_ret\([^)]*\)\n\{.*?\n\}\n", text, flags=re.S)
        self.assertIsNotNone(body, "ctx_txn_ret not found")
        return text, body.group(0)

    def test_query_node_is_a_kretprobe_on_the_dispatcher(self):
        text, _ = self.kret()
        krp = re.search(r"static struct kretprobe krp_ctx_txn = \{.*?\};", text, flags=re.S)
        self.assertIsNotNone(krp, "krp_ctx_txn not found")
        self.assertRegex(krp.group(0), r'\.kp\.symbol_name = "selinux_transaction_write"')
        self.assertRegex(krp.group(0), r"\.entry_handler = ctx_txn_entry")
        self.assertRegex(krp.group(0), r"\.handler = ctx_txn_ret")

    def test_return_handler_drops_staged_answer_only_on_success(self):
        _, ret = self.kret()
        # The drop is guarded on the body having succeeded (rv > 0) AND the helper being resolved,
        # so it can never run on an unset private_data nor when nothing was staged.
        self.assertRegex(ret, r"if \(rv > 0 && ctx_txn_set\)\s*\n\s*ctx_txn_set\(st->file, 0\);")

    def test_return_handler_normalises_errno_to_einval(self):
        _, ret = self.kret()
        self.assertRegex(ret, r"regs_set_return_value\(regs, \(unsigned long\)\(long\)-EINVAL\);")

    def test_return_handler_is_nocfi(self):
        # The drop is an indirect call through a kallsyms-resolved pointer. A CFI-checked indirect
        # call to a resolver-found address panics at run time, so the enclosing function must be
        # __nocfi (the build's cfi_sites gate fails the module otherwise).
        text = strip_comments(read("kernel/susfs_selinux_ctx.c"))
        self.assertRegex(text, r"static int __nocfi ctx_txn_ret\(")

    def test_drop_helper_is_resolved_not_linked(self):
        text = strip_comments(read("kernel/susfs_selinux_ctx.c"))
        self.assertRegex(
            text,
            r'(?s)ctx_txn_set =.*?find_kernel_symbol_exact\("simple_transaction_set"\)',
        )
        self.assertNotRegex(
            text,
            r"EXPORT_SYMBOL|extern void simple_transaction_set",
        )

    def test_fallback_to_pre_reject_when_helper_unresolved(self):
        text = strip_comments(read("kernel/susfs_selinux_ctx.c"))
        reg = re.search(r"static int ctx_probes_register\(void\)\n\{.*?\n\}\n", text, flags=re.S)
        self.assertIsNotNone(reg)
        # kretprobe only when the drop helper resolved, otherwise the leak-safe pre-reject kprobe.
        self.assertRegex(reg.group(0), r"if \(ctx_txn_set\) \{\s*\n\s*rc = register_kretprobe\(&krp_ctx_txn\);")
        self.assertRegex(reg.group(0), r"\} else \{\s*\n\s*rc = register_kprobe\(&kp_ctx_txn\);")

    def test_setprocattr_stays_a_pre_reject(self):
        text = strip_comments(read("kernel/susfs_selinux_ctx.c"))
        attr = re.search(r"static struct kprobe kp_ctx_attr = \{.*?\};", text, flags=re.S)
        self.assertIsNotNone(attr)
        self.assertRegex(attr.group(0), r"\.pre_handler = ctx_attr_pre")
        # There must be no kretprobe on setprocattr: letting its body run commits the transition.
        self.assertNotRegex(text, r'\.kp\.symbol_name = "security_setprocattr"')

    def test_entry_gate_discards_instance_for_callers_it_leaves_alone(self):
        text = strip_comments(read("kernel/susfs_selinux_ctx.c"))
        entry = re.search(r"static int ctx_txn_entry\([^)]*\)\n\{.*?\n\}\n", text, flags=re.S)
        self.assertIsNotNone(entry)
        # Gate misses return non-zero (instance discarded, return trap skipped). Only a hit returns 0.
        self.assertRegex(entry.group(0), r"if \(ctx_hide_empty\(\) \|\| !ubuf \|\| !size\)\s*\n\s*return 1;")
        self.assertRegex(entry.group(0), r"if \(!susfs_is_current_proc_umounted_app\(\)\)\s*\n\s*return 1;")
        self.assertRegex(entry.group(0), r"if \(!ctx_buf_has_hidden_type\(kbuf, n\)\)\s*\n\s*return 1;")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=SRC)
    args, rest = ap.parse_known_args()
    SRC = os.path.abspath(args.src)
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=2)
