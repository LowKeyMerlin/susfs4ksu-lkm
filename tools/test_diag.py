# SPDX-License-Identifier: GPL-2.0-only
"""Host tests for status.sh and check.sh, and the contract between them and the WebUI page."""
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_toggle import find_sh, put  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
OVERLAY = ROOT / ".susfs-fork" / "module"
PAGE = (ROOT / "module" / "webroot" / "index.html").read_text(encoding="utf-8")
LEVELS = {"ok", "info", "warn", "fail"}


class Scratch(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sh = find_sh()
        if not cls.sh:
            raise unittest.SkipTest("no POSIX sh on this host")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.modules = self.base / "modules"
        self.mod = self.modules / "susfs_guard_lkm"
        self.mod.mkdir(parents=True)
        for name in ("status.sh", "check.sh"):
            data = (OVERLAY / name).read_bytes().replace(b"\r\n", b"\n")
            (self.mod / name).write_bytes(data)
        put(self.mod / "module.prop",
            "id=susfs_guard_lkm\nname=SUSFS (LKM Edition)\nversion=v1.0.0\nsusfsBase=2.3.0\n"
            "description=Active | boot load | android16-6.12 | SUSFS 2.3.0\n")
        self.proc = self.base / "proc"
        (self.proc / "sys/kernel").mkdir(parents=True)
        put(self.proc / "sys/kernel/osrelease", "6.12.23-android16-5-gabc-4k\n")
        put(self.proc / "modules", "other_mod 1 0 - Live 0x0\n")
        put(self.proc / "kallsyms", "0 T printk\n")
        self.sysmod = self.base / "sysmod"
        self.sysmod.mkdir()
        self.hook = self.base / "hook"
        self.dmesg = self.base / "dmesg"
        self.dmesg.write_text("#!/bin/sh\ncat \"$0.out\" 2>/dev/null\n")
        self.dmesg.chmod(0o755)
        self.enforce = self.base / "getenforce"
        self.enforce.write_text("#!/bin/sh\necho Enforcing\n")
        self.enforce.chmod(0o755)
        self.brene_conf = self.base / "brene.conf"

    def env(self):
        return {
            "PATH": "/usr/bin:/bin:/mingw64/bin",
            "SUSFS_PROC": self.proc.as_posix(),
            "SUSFS_SYS_MODULE": self.sysmod.as_posix(),
            "SUSFS_MODULES_DIR": self.modules.as_posix(),
            "SUSFS_EARLY_HOOK": self.hook.as_posix(),
            "SUSFS_TIMEOUT_LOG": (self.base / "timeout.log").as_posix(),
            "SUSFS_DMESG": self.dmesg.as_posix(),
            "SUSFS_GETENFORCE": self.enforce.as_posix(),
            "SUSFS_BRENE_CONF": self.brene_conf.as_posix(),
        }

    def run_script(self, name):
        r = subprocess.run([self.sh, (self.mod / name).as_posix()], capture_output=True, text=True,
                           env=self.env(), timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def checks(self):
        found = {}
        for line in self.run_script("check.sh").splitlines():
            parts = line.split("|")
            self.assertEqual(len(parts), 4, f"one record per line: {line!r}")
            self.assertIn(parts[1], LEVELS, line)
            found[parts[0]] = parts[1:]
        return found


class Status(Scratch):
    def test_reports_the_facts(self):
        (self.mod / "early_load").write_text("")
        self.hook.write_text("")
        (self.mod / "guard.fails").write_text("1\n")
        out = dict(l.split("=", 1) for l in self.run_script("status.sh").splitlines())
        self.assertEqual(out["name"], "SUSFS (LKM Edition)")
        self.assertEqual(out["version"], "v1.0.0")
        self.assertEqual(out["susfs_base"], "2.3.0")
        self.assertEqual(out["kernel"], "6.12.23-android16-5-gabc-4k")
        self.assertEqual((out["loaded"], out["early_load"], out["guard_tripped"], out["guard_fails"]),
                         ("1", "1", "0", "1"))

    def test_early_load_needs_marker_and_hook(self):
        (self.mod / "early_load").write_text("")
        out = dict(l.split("=", 1) for l in self.run_script("status.sh").splitlines())
        self.assertEqual(out["early_load"], "0")


class Checks(Scratch):
    def test_healthy_device_has_no_warning(self):
        (self.mod / "early_load").write_text("")
        self.hook.write_text("")
        levels = {k: v[0] for k, v in self.checks().items()}
        self.assertNotIn("warn", levels.values())
        self.assertNotIn("fail", levels.values())
        self.assertEqual(levels["loaded"], "ok")
        self.assertEqual(levels["early_load"], "ok")

    def test_not_loaded_is_a_problem_and_quotes_the_card(self):
        self.sysmod.rmdir()
        loaded = self.checks()["loaded"]
        self.assertEqual(loaded[0], "fail")
        self.assertIn("Active", loaded[2])

    def test_layers_that_failed_to_start_are_named(self):
        Path(str(self.dmesg) + ".out").write_text(
            "[1.0] susfs_guard_lkm: sus_mount init failed -22 - that feature stays off\n"
            "[1.1] susfs_guard_lkm: kstat init failed -2 - that feature stays off\n")
        layers = self.checks()["layers"]
        self.assertEqual(layers[0], "warn")
        self.assertIn("kstat", layers[2])
        self.assertIn("sus_mount", layers[2])

    def test_module_listed_in_proc_modules_is_a_problem(self):
        put(self.proc / "modules", "susfs_guard_lkm 1 0 - Live 0x0\n")
        self.assertEqual(self.checks()["hide_modules"][0], "fail")

    def test_module_symbols_in_kallsyms_are_a_problem(self):
        put(self.proc / "kallsyms", "0 t foo\t[susfs_guard_lkm]\n")
        self.assertEqual(self.checks()["hide_symbols"][0], "fail")

    def test_tripped_guard_is_a_problem(self):
        (self.mod / "guard.tripped").write_text("2 boots in a row ended early\n")
        self.assertEqual(self.checks()["guard"][0], "fail")

    def test_overlapping_module_is_a_warning_unless_disabled(self):
        other = self.modules / "resusfs"
        other.mkdir()
        put(other / "module.prop", "id=resusfs\nname=ReSUSFS\n")
        self.assertEqual(self.checks()["conflicts"][0], "warn")
        (other / "disable").write_text("")
        self.assertEqual(self.checks()["conflicts"][0], "ok")

    def test_brene_is_a_companion_not_a_conflict(self):
        other = self.modules / "brene"
        other.mkdir()
        put(other / "module.prop", "id=brene\nname=.BRENE - SuSFS\n")
        self.assertEqual(self.checks()["conflicts"][0], "ok")

    def brene(self, avc, log, node_avc, node_log):
        # BRENE's file starts with blanks and sometimes NULs, which makes grep call it binary.
        self.brene_conf.write_bytes(b"\x00\x00   \nconfig_enable_log=%s\nconfig_enable_avc_log_spoofing=%s\n" % (log, avc))
        (self.proc / "susfs_avc_spoof").write_bytes(node_avc + b" (su_sid=76 enter=0 hits=0)\n")
        (self.proc / "susfs_enable_log").write_bytes(node_log + b"\n")

    def test_brene_settings_that_never_reached_the_kernel_are_a_warning(self):
        self.brene(b"1", b"0", b"0", b"1")
        sync = self.checks()["brene_sync"]
        self.assertEqual(sync[0], "warn")
        self.assertIn("enable_avc_log_spoofing (BRENE 1, kernel 0)", sync[2])
        self.assertIn("enable_log (BRENE 0, kernel 1)", sync[2])

    def test_brene_settings_that_match_are_fine(self):
        self.brene(b"1", b"0", b"1", b"0")
        self.assertEqual(self.checks()["brene_sync"][0], "ok")

    def test_no_brene_means_no_brene_check(self):
        self.assertNotIn("brene_sync", self.checks())

    def test_unrelated_module_is_not_a_conflict(self):
        other = self.modules / "zygisk_thing"
        other.mkdir()
        put(other / "module.prop", "id=zygisk_thing\nname=Something else\n")
        self.assertEqual(self.checks()["conflicts"][0], "ok")

    def test_permissive_selinux_is_a_problem(self):
        self.enforce.write_text("#!/bin/sh\necho Permissive\n")
        self.assertEqual(self.checks()["selinux"][0], "fail")

    def log(self, text):
        Path(str(self.dmesg) + ".out").write_text(text)

    # These two lines are from a Pixel-class android16-6.12 kernel, where the module loaded and
    # two hooks were not in place.
    def test_hooks_the_module_could_not_place_are_a_warning(self):
        self.log("[20.8] susfs_guard_lkm: sus_map: register_kprobe(__get_user_pages_remote) failed -2 - that listing is not filtered\n"
                 "[59.2] susfs_guard_lkm: susfs_hide_syms: kallsyms m->private is not a struct kallsym_iter - the mirror drifted; /proc/kallsyms is NOT being filtered\n")
        kernel_log = self.checks()["kernel_log"]
        self.assertEqual(kernel_log[0], "warn")
        self.assertIn("2 line(s)", kernel_log[2])
        self.assertIn("__get_user_pages_remote", kernel_log[2])

    def test_boot_time_notes_about_empty_rule_lists_are_not_warnings(self):
        self.log("[5.4] susfs_guard_lkm: sus_map: no rules, hook not installed\n"
                 "[5.4] susfs_guard_lkm: spoof_cmdline: no fake bootconfig, not armed\n"
                 "[20.9] susfs_guard_lkm: sus_map: skipped walk_page_range walk for ino=1 dev=2 uid=3\n"
                 "[374.6] susfs_guard_lkm: priority_filter: 'com.example' is uid 10203\n")
        self.assertEqual(self.checks()["kernel_log"][0], "ok")

    def test_other_drivers_warnings_are_not_the_modules(self):
        self.log("[8.3] qcom,fastrpc: Warning: fastrpc_notif_find_process failed\n")
        self.assertEqual(self.checks()["kernel_log"][0], "ok")

    def test_a_log_of_megabytes_is_read(self):
        line = "[374.6] susfs_guard_lkm: priority_filter: 'com.example.app' is uid 10203\n"
        self.log(line * 30000 + "[400.0] susfs_guard_lkm: sus_map: register_kprobe(x) failed -2 - that listing is not filtered\n")
        self.assertEqual(self.checks()["kernel_log"][0], "warn")

    # Android's sh has no printf builtin, so a log held in a variable and handed to printf fails
    # there once it passes the 128 KB argument limit. The host shells here have the builtin and
    # would not show it.
    def test_the_log_is_never_held_in_a_variable(self):
        src = (OVERLAY / "check.sh").read_text()
        self.assertNotRegex(src, r'=\$\("\$DMESG"[^|\n]*\)')

    def test_separator_in_a_message_cannot_split_the_record(self):
        put(self.mod / "module.prop", "description=a|b\nline two\n")
        self.sysmod.rmdir()
        self.checks()


class Page(unittest.TestCase):
    def test_no_html_injection_or_remote_code(self):
        for bad in ("innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"):
            self.assertNotIn(bad, PAGE, bad)
        self.assertIsNone(re.search(r"https?://", PAGE), "no remote resource")

    def test_costs_nothing_while_idle(self):
        for bad in ("setInterval", "requestAnimationFrame", "animation:", "@keyframes", "backdrop-filter"):
            self.assertNotIn(bad, PAGE, bad)
        self.assertIn("prefers-reduced-motion", PAGE)

    def test_every_element_the_script_uses_exists(self):
        ids = set(re.findall(r'id="([\w-]+)"', PAGE))
        used = set(re.findall(r'getElementById\("([\w-]+)"\)', PAGE))
        used |= {f"tab-{n}" for n in ("overview", "health", "options")}
        used |= {f"panel-{n}" for n in ("overview", "health", "options")}
        self.assertFalse(used - ids, used - ids)

    def test_it_calls_scripts_that_ship(self):
        called = set(re.findall(r'run\("([\w.]+\.sh)"', PAGE))
        shipped = {p.name for p in OVERLAY.glob("*.sh")} | {p.name for p in (ROOT / "module").glob("*.sh")}
        self.assertTrue({"status.sh", "check.sh", "toggle.sh"} <= called, called)
        self.assertFalse(called - shipped, called - shipped)

    def test_it_knows_every_level_the_checks_print(self):
        for level in LEVELS:
            self.assertRegex(PAGE, rf"\b{level}:\s*\{{ label")

    def test_toggle_keys_are_the_ones_toggle_sh_accepts(self):
        keys = set(re.findall(r'key: "(\w+)"', PAGE))
        accepted = set(re.search(r"is_key\(\) \{\s*case \$1 in\s*([\w|]+)\)", (ROOT / "module/toggle.sh").read_text())[1].split("|"))
        self.assertTrue(keys <= accepted, (keys, accepted))


if __name__ == "__main__":
    unittest.main(verbosity=2)
