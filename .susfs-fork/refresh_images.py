#!/usr/bin/env python3
"""Move .susfs-fork/images.json to the newest dated ddk-min image of every build variant.

Usage: refresh_images.py

The variants come from the matrix of upstream's build-ddk.yml. A variant moves only to a newer
dated tag than its current pin, and the pin always carries the digest the registry reports for the
tag. Nothing is written when every variant is current.
"""
import json
import pathlib
import re
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".github/workflows/build-ddk.yml"
IMAGES = pathlib.Path(__file__).resolve().parent / "images.json"
REPO = "ylarod/ddk-min"
REGISTRY = "https://ghcr.io"
MANIFESTS = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


class Registry:
    def __init__(self):
        url = f"{REGISTRY}/token?service=ghcr.io&scope=repository:{REPO}:pull"
        with urllib.request.urlopen(url, timeout=30) as r:
            self.auth = {"Authorization": "Bearer " + json.load(r)["token"]}

    def open(self, url, method="GET", accept=None):
        headers = dict(self.auth, **({"Accept": accept} if accept else {}))
        return urllib.request.urlopen(urllib.request.Request(url, headers=headers, method=method), timeout=30)

    def tags(self):
        found, url = [], f"{REGISTRY}/v2/{REPO}/tags/list?n=1000"
        while url:
            with self.open(url) as r:
                found += json.load(r)["tags"]
                nxt = re.search(r'<([^>]+)>;\s*rel="next"', r.headers.get("Link", ""))
            url = REGISTRY + nxt[1] if nxt else None
        return found

    def digest(self, tag):
        with self.open(f"{REGISTRY}/v2/{REPO}/manifests/{tag}", "HEAD", MANIFESTS) as r:
            return r.headers["Docker-Content-Digest"]


def matrix(text):
    return re.findall(r'\{\s*variant:\s*([^,\s]+)\s*,\s*image:\s*"([^"]+)"', text)


def date_of(image):
    m = re.search(r":[^@]*-(\d{8})@", image)
    return m[1] if m else ""


def refresh():
    pins = json.loads(IMAGES.read_text(encoding="utf-8")) if IMAGES.exists() else {}
    if not isinstance(pins, dict) or not all(isinstance(v, str) for v in pins.values()):
        print("refresh_images: images.json is not an object of variant to image", file=sys.stderr)
        return 1
    entries = matrix(SOURCE.read_text(encoding="utf-8"))
    if not entries:
        print("refresh_images: no matrix entries found in build-ddk.yml", file=sys.stderr)
        return 1

    registry = Registry()
    tags = registry.tags()
    out, moved = dict(pins), []
    for variant, upstream in entries:
        current = pins.get(variant, upstream)
        dated = sorted(t for t in tags if re.fullmatch(re.escape(variant) + r"-\d{8}", t))
        if not dated:
            print(f"refresh_images: no dated tag for {variant} in the registry", file=sys.stderr)
            return 1
        if dated[-1][-8:] <= date_of(current):
            continue
        digest = registry.digest(dated[-1])
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            print(f"refresh_images: odd digest for {dated[-1]}: {digest}", file=sys.stderr)
            return 1
        out[variant] = f"ghcr.io/{REPO}:{dated[-1]}@{digest}"
        moved.append(f"{variant}: {date_of(current) or current} -> {dated[-1][-8:]}")

    if not moved:
        print("every image is current")
        return 0
    order = [v for v, _ in entries] + sorted(set(out) - {v for v, _ in entries})
    IMAGES.write_bytes((json.dumps({v: out[v] for v in order if v in out}, indent=2) + "\n").encode("utf-8"))
    print("\n".join(moved))
    return 0


def main():
    try:
        return refresh()
    except (OSError, KeyError, ValueError) as e:
        print(f"refresh_images: {type(e).__name__}: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
