#!/usr/bin/env python3
"""Add the bootloop guard and the installer screen to the zip tools/pack_module.py wrote.

Usage:
    pack_extra.py --check [--rejects DIR]
    pack_extra.py --zip ZIP --sc SUSFS_SC [--rejects DIR]

Upstream's module scripts are not edited. In the zip, upstream's load.sh becomes load.upstream.sh
and the wrapper from .susfs-fork/module/load.sh takes its name, which both boot paths already
call. The wrapper runs the upstream loader unchanged, so changes upstream makes to it need no
merging. The installer works the same way: customize.sh becomes customize.upstream.sh and
.susfs-fork/module/customize.sh prints the steps around it and runs it.

This holds only while upstream's scripts keep the shape the wrapper relies on, which the checks
below verify. When one fails nothing is written, the reasons and the scripts looked at go to the
rejects directory, and the exit status is 2.

--check runs the same checks against the module directory in the repository, without a zip.
"""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE = ROOT / "module"
OVERLAY = pathlib.Path(__file__).resolve().parent / "module"

# Files taken from .susfs-fork/module/, and where they go in the zip.
WRAPPER = "load.sh"
INSTALLER = "customize.sh"
ADDED = {name: name for name in (
    "guard.sh", "service.sh", "status.sh", "check.sh", "early.sh", "hide_mounts.sh", "boot-completed.sh",
    "scope.sh", "clients.sh")}
LOADER = "load.upstream.sh"
INSTALLER_UPSTREAM = "customize.upstream.sh"
# What upstream's script of that name becomes in the zip.
RENAMED = {WRAPPER: LOADER, INSTALLER: INSTALLER_UPSTREAM}
PROBE = "bin/susfs_sc"
BUILD_WORKFLOW = ".github/workflows/susfs-build.yml"

# Upstream's scripts that must exist, and the two that start the loader.
REQUIRED = ("post-fs-data.sh", "early-dispatch.sh", "load.sh", "kmi.sh", "customize.sh", "uninstall.sh")
ENTRY_POINTS = ("post-fs-data.sh", "early-dispatch.sh")
CALLS_LOADER = '"$MODDIR/load.sh"'
LOCATES_ITSELF = "MODDIR=${0%/*}"
SELECTOR = "select_kmi()"


class Reject(Exception):
    def __init__(self, problems, files=None):
        super().__init__("\n".join(problems))
        self.problems = problems
        self.files = files or {}


def contract(files):
    """files maps a zip member name to its bytes. Returns what is wrong, empty when it fits."""
    problems = []
    for name in REQUIRED:
        if name not in files:
            problems.append(f"upstream no longer has {name}")
    for name in (LOADER, INSTALLER_UPSTREAM, PROBE, *ADDED.values()):
        if name in files:
            problems.append(f"upstream now ships {name}, which the guard adds")
    for name in ENTRY_POINTS:
        if name in files and CALLS_LOADER.encode() not in files[name]:
            problems.append(f"{name} no longer runs {CALLS_LOADER}, so the wrapper would not be used")
    if "kmi.sh" in files and SELECTOR.encode() not in files["kmi.sh"]:
        problems.append(f"kmi.sh no longer defines {SELECTOR}, which the kernel release check calls")
    if "load.sh" in files and LOCATES_ITSELF.encode() not in files["load.sh"]:
        problems.append(f"load.sh no longer sets {LOCATES_ITSELF}, so it cannot be run under another name")
    return problems


def overlay_sources():
    sources = {}
    for name in (WRAPPER, INSTALLER, *ADDED):
        path = OVERLAY / name
        if not path.is_file():
            raise Reject([f"{path.relative_to(ROOT)} is missing"])
        # A checkout that converts line endings must not put carriage returns into a shell script.
        sources[name] = path.read_bytes().replace(b"\r\n", b"\n")
    return sources


def syntax(sources):
    """Shell syntax of what is added, and shellcheck when the machine has it."""
    problems = []
    sh = shutil.which("sh")
    shellcheck = shutil.which("shellcheck")
    with tempfile.TemporaryDirectory() as tmp:
        for name, data in sources.items():
            path = pathlib.Path(tmp) / name
            path.write_bytes(data)
            if sh and subprocess.run([sh, "-n", str(path)], capture_output=True).returncode:
                problems.append(f"{name} does not parse as a shell script")
            if shellcheck:
                run = subprocess.run([shellcheck, "-s", "sh", "-S", "warning", str(path)],
                                     capture_output=True, text=True)
                if run.returncode:
                    problems.append(f"shellcheck on {name}:\n{run.stdout}")
    return problems


def reject(problems, files, rejects):
    out = pathlib.Path(rejects)
    out.mkdir(parents=True, exist_ok=True)
    (out / "contract.txt").write_text("\n".join(problems) + "\n", encoding="utf-8")
    for name in REQUIRED:
        if name in files:
            (out / name).write_bytes(files[name])
    print("pack_extra: the guard does not fit upstream's module scripts:", file=sys.stderr)
    for p in problems:
        print(f"  {p}", file=sys.stderr)


NAME = "SUSFS (LKM Edition)"
AUTHOR = "LowKeyMerlin, inforcqb"
ABI_HEADER = ROOT / "kernel" / "susfs_abi.h"


def susfs_base():
    """The SUSFS release the kernel code tracks, without the leading v."""
    for line in ABI_HEADER.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if parts[:2] == ["#define", "SUSFS_VERSION_STR"] and len(parts) > 2:
            return parts[2].strip('"').lstrip("v")
    raise Reject([f"{ABI_HEADER.relative_to(ROOT)} has no SUSFS_VERSION_STR"])


def kmi_range(kmis):
    """Lowest and highest kernel version among KMI names like android14-6.1."""
    versions = sorted((tuple(int(n) for n in k.split("-", 1)[1].split(".")), k.split("-", 1)[1]) for k in kmis)
    return versions[0][1], versions[-1][1]


def brand(prop, kmis):
    """Our name, author and base version in the module.prop that pack_module.py wrote.

    The version and versionCode stay as pack_module.py set them. The description is what the card
    shows until the first boot, load.sh replaces it with the state of that boot.
    """
    base = susfs_base()
    low, high = kmi_range(kmis)
    props = dict(line.split("=", 1) for line in prop.splitlines() if "=" in line)
    props.update(
        name=NAME,
        author=AUTHOR,
        susfsBase=base,
        description=f"Waiting for the first boot | {len(kmis)} kernel builds, {low} to {high} | SUSFS {base}",
    )
    return "".join(f"{k}={v}\n" for k, v in props.items())


def read_tree():
    return {p.name: p.read_bytes() for p in MODULE.iterdir() if p.is_file()}


def overlay(zip_path, sc_path):
    sources = overlay_sources()
    src = zipfile.ZipFile(zip_path)
    files = {i.filename: src.read(i) for i in src.infolist()}
    problems = contract(files) + syntax(sources)
    for name in ("provenance.json", "module.prop", "bin/susfs_insmod"):
        if name not in files:
            problems.append(f"the zip has no {name}")
    if not pathlib.Path(sc_path).is_file():
        problems.append(f"the probe binary {sc_path} does not exist")
    if problems:
        raise Reject(problems, files)

    probe = pathlib.Path(sc_path).read_bytes()
    provenance = json.loads(files["provenance.json"])
    provenance["build_workflow"] = BUILD_WORKFLOW
    # tools/pack_module.py names upstream's repository, but the commit it records is the one built here.
    repo, sha = os.environ.get("GITHUB_REPOSITORY"), provenance.get("github_sha")
    if repo and sha:
        provenance["source"] = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{repo}/tree/{sha}"
    provenance["assets_sha256"][pathlib.PurePosixPath(PROBE).name] = hashlib.sha256(probe).hexdigest()
    provenance["boot_loop_guard"] = {
        name: hashlib.sha256(data).hexdigest() for name, data in sorted(sources.items()) if name != INSTALLER
    }
    provenance["installer"] = {INSTALLER: hashlib.sha256(sources[INSTALLER]).hexdigest()}

    now = time.gmtime()[:6]
    tmp = pathlib.Path(zip_path).with_suffix(".tmp")
    with zipfile.ZipFile(tmp, "w", compression=zipfile.ZIP_DEFLATED) as out:
        for info in src.infolist():
            data = files[info.filename]
            if info.filename in RENAMED:
                info.filename = RENAMED[info.filename]
            elif info.filename == "provenance.json":
                data = (json.dumps(provenance, indent=2) + "\n").encode()
            elif info.filename == "module.prop":
                data = brand(data.decode(), provenance["supported_kmis"]).encode()
            out.writestr(info, data)
        entries = {WRAPPER: sources[WRAPPER], INSTALLER: sources[INSTALLER], PROBE: probe} | {
            ADDED[n]: sources[n] for n in ADDED}
        for name, data in entries.items():
            info = zipfile.ZipInfo(name, date_time=now)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            out.writestr(info, data)
    src.close()
    tmp.replace(zip_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="check the module directory, write nothing")
    ap.add_argument("--zip", help="the module zip to add the guard to, rewritten in place")
    ap.add_argument("--sc", help="the susfs_sc binary shipped as the probe")
    ap.add_argument("--rejects", default="pack-rejects", help="where the reasons go when the checks fail")
    args = ap.parse_args()
    if args.check == bool(args.zip) or (args.zip and not args.sc):
        ap.error("give --check, or --zip together with --sc")

    try:
        if args.check:
            files = read_tree()
            problems = contract(files) + syntax(overlay_sources())
            if problems:
                raise Reject(problems, files)
        else:
            overlay(args.zip, args.sc)
    except Reject as e:
        reject(e.problems, e.files, args.rejects)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
