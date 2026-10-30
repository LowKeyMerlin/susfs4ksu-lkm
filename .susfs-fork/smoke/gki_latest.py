#!/usr/bin/env python3
"""Print the newest Google GKI release build of each given kernel as JSON.

Usage: gki_latest.py KMI [KMI ...]      for example: gki_latest.py android15-6.6 android16-6.12

Google tags every GKI release in kernel/common as <kmi>-<year>-<month>_r<n>, and the tag message
names the CI build. The newest tag whose build still serves its kernel Image is used, looking back
a few tags in case the newest build is not published yet. Nothing here names a kernel or build.

Prints [{"variant": KMI, "tag": TAG, "build": ID, "image": URL}, ...] and exits non-zero when a
kernel has no usable release, so a test never silently covers less than asked.
"""
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request

REMOTE = "https://android.googlesource.com/kernel/common"
IMAGE_URL = "https://ci.android.com/builds/submitted/{build}/kernel_aarch64/latest/raw/Image"
BUILD_ID = re.compile(r"builds/submitted/(\d+)/kernel_aarch64")
TRIES = 5
TIMEOUT = 60


def release_tags(kmi):
    """The release tags of one kernel, newest first."""
    out = subprocess.run(
        ["git", "ls-remote", "--tags", "--refs", REMOTE, f"refs/tags/{kmi}-*_r*"],
        check=True, capture_output=True, text=True, timeout=TIMEOUT * 2,
    ).stdout
    shape = re.compile(rf"refs/tags/({re.escape(kmi)}-(\d{{4}})-(\d{{2}})_r(\d+))$")
    found = [(int(m[2]), int(m[3]), int(m[4]), m[1]) for line in out.splitlines() if (m := shape.search(line))]
    return [tag for *_, tag in sorted(found, reverse=True)]


def build_of(tag):
    with urllib.request.urlopen(f"{REMOTE}/+/refs/tags/{tag}", timeout=TIMEOUT) as page:
        found = BUILD_ID.search(page.read().decode("utf-8", "replace"))
    return found[1] if found else None


def serves_image(url):
    """True when the artifact exists. One byte is asked for, the Image itself is tens of megabytes."""
    request = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as answer:
            return answer.status in (200, 206)
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return False
        raise


def latest(kmi):
    tags = release_tags(kmi)
    if not tags:
        raise SystemExit(f"{kmi}: Google has no release tag for it")
    for tag in tags[:TRIES]:
        build = build_of(tag)
        if build and serves_image(IMAGE_URL.format(build=build)):
            return {"variant": kmi, "tag": tag, "build": build, "image": IMAGE_URL.format(build=build)}
    raise SystemExit(f"{kmi}: none of the newest {TRIES} releases ({', '.join(tags[:TRIES])}) has a kernel Image")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    print(json.dumps([latest(kmi) for kmi in sys.argv[1:]], separators=(",", ":")))


if __name__ == "__main__":
    main()
