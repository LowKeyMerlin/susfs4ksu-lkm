#!/usr/bin/env python3
"""Print the smoke-test matrix of one module build as JSON.

Usage: plan.py MODULE_DIR [GKI_JSON]

MODULE_DIR holds the unpacked module zip. Its provenance.json lists the kernels the zip covers
(supported_kmis) and the toolchain images the .ko files were built in (ddk_images). Each kernel
is tested in the image it was built against, so kernel and module agree on the ABI. Nothing here
names a kernel or image, a new one in the build is picked up on its own.

GKI_JSON is the gki_latest.py output. With it every kernel is also tested on Google's release
build, which is what a device runs.

Each entry has a key ("ddk-android15-6.6", "gki-android15-6.6"), the kernel it is for (variant),
where it comes from (source), what to boot (kernel: an image reference for ddk, a download URL
for gki) and the release (ref, empty for ddk).

Anything that does not add up is an error and prints nothing: a kernel without an image or its
.ko, a kernel Google has no release of, or no kernels at all. A test that quietly covers less
than the build is worse than none.
"""
import json
import pathlib
import re
import sys

IMAGE_KMI = re.compile(r":(android\d+-\d+\.\d+)-[^@:]+@")


def toolchain_images(prov):
    images = {}
    for ref in prov.get("ddk_images") or []:
        m = IMAGE_KMI.search(ref)
        if not m:
            raise SystemExit(f"cannot tell which kernel the image {ref} is for")
        if m[1] in images:
            raise SystemExit(f"two images for {m[1]}")
        images[m[1]] = ref
    return images


def google_releases(entries):
    releases = {}
    for entry in entries:
        if entry["variant"] in releases:
            raise SystemExit(f"two Google releases for {entry['variant']}")
        releases[entry["variant"]] = entry
    return releases


def plan(module, gki=None):
    found = sorted(module.rglob("provenance.json"))
    if len(found) != 1:
        raise SystemExit(f"expected one provenance.json under {module}, found {len(found)}")
    root = found[0].parent
    prov = json.loads(found[0].read_text(encoding="utf-8"))

    kmis = sorted(prov.get("supported_kmis") or [])
    images = toolchain_images(prov)
    releases = google_releases(gki) if gki is not None else {}

    problems = []
    if not kmis:
        problems.append("provenance.json lists no supported_kmis")
    for kmi in kmis:
        if kmi not in images:
            problems.append(f"{kmi} has no image in ddk_images")
        if not (root / "lib" / f"susfs_guard_lkm-{kmi}.ko").is_file():
            problems.append(f"{kmi} has no .ko in the zip")
        if gki is not None and kmi not in releases:
            problems.append(f"{kmi} has no Google release")
    for kmi in sorted(set(releases) - set(kmis)):
        problems.append(f"{kmi} has a Google release but is not in supported_kmis")
    if problems:
        raise SystemExit("\n".join(problems))

    include = [
        {"key": f"ddk-{kmi}", "variant": kmi, "source": "ddk", "kernel": images[kmi], "ref": ""}
        for kmi in kmis
    ]
    include += [
        {"key": f"gki-{kmi}", "variant": kmi, "source": "gki", "kernel": releases[kmi]["image"], "ref": releases[kmi]["tag"]}
        for kmi in kmis
        if gki is not None
    ]
    return {"include": include}


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    gki = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")) if len(sys.argv) == 3 else None
    print(json.dumps(plan(pathlib.Path(sys.argv[1]), gki), separators=(",", ":")))


if __name__ == "__main__":
    main()
