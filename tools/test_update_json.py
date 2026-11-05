# SPDX-License-Identifier: GPL-2.0-only
"""Host test: the update.json of a release zip."""
import importlib.util
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("update_json", ROOT / ".susfs-fork/update_json.py")
update_json = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update_json)


def refused(path, tag):
    try:
        update_json.update_json(path, "o/r", tag)
    except SystemExit as e:
        return str(e)
    return None


def main():
    with tempfile.TemporaryDirectory() as d:
        zip_path = str(Path(d) / "ksu_susfs_lkm-module-v1.2.3-arm64.zip")
        with zipfile.ZipFile(zip_path, "w") as z:
            z.writestr("module.prop", "id=susfs_guard_lkm\nversion=v1.2.3\nversionCode=1700000123\n")
        got = update_json.update_json(zip_path, "o/r", "v1.2.3")
        assert got == {
            "version": "v1.2.3",
            "versionCode": 1700000123,
            "zipUrl": "https://github.com/o/r/releases/download/v1.2.3/ksu_susfs_lkm-module-v1.2.3-arm64.zip",
            "changelog": "https://github.com/o/r/releases/tag/v1.2.3",
        }, got
        assert isinstance(got["versionCode"], int)
        assert "not v1.2.4" in refused(zip_path, "v1.2.4")
        bad = str(Path(d) / "bad.zip")
        with zipfile.ZipFile(bad, "w") as z:
            z.writestr("module.prop", "version=v1.2.3\nversionCode=abc\n")
        assert "versionCode" in refused(bad, "v1.2.3")
    print("update_json test ok")


main()