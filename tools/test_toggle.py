# SPDX-License-Identifier: GPL-2.0-only
"""Host test for module/toggle.sh against a fake /proc and a temporary config file.

The script writes /proc as root, so the cases that matter are the ones that must write nothing:
a key or value outside the whitelist, a node that is not there, a node that cannot be written.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "module" / "toggle.sh"
GIT_SH = Path("C:/Program Files/Git/bin/sh.exe")


def find_sh():
    return shutil.which("sh") or (str(GIT_SH) if GIT_SH.exists() else None)


def put(path, text):
    # write_text() would turn "\n" into "\r\n" on Windows; a /proc node never holds a CR.
    with open(path, "w", newline="\n") as f:
        f.write(text)


class Env:
    def __init__(self, sh, base):
        self.sh = sh
        self.proc = base / "proc"
        self.proc.mkdir()
        self.conf = base / "data" / "toggles"

    def node(self, key, text="0\n"):
        put(self.proc / f"susfs_{key}", text)

    def read(self, key):
        return (self.proc / f"susfs_{key}").read_text()

    def run(self, *args):
        r = subprocess.run([self.sh, str(SCRIPT), *args], capture_output=True, text=True,
                           env={"PATH": "/usr/bin:/bin:/mingw64/bin", "TOGGLE_PROC": self.proc.as_posix(),
                                "TOGGLE_CONF": self.conf.as_posix()})
        return r.returncode, r.stdout, r.stderr

    def saved(self):
        return self.conf.read_text() if self.conf.exists() else None


def main():
    sh = find_sh()
    if not sh:
        print("toggle test skipped: no sh on this host")
        return
    with tempfile.TemporaryDirectory() as d:
        e = Env(sh, Path(d))
        e.node("enable_log", "1\n")
        e.node("avc_spoof", "0 (su_sid=2907 priv_app_sid=2504 enter=0 hits=0)\n")
        e.node("selinux_hide", "native_supported=0 native_running=0\n")

        # get reads the first word only and reports a missing or odd node as unavailable;
        # selinux_hide is read-only and never appears in the saved config (see below)
        rc, out, _ = e.run("get")
        assert rc == 0 and out.split() == ["enable_log=1", "avc_spoof=0", "selinux_hide=none"], out
        e.node("selinux_hide", "native_supported=1 native_running=1\n")
        assert "selinux_hide=native" in e.run("get")[1]
        (e.proc / "susfs_selinux_hide").unlink()
        assert "selinux_hide=unavailable" in e.run("get")[1]
        put(e.proc / "susfs_selinux_hide", "garbage\n")
        assert "selinux_hide=unavailable" in e.run("get")[1]
        e.node("selinux_hide", "native_supported=0 native_running=0\n")

        # selinux_hide is not a settable key: refused like any other unknown key, nothing saved
        before = e.saved()
        rc, _, err = e.run("set", "selinux_hide", "1")
        assert rc == 64 and "usage" in err and e.saved() == before
        put(e.proc / "susfs_avc_spoof", "garbage\n")
        assert "avc_spoof=unavailable" in e.run("get")[1]
        (e.proc / "susfs_avc_spoof").unlink()
        assert "avc_spoof=unavailable" in e.run("get")[1]
        e.node("avc_spoof")

        # set writes the node and remembers it, once per key
        assert e.run("set", "enable_log", "0")[0] == 0
        assert e.read("enable_log").strip() == "0"
        assert e.saved() == "enable_log=0\n", e.saved()
        assert e.run("set", "enable_log", "1")[0] == 0
        assert e.run("set", "avc_spoof", "1")[0] == 0
        assert sorted(e.saved().split()) == ["avc_spoof=1", "enable_log=1"], e.saved()

        # bad input writes nothing: not a key, two keys in one argument, a path, a bad value
        before, node = e.saved(), e.read("enable_log")
        for args in (("set", "bogus", "1"), ("set", "enable_log avc_spoof", "1"),
                     ("set", "../x", "1"), ("set", "", "1"), ("set", "enable_log", "2"),
                     ("set", "enable_log", ""), ("set", "enable_log", "01"),
                     ("set", "enable_log", "1 "), ("set", "enable_log"), ("set",), ("nope",), ()):
            rc, _, err = e.run(*args)
            assert rc == 64 and "usage" in err, (args, rc, err)
        assert e.saved() == before and e.read("enable_log") == node

        # module not loaded: nothing is remembered either, or the next boot would apply it
        (e.proc / "susfs_avc_spoof").unlink()
        e.conf.unlink()
        rc, _, _ = e.run("set", "avc_spoof", "1")
        assert rc == 2 and e.saved() is None, (rc, e.saved())

        # a node that cannot be written: refused, nothing remembered
        (e.proc / "susfs_avc_spoof").mkdir()
        rc, _, _ = e.run("set", "avc_spoof", "1")
        assert rc == 1 and e.saved() is None, (rc, e.saved())
        (e.proc / "susfs_avc_spoof").rmdir()
        e.node("avc_spoof")

        # apply: remembered values go back, damaged and unknown lines are skipped
        e.node("enable_log", "1\n")
        put(e.conf, "evil=1\nenable_log=7\n\n=1\navc_spoof=1\nenable_log=0 \n")
        rc, _, _ = e.run("apply")
        assert rc == 0
        assert e.read("avc_spoof").strip() == "1", e.read("avc_spoof")
        assert e.read("enable_log").strip() == "1", "a bad value must not reach the node"
        assert not (e.proc / "susfs_evil").exists()
        e.conf.unlink()
        assert e.run("apply")[0] == 0

        # apply with the module not loaded does not fail the boot
        put(e.conf, "avc_spoof=1\n")
        (e.proc / "susfs_avc_spoof").unlink()
        rc, _, err = e.run("apply")
        assert rc == 0 and "not applied" in err, (rc, err)
    print("toggle test ok")


if __name__ == "__main__":
    sys.exit(main())
