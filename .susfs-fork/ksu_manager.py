#!/usr/bin/env python3
"""Download the manager APK that ksu_release.py chose for a fork.

Usage: ksu_manager.py OUT_DIR < ENTRY_JSON

ENTRY_JSON is one element of the ksu_release.py output. A release APK keeps its own name. One
from a fork's CI is named FORK_VERSIONNAME_BUILDNUMBER-spoofed.apk after what it reports, since CI
file names differ per fork and some omit the build, while a version name between tags is only the
tag. Prints one JSON object with the file name, SHA-256, package, version name and build number
read from the manifest, and the source.

A download is checked before it is kept. A release asset is compared with the digest GitHub holds
for it. Every APK must be a zip with a readable manifest and code and carry a signing block, so
an HTML page or truncated file does not pass. A pin's manager must report the pin's version name
and build number, which ties the file to the tested build. Anything that does not add up stops
the run. Needs the gh CLI, authenticated through GH_TOKEN, for a fork's CI artifacts.
"""
import hashlib
import json
import pathlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

from ksu_release import pick_apk

TIMEOUT = 120
TRIES = 3
SIGNING_BLOCK = b"APK Sig Block 42"
REQUIRED_ENTRIES = ("AndroidManifest.xml", "classes.dex")
NAME_PART = re.compile(r"[\w.+-]+")

# The binary XML of a manifest: chunk types and the types of an attribute value.
CHUNK_STRINGS = 0x0001
CHUNK_START_ELEMENT = 0x0102
VALUE_STRING = 0x03
VALUE_INT = (0x10, 0x11)
UTF8_FLAG = 0x100
NO_STRING = 0xFFFFFFFF


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(url, dest):
    error = None
    for _ in range(TRIES):
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT) as answer, dest.open("wb") as out:
                shutil.copyfileobj(answer, out)
            return
        except OSError as err:
            error = err
    sys.exit(f"{url}: {error}")


def from_release(manager, dest):
    download(manager["url"], dest)
    digest = manager.get("digest")
    if not digest:
        print(f"{manager['name']}: GitHub holds no digest for it, only its structure is checked", file=sys.stderr)
    elif digest != f"sha256:{sha256(dest)}":
        sys.exit(f"{manager['name']}: does not match the digest {digest} of the release")


def from_ci(entry, tmp):
    manager = entry["manager"]
    what = f"artifact {manager['name']} of run {manager['run']} in {entry['repo']}"
    try:
        subprocess.run(["gh", "run", "download", str(manager["run"]), "--repo", entry["repo"],
                        "--name", manager["name"], "--dir", str(tmp)],
                       check=True, capture_output=True, text=True)
    except OSError as err:
        sys.exit(f"cannot run gh to download the {what}: {err}")
    except subprocess.CalledProcessError as err:
        sys.exit(f"cannot download the {what}: {err.stderr.strip()}")
    found = {p.name: p for p in tmp.rglob("*.apk")}
    chosen = pick_apk(list(found))
    if chosen is None:
        sys.exit(f"{entry['name']}: cannot tell which APK to take out of {', '.join(sorted(found)) or 'nothing'}")
    return found[chosen]


def pool_string(data, chunk, strings_start, utf8, offset):
    pos = chunk + strings_start + offset
    if utf8:
        pos += 2 if data[pos] & 0x80 else 1
        size = data[pos]
        pos += 1
        if size & 0x80:
            size = ((size & 0x7F) << 8) | data[pos]
            pos += 1
        return data[pos:pos + size].decode("utf-8", "replace")
    size = struct.unpack_from("<H", data, pos)[0]
    pos += 2
    if size & 0x8000:
        size = ((size & 0x7FFF) << 16) | struct.unpack_from("<H", data, pos)[0]
        pos += 2
    return data[pos:pos + size * 2].decode("utf-16-le", "replace")


def manifest_attributes(data):
    """The attributes of the manifest element out of the binary XML of an APK."""
    pos = 8
    strings = []
    while pos + 8 <= len(data):
        kind, header, size = struct.unpack_from("<HHI", data, pos)
        if size < 8:
            break
        if kind == CHUNK_STRINGS:
            count, _styles, flags, start, _ = struct.unpack_from("<5I", data, pos + 8)
            offsets = struct.unpack_from(f"<{count}I", data, pos + header)
            strings = [pool_string(data, pos, start, bool(flags & UTF8_FLAG), o) for o in offsets]
        elif kind == CHUNK_START_ELEMENT:
            if strings[struct.unpack_from("<I", data, pos + 20)[0]] != "manifest":
                break
            offset, width, count = struct.unpack_from("<3H", data, pos + 24)
            found = {}
            for i in range(count):
                _ns, name, raw, _size, _res, vtype, value = struct.unpack_from(
                    "<3IHBBI", data, pos + 16 + offset + i * width)
                if vtype == VALUE_STRING:
                    found[strings[name]] = strings[raw if raw != NO_STRING else value]
                elif vtype in VALUE_INT:
                    found[strings[name]] = value
            return found
        pos += size
    return {}


def check_apk(path):
    """The package, version name and build number the APK reports, once it passes the checks."""
    if not zipfile.is_zipfile(path):
        sys.exit(f"{path.name}: not a zip, so not an APK")
    with zipfile.ZipFile(path) as apk:
        missing = [n for n in REQUIRED_ENTRIES if n not in apk.namelist()]
        if missing:
            sys.exit(f"{path.name}: lacks {', '.join(missing)}")
        try:
            attributes = manifest_attributes(apk.read("AndroidManifest.xml"))
        except (struct.error, IndexError) as err:
            sys.exit(f"{path.name}: the manifest cannot be read: {err}")
    package = attributes.get("package")
    version_name = attributes.get("versionName")
    version_code = attributes.get("versionCode")
    if not package or not version_name or not isinstance(version_code, int):
        sys.exit(f"{path.name}: the manifest names no package, version name or build number")
    if SIGNING_BLOCK not in path.read_bytes():
        sys.exit(f"{path.name}: carries no APK signing block, it would not install")
    return {"package": package, "versionName": version_name, "versionCode": version_code}


def spoofed_name(fork, about):
    name = f"{fork}_{about['versionName']}_{about['versionCode']}-spoofed.apk"
    if not NAME_PART.fullmatch(name):
        sys.exit(f"{fork}: {name} is not a usable file name")
    return name


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    out = pathlib.Path(sys.argv[1])
    try:
        entry = json.load(sys.stdin)
        manager = entry["manager"]
        kind = manager["kind"]
    except (ValueError, KeyError, TypeError):
        sys.exit("the input is not an entry of ksu_release.py with a manager")
    if kind == "none":
        sys.exit(f"{entry['name']}: there is no manager to download")

    out.mkdir(parents=True, exist_ok=True)
    name = manager["name"]
    with tempfile.TemporaryDirectory() as tmp:
        if kind == "ci-spoofed":
            fetched = from_ci(entry, pathlib.Path(tmp))
        else:
            fetched = pathlib.Path(tmp) / name
            from_release(manager, fetched)
        about = check_apk(fetched)
        expect = manager.get("expect")
        if expect and any(about[key] != expect[key] for key in expect):
            sys.exit(f"{entry['name']}: the APK reports {about['versionName']} build {about['versionCode']}, "
                     f"the pin says {expect['versionName']} build {expect['versionCode']}")
        if kind == "ci-spoofed":
            name = spoofed_name(entry["name"], about)
        kept = out / name
        shutil.copyfile(fetched, kept)

    print(json.dumps({"name": name, "sha256": sha256(kept), "kind": kind, "fork": entry["name"],
                      "commit": entry["commit"], **about}, separators=(",", ":")))


if __name__ == "__main__":
    main()
