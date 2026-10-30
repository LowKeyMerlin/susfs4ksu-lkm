#!/usr/bin/env python3
"""Report where upstream SUSFS and this module differ.

Usage: abi_drift.py UPSTREAM_CLONE [--kit DIR]

UPSTREAM_CLONE is a clone of upstream SUSFS with history. Every stable gki-androidN-X.Y branch is
read, the -dev branches are not. The markdown report stays empty when there is nothing to report.
It lists:

- commands and structs upstream defines and kernel/susfs_abi.h does not, and fields or constants
  whose type, size or value differ (abi_known.json holds the reviewed harmless ones);
- hook sites and changed files of the upstream kernel patch with no row in parity.json, and the
  rows that say the module lacks the behaviour;
- upstream commits to kernel_patches/ since the commit parity.json says was reviewed.

With --kit, a non-empty report also writes what is needed to port the gap: upstream
kernel_patches/ of every stable branch, and hits.txt with the lines mentioning each missing
command or struct.
"""
import argparse
import fnmatch
import io
import json
import pathlib
import re
import subprocess
import tarfile

OURS = pathlib.Path(__file__).resolve().parent.parent / "kernel" / "susfs_abi.h"
PARITY = pathlib.Path(__file__).resolve().parent / "parity.json"
# Differences that were looked at and are harmless, each with the reason.
KNOWN = pathlib.Path(__file__).resolve().parent / "abi_known.json"
DEF_H = "kernel_patches/include/linux/susfs_def.h"
MAIN_H = "kernel_patches/include/linux/susfs.h"
STABLE = re.compile(r"^origin/(gki-android\d+-\d+\.\d+)$")
# Kernel side bookkeeping, not part of the supercall ABI.
INTERNAL = re.compile(r"_h?list$")


def git(repo, *args):
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if done.returncode:
        raise SystemExit(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done.stdout


def grep(repo, ref, stem):
    done = subprocess.run(["git", "-C", str(repo), "grep", "-n", "-i", "-F", stem, ref, "--", "kernel_patches"],
                          capture_output=True, text=True)
    if done.returncode > 1:
        raise SystemExit(f"git grep failed in {ref}: {done.stderr.strip()}")
    return done.stdout.splitlines()


def export_kit(repo, branches, names, stems, dest):
    dest.mkdir(parents=True, exist_ok=True)
    hits = []
    for ref, name in zip(branches, names):
        archive = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", ref, "kernel_patches"],
                                 capture_output=True)
        if archive.returncode:
            raise SystemExit(f"git archive {ref}: {archive.stderr.decode().strip()}")
        with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tar:
            tar.extractall(dest / name, filter="data")
        for stem in stems:
            lines = grep(repo, ref, stem)
            if lines:
                hits.append(f"## {stem} in {name}\n\n" + "\n".join(lines) + "\n")
    (dest / "hits.txt").write_text("\n".join(hits), encoding="utf-8")


def where(found, every):
    return "all stable branches" if len(found) == len(every) else ", ".join(found)


def commands(text):
    return {m[1]: int(m[2], 16) for m in re.finditer(r"#define\s+(CMD_SUSFS_\w+)\s+(0x[0-9a-fA-F]+)", text)}


def field(decl):
    """name, and the declaration without the whitespace that does not matter: type and array size."""
    m = re.search(r"(\w+)\s*(\[[^\]]*\])?\s*$", decl.strip())
    typ = re.sub(r"\s+", " ", decl.strip()[: m.start()]).strip()
    size = re.sub(r"\s+", "", m[2] or "")
    return m[1], f"{typ} {m[1]}{size}"


def structs(text):
    out = {}
    for m in re.finditer(r"struct\s+(st_susfs_\w+)\s*\{(.*?)\};", text, re.S):
        if INTERNAL.search(m[1]):
            continue
        body = re.sub(r"/\*.*?\*/|//[^\n]*", "", m[2], flags=re.S)
        decls = [field(f) for f in body.split(";") if f.strip()]
        out[m[1]] = ([n for n, _ in decls], m[0], dict(decls))
    return out


def defines(text):
    """Object-like macros with a value, comments dropped and blanks removed."""
    out = {}
    for m in re.finditer(r"(?m)^#define\s+(\w+)[ \t]+(\S[^\n]*)$", text):
        value = re.sub(r"/\*.*?\*/|//.*$", "", m[2]).strip().replace(" ", "")
        if value and not value.endswith("\\"):
            out[m[1]] = value
    return out


def expand(text, defs):
    """text with the macros that have a value replaced by it, so 16 and SUSFS_MAX_VERSION_BUFSIZE agree."""
    for _ in range(3):
        text = re.sub(r"\b\w+\b", lambda m: defs.get(m[0], m[0]), text)
    return text


SITE_FILE = re.compile(r"^diff --git a/(\S+)")
SITE_CALL = re.compile(r"\b(susfs_\w+|SUSFS_IS_INODE_\w+)\b")


def hook_sites(patch):
    """The (file, call) pairs the kernel patch adds a call to, as the module has to answer them."""
    sites, current = set(), None
    for line in patch.splitlines():
        if m := SITE_FILE.match(line):
            current = m[1]
        elif current and line.startswith("+") and not line.startswith("+++"):
            sites.update((current, c[1]) for c in re.finditer(r"\b(susfs_\w+|SUSFS_IS_INODE_\w+)\s*\(", line))
    return sites


def parity_rows(path):
    """Each row of parity.json as the files and call names it covers, '*' standing for any suffix."""
    rows = json.loads(path.read_text(encoding="utf-8"))["sites"]
    out = []
    for row in rows:
        tokens = re.findall(r"[\w./*]+", row["upstream"])
        out.append(([t for t in tokens if "/" in t and not t.startswith(("susfs_", "SUSFS_"))],
                    [t for t in tokens if t.startswith(("susfs_", "SUSFS_"))]))
    return out


def patched_files(patch):
    """Every file the kernel patch changes, also those whose hook is not a susfs_ call."""
    return set(SITE_FILE.findall(patch))


def covered_file(file, rows):
    return any(file in files for files, _ in rows)


def covered(site, rows):
    file, call = site
    return any(file in files and any(fnmatch.fnmatchcase(call, pat) for pat in calls) for files, calls in rows)


def main():
    args = argparse.ArgumentParser()
    args.add_argument("upstream", type=pathlib.Path)
    args.add_argument("--kit", type=pathlib.Path)
    args = args.parse_args()
    up = args.upstream
    branches = sorted(b for b in git(up, "for-each-ref", "--format=%(refname:short)", "refs/remotes").split()
                      if STABLE.match(b))
    if not branches:
        raise SystemExit("no stable gki branch found in the upstream clone")

    names = [STABLE.match(b)[1] for b in branches]
    ours = OURS.read_text(encoding="utf-8")
    our_cmds, our_structs = commands(ours), structs(ours)

    our_defs = defines(ours)
    known = json.loads(KNOWN.read_text(encoding="utf-8")) if KNOWN.exists() else {}
    known_fields = known.get("struct_fields", {})
    parity = json.loads(PARITY.read_text(encoding="utf-8"))
    rows = parity_rows(PARITY)

    missing_cmds, changed_cmds, missing_structs, changed_structs = {}, {}, {}, {}
    retyped, redefined, unmapped, new_commits = {}, {}, {}, {}
    for b, name in zip(branches, names):
        def_h = git(up, "show", f"{b}:{DEF_H}")
        main_h = git(up, "show", f"{b}:{MAIN_H}")
        cmds, strs = commands(def_h), structs(main_h)
        if not cmds or not strs:
            raise SystemExit(f"{name}: no commands or structs parsed, did the headers move?")
        up_defs = {**defines(def_h), **defines(main_h)}
        for c, v in cmds.items():
            if c not in our_cmds:
                missing_cmds.setdefault(c, (v, []))[1].append(name)
            elif our_cmds[c] != v:
                changed_cmds.setdefault(c, (v, our_cmds[c], []))[2].append(name)
        for s, (fields, text, decls) in strs.items():
            if s not in our_structs:
                missing_structs.setdefault(s, (text, []))[1].append(name)
            elif our_structs[s][0] != fields:
                changed_structs.setdefault(s, (fields, our_structs[s][0], []))[2].append(name)
            else:
                for f, decl in decls.items():
                    mine = our_structs[s][2][f]
                    if expand(mine, our_defs) != expand(decl, up_defs) and f"{s}.{f}" not in known_fields:
                        retyped.setdefault((s, f, decl, mine), []).append(name)
        for d, v in up_defs.items():
            if d in our_defs and our_defs[d] != v and d not in known.get("defines", {}):
                redefined.setdefault((d, v, our_defs[d]), []).append(name)

        patch = git(up, "show", f"{b}:kernel_patches/50_add_susfs_in_{name}.patch")
        for site in sorted(hook_sites(patch)):
            if not covered(site, rows):
                unmapped.setdefault(site, []).append(name)
        for file in sorted(patched_files(patch)):
            if not covered_file(file, rows):
                unmapped.setdefault((file, "the file as a whole"), []).append(name)

        seen = parity["reviewed"].get(name)
        if seen:
            log = git(up, "log", "--format=%h %s", f"{seen}..{b}", "--", "kernel_patches").splitlines()
            if log:
                new_commits[name] = log

    out = []
    if missing_cmds:
        out.append("### Commands not implemented\n")
        out += [f"- `{c}` = `0x{v:x}` ({where(bs, names)})" for c, (v, bs) in sorted(missing_cmds.items())]
    if changed_cmds:
        out.append("\n### Commands with a different ID\n")
        out += [f"- `{c}` is `0x{v:x}` upstream and `0x{o:x}` here ({where(bs, names)})"
                for c, (v, o, bs) in sorted(changed_cmds.items())]
    if missing_structs:
        out.append("\n### Structs not defined\n")
        for s, (text, bs) in sorted(missing_structs.items()):
            out.append(f"`{s}` ({where(bs, names)})\n\n```c\n{text}\n```\n")
    if changed_structs:
        out.append("\n### Structs with different fields\n")
        out += [f"- `{s}` has {fields} upstream and {o} here ({where(bs, names)})"
                for s, (fields, o, bs) in sorted(changed_structs.items())]
    if retyped:
        out.append("\n### Struct fields with another type or size\n")
        out += [f"- `{s}.{f}` is `{up_decl}` upstream and `{mine}` here ({where(bs, names)})"
                for (s, f, up_decl, mine), bs in sorted(retyped.items())]
    if redefined:
        out.append("\n### Constants with a different value\n")
        out += [f"- `{d}` is `{v}` upstream and `{o}` here ({where(bs, names)})"
                for (d, v, o), bs in sorted(redefined.items())]
    gaps = [r["upstream"] for r in parity["sites"] if r["status"] == "missing"]
    if gaps:
        out.append("\n### Upstream behaviour the module does not have (status missing in parity.json)\n")
        out += [f"- {g}" for g in gaps]
    if unmapped:
        out.append("\n### Upstream hook sites with no row in .susfs-fork/parity.json\n")
        out += [f"- `{file}`: `{call}` ({where(bs, names)})" for (file, call), bs in sorted(unmapped.items())]
    if new_commits:
        out.append("\n### Upstream commits touching kernel_patches since the last review\n")
        out.append("Triage each one as ported or not applicable, then move `reviewed` in parity.json.\n")
        for name, log in new_commits.items():
            out.append(f"{name}: {len(log)} commits\n")
            out += [f"- `{line.split(' ', 1)[0]}` {line.split(' ', 1)[1]}" for line in log[:25]]
            if len(log) > 25:
                out.append(f"- and {len(log) - 25} more")
            out.append("")
    if out:
        print("\n".join(out).strip())
        if args.kit:
            stems = sorted({c.removeprefix("CMD_").lower() for c in missing_cmds}
                           | {s.removeprefix("st_") for s in missing_structs})
            export_kit(up, branches, names, stems, args.kit)


if __name__ == "__main__":
    main()
