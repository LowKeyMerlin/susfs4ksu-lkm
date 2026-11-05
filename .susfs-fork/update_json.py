#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Print the update.json that the root manager's Update button reads for a release.

Usage: update_json.py ZIP REPOSITORY TAG

ZIP is the module zip attached to release TAG of REPOSITORY (owner/name). Its module.prop supplies
the version and versionCode, so the manager compares what the zip really contains. A zip whose
version is not TAG is an error. A release that carries this file is the one the WebUI offers to
install.
"""
import json
import sys
import zipfile
from pathlib import Path


def update_json(zip_path, repository, tag):
    with zipfile.ZipFile(zip_path) as z:
        text = z.read("module.prop").decode()
    prop = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
    if prop.get("version") != tag:
        raise SystemExit(f"{zip_path} is version {prop.get('version')}, not {tag}")
    if not prop.get("versionCode", "").isdigit():
        raise SystemExit(f"{zip_path} has no numeric versionCode")
    base = f"https://github.com/{repository}/releases"
    return {
        "version": tag,
        "versionCode": int(prop["versionCode"]),
        "zipUrl": f"{base}/download/{tag}/{Path(zip_path).name}",
        "changelog": f"{base}/tag/{tag}",
    }


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    print(json.dumps(update_json(*sys.argv[1:]), indent=2))