#!/usr/bin/env python3
"""Report KernelSU forks whose ksud no longer runs a module as this module expects.

Usage: ksud_contract.py [FORKS_JSON] [--src DIR]

FORKS_JSON lists the forks, default ksud_forks.json next to this file. Each fork's
userspace/ksud/src is cloned (shallow, sparse) unless --src points at a directory with one folder
of sources per fork name.

The module relies on ksud doing this:
  - skip a module holding a file named disable, remove one holding a file named remove. The
    bootloop guard disables the module this way.
  - run the scripts of a stage as <stage>.sh, so post-fs-data.sh and service.sh run.
  - run the post-fs-data and service stages.

Forks move files around, so each check searches every .rs file under ksud/src. The markdown
report stays empty when every fork still behaves like that. A fork that cannot be fetched exits 1,
so a network failure does not read as drift.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SRC = "userspace/ksud/src"

# An opening brace followed by a continue before the block closes. A quoted string counts as one
# unit, so the {} of a log message does not end the block.
IF_BLOCK_CONTINUES = r'\{(?:[^{}"]|"[^"]*")*?\bcontinue\b'

CHECKS = [
    (r'DISABLE_FILE_NAME\s*:\s*&str\s*=\s*"disable"', "a module is disabled by a file named disable"),
    (r'REMOVE_FILE_NAME\s*:\s*&str\s*=\s*"remove"', "a module is removed by a file named remove"),
    (rf"DISABLE_FILE_NAME\s*\)\s*\.exists\(\)\s*{IF_BLOCK_CONTINUES}", "a module with a disable file is skipped"),
    (rf"REMOVE_FILE_NAME\s*\)\s*\.exists\(\)\s*{IF_BLOCK_CONTINUES}", "a module with a remove file is skipped"),
    (r'\.join\(\s*format!\(\s*"\{stage\}\.sh"\s*\)\s*\)', "the scripts of a stage are named <stage>.sh"),
    (r'exec_stage_script\(\s*"post-fs-data"', "the post-fs-data stage runs the module scripts"),
    (r'(?s)fn on_services\b.{0,800}?run_stage\(\s*"service"', "the service stage runs the module scripts"),
]


def fetch(repo, dest):
    clone = ["git", "clone", "--quiet", "--depth", "1", "--filter=blob:none", "--sparse", repo, str(dest)]
    done = subprocess.run(clone, capture_output=True, text=True)
    if done.returncode == 0:
        done = subprocess.run(["git", "-C", str(dest), "sparse-checkout", "set", SRC],
                              capture_output=True, text=True)
    if done.returncode:
        sys.exit(f"{repo}: {done.stderr.strip()}")


def problems(src):
    sources = [p.read_text(encoding="utf-8", errors="replace") for p in sorted(src.rglob("*.rs"))]
    if not sources:
        return [f"`{SRC}` holds no Rust sources, the layout of ksud changed"]
    return [f"not found in any source: {what}" for pattern, what in CHECKS
            if not any(re.search(pattern, text) for text in sources)]


def main():
    args = argparse.ArgumentParser()
    args.add_argument("forks", nargs="?", type=pathlib.Path, default=HERE / "ksud_forks.json")
    args.add_argument("--src", type=pathlib.Path)
    args = args.parse_args()

    forks = json.loads(args.forks.read_text(encoding="utf-8"))
    if not forks:
        sys.exit(f"{args.forks} lists no forks")

    with tempfile.TemporaryDirectory() as tmp:
        root = args.src or pathlib.Path(tmp)
        report = []
        for fork in forks:
            if not args.src:
                fetch(fork["repo"], root / fork["name"])
            found = problems(root / fork["name"] / SRC)
            if found:
                report.append(f"### {fork['name']} ({fork['repo']})\n\n" + "\n".join(f"- {p}" for p in found))
        if report:
            print("\n\n".join(report))


if __name__ == "__main__":
    main()
