# SPDX-License-Identifier: GPL-2.0-only
"""Host test: the module.prop of a zip that went through pack_module.py and pack_extra.py."""
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KMIS = ["android12-5.10", "android14-6.1", "android17-6.18"]


def pack(directory):
    d = Path(directory)
    (d / "susfs_insmod").write_bytes(b"")
    (d / "susfs_sc").write_bytes(b"probe")
    (d / "susfs_propwait").write_bytes(b"watch")
    for k in KMIS:
        (d / f"susfs_guard_lkm-{k}.ko").write_bytes(b"mock")
    out = d / "m.zip"
    subprocess.run([sys.executable, str(ROOT / "tools/pack_module.py"), "--ko-dir", str(d),
                    "--insmod", str(d / "susfs_insmod"), "--tag", "v1.2.3-dev.abc1234",
                    "--out", str(out)], check=True, capture_output=True)
    subprocess.run([sys.executable, str(ROOT / ".susfs-fork/pack_extra.py"), "--zip", str(out),
                    "--sc", str(d / "susfs_sc"), "--watch", str(d / "susfs_propwait"),
                    "--rejects", str(d / "rejects")],
                   check=True, capture_output=True)
    with zipfile.ZipFile(out) as z:
        lines = z.read("module.prop").decode().splitlines()
        names = set(z.namelist())
    # The watcher binary and its shell guard are shipped alongside the probe.
    assert "bin/susfs_propwait" in names, names
    assert "adbd_guard.sh" in names, names
    assert "update.sh" in names, names
    return dict(line.split("=", 1) for line in lines)


def main():
    with tempfile.TemporaryDirectory() as directory:
        prop = pack(directory)
    assert prop["id"] == "susfs_guard_lkm", prop
    assert prop["name"] == "SUSFS (LKM Edition)", prop
    assert prop["author"] == "LowKeyMerlin, inforcqb", prop
    assert prop["version"] == "v1.2.3-dev.abc1234", prop
    assert prop["versionCode"].isdigit() and int(prop["versionCode"]) > 1_700_000_000, prop
    assert prop["updateJson"] == "https://github.com/LowKeyMerlin/susfs4ksu-lkm/releases/latest/download/update.json", prop
    abi = (ROOT / "kernel/susfs_abi.h").read_text()
    assert f'"v{prop["susfsBase"]}"' in abi, prop
    assert prop["description"] == (
        f"Waiting for the first boot | 3 kernel builds, 5.10 to 6.18 | SUSFS {prop['susfsBase']}"), prop
    # The card text goes through sed with '#' as the delimiter.
    assert not set("#&\\") & set(prop["description"]), prop
    version = (ROOT / ".susfs-fork/VERSION").read_text().strip()
    assert len(version.split(".")) == 3 and all(p.isdigit() for p in version.split(".")), version
    print("pack_extra test ok")


if __name__ == "__main__":
    main()
