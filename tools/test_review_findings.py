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

/* user memory is host memory; fault_at counts user accesses and fails exactly that one */
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


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=SRC)
    args, rest = ap.parse_known_args()
    SRC = os.path.abspath(args.src)
    unittest.main(argv=[sys.argv[0]] + rest, verbosity=2)
