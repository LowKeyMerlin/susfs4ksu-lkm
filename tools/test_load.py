# SPDX-License-Identifier: GPL-2.0-only
"""Host test for the outcome handling of module/load.sh, with a fake loader and a fake `timeout`.

The loader's result decides what the KernelSU manager shows on the module card and the exit
status, so each result has a case: loaded, EEXIST, a failure, a timeout, and a timeout that
arrives after the module came up (init_module(2) is not interrupted by the TERM `timeout` sends,
so the loader dies only once module_init() has returned).
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_toggle import find_sh, put  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
KMI = "android16-6.12"


def script(path, body):
    put(path, "#!/bin/sh\n" + body)
    os.chmod(path, 0o755)


class LoadSh(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sh = find_sh()
        if not cls.sh:
            raise unittest.SkipTest("no POSIX sh on this host")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.mod = base / "mod"
        (self.mod / "lib").mkdir(parents=True)
        (self.mod / "bin").mkdir()
        self.node = base / "proc_susfs_path"
        self.tlog = base / "timeout.log"
        self.dlog = base / "timeout_dmesg.log"
        # The script keeps its paths as literals, so the copy under test gets the scratch ones.
        paths = {
            "/proc/susfs_path": self.node,
            "/sys/module/susfs_guard_lkm": base / "no_such_dir",
            "/proc/sys/kernel/osrelease": base / "osrelease",
            "/data/adb/susfsload_timeout.log": self.tlog,
            "/data/adb/susfsload_timeout_dmesg.log": self.dlog,
        }
        text = (ROOT / "module" / "load.sh").read_text(encoding="utf-8").replace("\r\n", "\n")
        for literal, scratch in paths.items():
            assert literal in text, literal
            text = text.replace(literal, scratch.as_posix())
        (self.mod / "load.sh").write_text(text, encoding="utf-8", newline="\n")
        for name in ("kmi.sh", "toggle.sh"):
            data = (ROOT / "module" / name).read_bytes().replace(b"\r\n", b"\n")
            (self.mod / name).write_bytes(data)
        put(self.mod / "kmis", KMI + "\n")
        put(self.mod / "lib" / f"susfs_guard_lkm-{KMI}.ko", "ko")
        put(self.mod / "module.prop", "id=x\ndescription=initial\n")
        put(base / "osrelease", "6.12.23-android16-5-gabcdef-4k\n")
        self.stubs = base / "stubs"
        self.stubs.mkdir()
        script(self.stubs / "getprop", "echo 0\n")
        script(self.stubs / "dmesg", "exec sleep 30\n")
        script(self.stubs / "timeout", 'shift\nexec "$@"\n')
        # the fake loader: optionally brings the module "up", then exits with FAKE_RC
        script(
            self.mod / "bin" / "susfs_insmod",
            '[ -n "$FAKE_NODE" ] && : > "$FAKE_NODE"\nexit "$FAKE_RC"\n',
        )

    def run_load(self, rc, node_up=False):
        env = {
            "PATH": f"{self.stubs.as_posix()}:/usr/bin:/bin:/mingw64/bin",
            "FAKE_RC": str(rc),
            "FAKE_NODE": self.node.as_posix() if node_up else "",
        }
        r = subprocess.run(
            [self.sh, (self.mod / "load.sh").as_posix()],
            capture_output=True,
            text=True,
            env=env,
            timeout=120,
        )
        desc = next(
            l
            for l in (self.mod / "module.prop").read_text(encoding="utf-8").splitlines()
            if l.startswith("description=")
        )
        return r.returncode, desc

    def test_loaded(self):
        rc, desc = self.run_load(0, node_up=True)
        self.assertEqual(rc, 0)
        self.assertIn(f"auto-detected ({KMI})", desc)
    def test_eexist_is_not_a_failure(self):
        rc, desc = self.run_load(17)
        self.assertEqual(rc, 0)
        self.assertIn("already present", desc)

    def test_failure_keeps_its_status(self):
        rc, desc = self.run_load(5)
        self.assertEqual(rc, 5)
        self.assertIn("load failed", desc)

    def test_timeout_without_module_is_a_failure(self):
        rc, desc = self.run_load(124)
        self.assertEqual(rc, 124)
        self.assertIn("timed out", desc)
        self.assertTrue(self.tlog.exists(), "the timeout log is written")

    def test_timeout_after_module_came_up_is_a_late_success(self):
        rc, desc = self.run_load(124, node_up=True)
        self.assertEqual(rc, 0, "the module is loaded: not a failure")
        self.assertIn("auto-detected", desc)
        self.assertNotIn("timed out", desc)
        self.assertIn("but the module is up", (self.mod / "load.log").read_text())
        self.assertFalse(self.tlog.exists(), "no timeout report for a load that worked")


if __name__ == "__main__":
    unittest.main(verbosity=2)
