#!/usr/bin/env python3
"""Resolve which KernelSU build of each fork the module is tested against, as JSON.

Usage: ksu_release.py [--channel stable|tip] [--pins PINS_JSON] [FORKS_JSON]

The forks come from ksud_forks.json. Nothing here names a version, tag or file, so a new release
is picked up like today's.

stable  The newest release that is neither a draft nor a prerelease, what GitHub serves as
        "latest". A fork that only publishes prereleases is tested at its newest one, and the
        note says so. The kernel module is built at the commit of the release tag. The manager
        is the first of these that exists:
          1. a spoofed APK attached to the release
          2. a spoofed manager artifact of the fork's CI at that commit, or a few commits ahead
             when the tag was not built, never past a uapi change
          3. the regular APK attached to the release
        A manager built far ahead of the module can report that the kernel needs an update,
        hence the limit in 2.
        A fork with an entry in ksu_pins.json is tested at that commit instead, for forks whose
        release lags their CI or that only tag prereleases. The pin names the commit and the
        version name and build number its manager reports, and counts only while:
          1. it is ahead of the newest release, so a pin never goes back past a release
          2. it is on the history of the fork's default branch
          3. the fork's CI still holds the spoofed manager built at exactly that commit
        A pin failing 1 or 3 is ignored and the note says why, one failing 2 stops the run. Pins
        are moved by hand after a passing run at the new commit.
tip     The head of the default branch, no manager. A canary that warns before a fork's next
        release breaks the module.

Prints [{"name", "repo", "lkm", "channel", "ref", "commit", "version", "manager": {"kind", ...},
"note"}]. manager.kind is release-spoofed, ci-spoofed, release or none. A pin's manager carries
"expect", the version name and build number its APK must report. lkm is false for a fork that
cannot build as a loadable module. A fork without any release has "commit": null and a note.
Needs the gh CLI, authenticated through GH_TOKEN.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO_URL = re.compile(r"github\.com[/:]([^/]+/[^/]+?)(?:\.git)?$")
SPOOFED = re.compile(r"spoof", re.I)
# Builds of a manager for a CPU or a debugging purpose that nobody installs on a phone under test.
UNWANTED_APK = re.compile(r"debug|armeabi|armv7|x86|riscv", re.I)
# Side products of a manager build that carry no APK.
UNWANTED_ARTIFACT = re.compile(r"mappings|gradle|debug", re.I)
UAPI = re.compile(r"(^|/)uapi/")
LOOK_AHEAD = 5
PIN_KEYS = ("commit", "versionName", "versionCode")


def gh(path):
    """The decoded answer of the GitHub API, or None for a 404."""
    done = subprocess.run(["gh", "api", path], capture_output=True, text=True, encoding="utf-8")
    if done.returncode == 0:
        return json.loads(done.stdout)
    if "HTTP 404" in done.stderr:
        return None
    sys.exit(f"gh api {path}: {done.stderr.strip()}")


def pick_apk(names):
    """The APK to install out of the ones a build offers, None when the choice is not clear."""
    wanted = [n for n in names if not UNWANTED_APK.search(n)]
    for preference in ("universal", "arm64"):
        by_abi = [n for n in wanted if preference in n.lower()]
        if by_abi:
            wanted = by_abi
            break
    return wanted[0] if len(wanted) == 1 else None


def release_apk(release, spoofed):
    apks = [a for a in release["assets"]
            if a["name"].endswith(".apk") and bool(SPOOFED.search(a["name"])) == spoofed]
    chosen = pick_apk([a["name"] for a in apks])
    return next((a for a in apks if a["name"] == chosen), None)


def changes_uapi(slug, sha):
    files = gh(f"repos/{slug}/commits/{sha}")["files"]
    return any(UAPI.search(f["filename"]) for f in files)


def commits_from(slug, branch, commit, look_ahead):
    """The commit, then the few that follow it on the branch, stopping short of a uapi change."""
    yield commit
    ahead = gh(f"repos/{slug}/compare/{commit}...{branch}") if look_ahead else None
    for entry in (ahead["commits"] if ahead and ahead["status"] == "ahead" else [])[:look_ahead]:
        if changes_uapi(slug, entry["sha"]):
            return
        yield entry["sha"]


def ci_manager(slug, branch, commit, look_ahead=LOOK_AHEAD):
    workflows = [w for w in gh(f"repos/{slug}/actions/workflows?per_page=100")["workflows"]
                 if "manager" in w["path"].lower() and w["state"] == "active"]
    for sha in commits_from(slug, branch, commit, look_ahead):
        for workflow in workflows:
            runs = gh(f"repos/{slug}/actions/workflows/{workflow['id']}/runs"
                      f"?head_sha={sha}&status=success&per_page=1")["workflow_runs"]
            if not runs:
                continue
            artifacts = gh(f"repos/{slug}/actions/runs/{runs[0]['id']}/artifacts?per_page=100")["artifacts"]
            usable = [a for a in artifacts if SPOOFED.search(a["name"])
                      and not UNWANTED_ARTIFACT.search(a["name"]) and not a["expired"]]
            if len(usable) == 1:
                return {"kind": "ci-spoofed", "name": usable[0]["name"], "run": runs[0]["id"],
                        "artifact": usable[0]["id"], "commit": sha}
    return None


def default_branch(slug):
    """The default branch. A fork that was renamed or deleted stops the run, it is not a fork without releases."""
    repo = gh(f"repos/{slug}")
    if repo is None:
        sys.exit(f"{slug}: no such repository, ksud_forks.json is out of date")
    return repo["default_branch"]


def newest_release(slug):
    """The newest release that is not a draft, for a fork that publishes prereleases only."""
    return next((r for r in gh(f"repos/{slug}/releases?per_page=10") if not r["draft"]), None)


def load_pins(path):
    """The pins by fork name, none when the file does not exist."""
    if not path.exists():
        return {}
    pins = json.loads(path.read_text(encoding="utf-8"))
    for name, pin in pins.items():
        missing = [key for key in PIN_KEYS if key not in pin]
        if missing:
            sys.exit(f"{path.name}: the pin of {name} lacks {', '.join(missing)}")
    return pins


def compare_status(slug, base, head):
    answer = gh(f"repos/{slug}/compare/{base}...{head}")
    if answer is None:
        sys.exit(f"{slug}: cannot compare {base[:10]} with {head[:10]}, one of them does not exist")
    return answer["status"]


def pinned(slug, branch, release_commit, pin):
    """The manager of a pin and None, or None and the reason the pin does not count."""
    commit = pin["commit"]
    status = compare_status(slug, release_commit, commit)
    if status == "diverged":
        sys.exit(f"{slug}: the pin {commit[:10]} is not built on the release {release_commit[:10]}, "
                 "the history of the fork was rewritten or the pin is wrong")
    if status != "ahead":
        return None, "the pin is not ahead of the release and is ignored"
    if compare_status(slug, commit, branch) not in ("ahead", "identical"):
        sys.exit(f"{slug}: the pin {commit[:10]} is not on the history of {branch}")
    manager = ci_manager(slug, branch, commit, look_ahead=0)
    if manager is None:
        return None, "the CI of the fork holds no spoofed manager of the pin any more, the pin is ignored"
    manager["expect"] = {"versionName": pin["versionName"], "versionCode": pin["versionCode"]}
    return manager, None


def stable(slug, pin):
    branch = default_branch(slug)
    release = gh(f"repos/{slug}/releases/latest")
    notes = []
    if release is None:
        release = newest_release(slug)
        if release is None:
            return None, None, None, {"kind": "none"}, "the fork has no release"
        notes.append("no stable release, the newest prerelease is used")
    tag = release["tag_name"]
    commit = gh(f"repos/{slug}/commits/{tag}")["sha"]

    if pin:
        manager, why = pinned(slug, branch, commit, pin)
        if manager:
            return (branch, f"{pin['versionName']} build {pin['versionCode']}", pin["commit"], manager,
                    f"pinned, ahead of {tag}")
        notes.append(why)

    spoofed = release_apk(release, True)
    if spoofed:
        manager = {"kind": "release-spoofed", "name": spoofed["name"], "url": spoofed["browser_download_url"],
                   "digest": spoofed.get("digest")}
    else:
        manager = ci_manager(slug, branch, commit)
    if manager is None:
        regular = release_apk(release, False)
        if regular:
            manager = {"kind": "release", "name": regular["name"], "url": regular["browser_download_url"],
                       "digest": regular.get("digest")}
            notes.append("no spoofed manager, the regular one is used")
        else:
            manager = {"kind": "none"}
            notes.append("the release has no usable manager APK")
    return tag, tag, commit, manager, ", ".join(notes) or None


def tip(slug):
    branch = default_branch(slug)
    commit = gh(f"repos/{slug}/commits/{branch}")["sha"]
    return branch, branch, commit, {"kind": "none"}, None


def resolve(fork, channel, pins):
    found = REPO_URL.search(fork["repo"])
    if not found:
        sys.exit(f"{fork['name']}: {fork['repo']} is not a GitHub repository")
    slug = found[1]
    if channel == "stable":
        ref, version, commit, manager, note = stable(slug, pins.get(fork["name"]))
    else:
        ref, version, commit, manager, note = tip(slug)
    return {"name": fork["name"], "repo": slug, "lkm": fork.get("lkm", True), "channel": channel,
            "ref": ref, "commit": commit, "version": version, "manager": manager, "note": note}


def main():
    args = argparse.ArgumentParser()
    args.add_argument("forks", nargs="?", type=pathlib.Path, default=HERE / "ksud_forks.json")
    args.add_argument("--channel", choices=("stable", "tip"), default="stable")
    args.add_argument("--pins", type=pathlib.Path, default=HERE / "ksu_pins.json")
    args = args.parse_args()

    forks = json.loads(args.forks.read_text(encoding="utf-8"))
    if not forks:
        sys.exit(f"{args.forks} lists no forks")
    pins = load_pins(args.pins)
    unknown = sorted(set(pins) - {f["name"] for f in forks})
    if unknown:
        sys.exit(f"{args.pins.name} pins {', '.join(unknown)}, which {args.forks.name} does not list")
    print(json.dumps([resolve(f, args.channel, pins) for f in forks], separators=(",", ":")))


if __name__ == "__main__":
    main()
