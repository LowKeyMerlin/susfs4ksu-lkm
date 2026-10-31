# SPDX-License-Identifier: GPL-2.0-only
"""Copy named files out of android.googlesource.com/kernel/common for each KMI branch.

Usage: fetch_kernel_files.py OUT_DIR PATH [PATH ...] [--kmi android15-6.6 ...]

Each branch is cloned with no blobs, one commit deep and no checkout, then only the requested
paths are fetched in one request and read from the object store (git show), so a few dozen
files cost a few megabytes and about a minute instead of a kernel tree. A sparse checkout is not used: it leaves the working tree empty
while exiting 0. A path a branch does not have is reported and skipped, which is the signal
that a file moved between KMIs. Files land in OUT_DIR/<kmi>/<path>.
"""
import argparse
import subprocess
import sys
import shutil
from pathlib import Path

COMMON_URL = "https://android.googlesource.com/kernel/common"
KMIS = [
    "android12-5.10",
    "android13-5.10",
    "android13-5.15",
    "android14-5.15",
    "android14-6.1",
    "android15-6.6",
    "android16-6.12",
    "android17-6.18",
]


def git(*args, cwd=None, timeout=900):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, timeout=timeout)


def fetch_branch(kmi, paths, out):
    # The blobless clone is kept under OUT_DIR/.clones: it holds trees only, so it is small, and
    # a later request for more files from the same branch costs seconds instead of a new clone.
    tmp = str(out / ".clones" / kmi)
    try:
        if not (Path(tmp) / ".git").is_dir():
            Path(tmp).parent.mkdir(parents=True, exist_ok=True)
            shutil.rmtree(tmp, ignore_errors=True)
            r = git(
                "clone",
                "--filter=blob:none",
                "--no-checkout",
                "--depth",
                "1",
                "--branch",
                kmi,
                COMMON_URL,
                tmp,
            )
            if r.returncode:
                print(
                    f"{kmi}: clone failed: {r.stderr.decode(errors='replace').strip()[:200]}"
                )
                shutil.rmtree(tmp, ignore_errors=True)
                return False
        # One fetch for every wanted blob: without it each git show below pulls its blob in a
        # separate round trip to the server, which is minutes per branch for a few dozen files.
        oids = {}
        for p in paths:
            r = git("rev-parse", f"HEAD:{p}", cwd=tmp)
            if r.returncode:
                print(f"{kmi}: no {p}")
            else:
                oids[p] = r.stdout.decode().strip()
        r = git(
            "fetch", "--no-tags", "--no-write-fetch-head", "--filter=blob:none",
            "origin", *sorted(set(oids.values())), cwd=tmp,
        )
        if r.returncode:
            print(f"{kmi}: blob fetch failed: {r.stderr.decode(errors='replace').strip()[:200]}")
            return False
        got = 0
        for p in oids:
            r = git("show", f"HEAD:{p}", cwd=tmp, timeout=300)
            if r.returncode:
                print(f"{kmi}: could not read {p}")
                return False
            dest = out / kmi / p
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(r.stdout)
            got += 1
        print(f"{kmi}: {got}/{len(paths)} files")
        return True
    except subprocess.TimeoutExpired:
        print(f"{kmi}: timed out")
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("paths", nargs="*")
    ap.add_argument(
        "--list", help="file with one path per line, added to PATH arguments"
    )
    ap.add_argument("--kmi", nargs="*", default=KMIS)
    args = ap.parse_args()
    paths = list(args.paths)
    if args.list:
        paths += [
            p.strip() for p in Path(args.list).read_text().splitlines() if p.strip()
        ]
    if not paths:
        ap.error("no paths given")
    out = Path(args.out)
    ok = [fetch_branch(k, paths, out) for k in args.kmi]
    sys.exit(0 if all(ok) else 1)


if __name__ == "__main__":
    main()
