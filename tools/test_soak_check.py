#!/usr/bin/env python3
"""The judge of the soak, unload and reload stage in .susfs-fork/smoke/check.py.

A healthy set of facts passes, and each fact that goes wrong, or is missing, is a problem; a
kernel message that a deadlock or a lockup prints is a crash.  Run: python3 tools/test_soak_check.py
"""
import importlib.util
import pathlib
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("smoke_check", ROOT / ".susfs-fork/smoke/check.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def healthy():
    facts = {key: want for key, want, _ in check.SOAK_EXPECTED}
    facts["unload_kprobes_base"] = "0"
    for c in (1, 2, 3):
        for key, want, _ in check.UNLOAD_EXPECTED:
            facts[key.format(c=c)] = want
        facts[f"unload{c}_kprobes_left"] = "0"
    facts["soak_slab_growth_kb"] = "100"
    facts["unload_slab_growth_kb"] = "-20"
    return facts


class SoakJudge(unittest.TestCase):
    def test_healthy_facts_pass(self):
        self.assertEqual(check.soak_problems(healthy()), [])

    def test_each_wrong_or_missing_fact_is_a_problem(self):
        base = healthy()
        for key in base:
            with self.subTest(key=key, how="missing"):
                f = dict(base)
                del f[key]
                self.assertTrue(check.soak_problems(f), f"{key} missing went unnoticed")
        for key in [k for k in base if not k.endswith("_kb") and k != "unload_kprobes_base"]:
            with self.subTest(key=key, how="wrong"):
                f = dict(base)
                f[key] = "bogus"
                self.assertTrue(check.soak_problems(f), f"{key}=bogus went unnoticed")

    def test_leftover_kprobe_is_a_problem(self):
        f = healthy()
        f["unload2_kprobes_left"] = "3"
        self.assertTrue(any("kprobe" in p for p in check.soak_problems(f)))

    def test_slab_growth_over_the_limit_is_a_problem(self):
        for key, limit, _ in check.SLAB_LIMITS:
            f = healthy()
            f[key] = str(limit + 1)
            self.assertTrue(check.soak_problems(f), key)
            f[key] = str(limit)
            self.assertEqual(check.soak_problems(f), [], key)


class StallsAreCrashes(unittest.TestCase):
    def test_patterns(self):
        for line in (
            "[  50.1] watchdog: BUG: soft lockup - CPU#1 stuck for 22s!",
            "[  50.1] rcu: INFO: rcu_sched detected stalls on CPUs/tasks:",
            "[  50.1] INFO: task sh:77 blocked for more than 120 seconds.",
            "[  50.1] WARNING: possible circular locking dependency detected",
            "[  50.1] refcount_t: underflow; use-after-free.",
        ):
            self.assertTrue(check.CRASH.search(line), line)

    def test_a_quiet_boot_is_not_a_crash(self):
        for line in (
            "[    0.1] rcu: RCU dyntick-idle grace-period acceleration is enabled.",
            "[    1.0] kvm [1]: HYP mode not available",
            "[    2.0] susfs_guard_lkm: loaded.",
        ):
            self.assertFalse(check.CRASH.search(line), line)


if __name__ == "__main__":
    sys.exit(unittest.main(verbosity=2).result.wasSuccessful() is False)
