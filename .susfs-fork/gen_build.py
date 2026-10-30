#!/usr/bin/env python3
"""Generate .github/workflows/susfs-build.yml from upstream's build-ddk.yml.

Usage: gen_build.py [--check]

The edits below are everything the susfs branch changes in the build. A strict edit that no
longer finds its anchor in build-ddk.yml stops the run with its name, which means upstream
changed that part of the workflow and the edit needs a look. With --check nothing is written
and the exit status says whether the committed file is current.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".github/workflows/build-ddk.yml"
TARGET = ROOT / ".github/workflows/susfs-build.yml"
IMAGES = pathlib.Path(__file__).resolve().parent / "images.json"
NAME = "build-lkm-susfs"
# Run name in the workflow list: the given title, else what started the run.
RUN_TITLE = (
    "${{ inputs.title || (github.event_name == 'pull_request' && format('PR #{0} {1}', "
    "github.event.pull_request.number, github.event.pull_request.title)) || "
    "format('{0} on {1}', github.event_name, github.ref_name) }}"
)
IMAGE = re.compile(r"ghcr\.io/ylarod/ddk-min:[^@\s]+@sha256:[0-9a-f]{64}")


class Reject(Exception):
    pass


def once(text, old, new, what):
    if text.count(old) != 1:
        raise Reject(f"{what}: expected one match, found {text.count(old)}")
    return text.replace(old, new)


def header(text):
    text, n = re.subn(
        r"^name: [^\n]*\n",
        "# Generated from build-ddk.yml by .susfs-fork/gen_build.py, change the generator and not this file.\n"
        "# The original is left untouched and disabled in the repository settings, so syncing it from\n"
        "# upstream cannot conflict with this file.\n"
        f"name: {NAME}\n"
        f"run-name: \"{NAME}: {RUN_TITLE}\"\n", text, count=1, flags=re.M)
    if n != 1:
        raise Reject("name: no name line")
    return text


def triggers(text):
    # susfs-pipeline.yml calls the build and decides when it runs. This file references no secret.
    text, n = re.subn(
        r"^on:\n.*?\n  workflow_dispatch:",
        "on:\n"
        "  workflow_call:\n"
        "  workflow_dispatch:\n"
        "    inputs:\n"
        "      title:\n"
        "        description: Name for this run in the workflow list, a default is used when empty\n"
        "        required: false", text, count=1, flags=re.S | re.M)
    if n != 1:
        raise Reject("triggers: no on block ending in workflow_dispatch")
    return text


def drop_concurrency(text):
    # Called from the pipeline, github.workflow is the pipeline's name, so this group would be the
    # pipeline's own and the build would wait on or cancel its caller. The pipeline has the group.
    text, n = re.subn(r"^concurrency:\n(?:  [^\n]*\n)+\n?", "", text, count=1, flags=re.M)
    if n != 1:
        raise Reject("concurrency: no top-level concurrency block")
    return text


def self_reference(text):
    old = ".github/workflows/build-ddk.yml"
    if old not in text:
        raise Reject("self reference: the packing job no longer reads the workflow file")
    return text.replace(old, ".github/workflows/susfs-build.yml")


def drop_probe_uploads(text):
    # Only the module zip is published. The probe tools are still built as a compile check.
    return re.sub(
        r"      - name: Upload [^\n]*\n        uses: actions/upload-artifact@v\d+\n        with:\n"
        r"          name: susfs_[a-z_]+\n          path: /tmp/(?!susfs_insmod\n)[a-z_]+\n"
        r"          if-no-files-found: error\n\n", "", text)


def short_retention(text):
    for path in ("kernel/susfs_guard_lkm.ko", "/tmp/susfs_insmod"):
        old = f"          path: {path}\n          if-no-files-found: error\n"
        text = once(text, old, old + "          retention-days: 1\n", f"retention: no upload of {path}")
    return text


def ship_probe(text):
    # The bootloop guard probes SUSFS with the supercall client, so it travels with the loader.
    text = once(
        text,
        "      - name: Upload module loader\n",
        "      - name: Upload module loader and probe\n",
        "probe: no loader upload step")
    return once(
        text,
        "          path: /tmp/susfs_insmod\n          if-no-files-found: error\n          retention-days: 1\n",
        "          path: |\n            /tmp/susfs_insmod\n            /tmp/susfs_sc\n"
        "          if-no-files-found: error\n          retention-days: 1\n",
        "probe: loader upload path")


def patch_steps(text):
    step = (
        "      - name: Checkout module\n        uses: actions/checkout@v4\n"
        "\n"
        "      - name: Apply the susfs patches\n"
        "        run: sh .susfs-fork/apply_patches.sh\n"
        "\n"
        "      - name: Upload the patch rejects\n"
        "        if: failure()\n"
        "        uses: actions/upload-artifact@v7\n"
        "        with:\n"
        "          name: patch-rejects-${{ github.job }}-${{ matrix.variant || 'default' }}\n"
        "          path: patch-rejects\n"
        "          if-no-files-found: ignore\n")
    old = "      - name: Checkout module\n        uses: actions/checkout@v4\n"
    if old not in text:
        raise Reject("patches: no Checkout module step")
    return text.replace(old, step)


def packing_job(text):
    text = once(
        text,
        "      actions: read\n    steps:\n      - uses: actions/checkout@v4\n",
        "      actions: write\n    steps:\n"
        "      # Full history and tags, git describe below needs them.\n"
        "      - uses: actions/checkout@v4\n        with:\n          fetch-depth: 0\n",
        "packing job: permissions and checkout")
    text = once(
        text,
        "          if len(images) != 8:\n"
        '              raise SystemExit(f"expected 8 digest-pinned DDK images, found {len(images)}")\n',
        "          # One pinned image per matrix entry, however many entries there are.\n"
        '          variants = re.findall(r"\\{\\s*variant:\\s*([^,\\s]+)\\s*,\\s*image:", text)\n'
        "          if not variants or len(images) != len(variants):\n"
        '              raise SystemExit(f"{len(variants)} matrix variants but {len(images)} pinned DDK images")\n',
        "packing job: image count")
    start = text.find("      # The tag carries the ref and the commit")
    end = text.find("      - name: Upload the flashable module")
    if start < 0 or end < start:
        raise Reject("packing job: pack and upload steps not found")
    return text[:start] + PACK_AND_UPLOAD + text[end:].split("          if-no-files-found: error\n", 1)[1]


PACK_AND_UPLOAD = '''\
      # The fork does not keep upstream's tags, so they would not show on its tags page. They are
      # read from the parent into this runner's clone, only to name the zip below.
      - name: Fetch the upstream tags
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          parent="$(gh api "repos/$GITHUB_REPOSITORY" --jq '.parent.full_name // empty')"
          if [ -n "$parent" ]; then
            git fetch --quiet "https://github.com/$parent.git" 'refs/tags/*:refs/tags/*'
          fi

      - name: Pack the module
        id: pack
        run: |
          set -euo pipefail
          # Version the module by the nearest upstream release tag, then the commit. Fall back to
          # the SUSFS version in the ABI header when no tag is reachable.
          base="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
          if [ -z "$base" ]; then
            base="$(sed -n 's/^#define SUSFS_VERSION_STR[[:space:]]*"\\(.*\\)".*/\\1/p' kernel/susfs_abi.h)"
            echo "::warning::no release tag reachable, using $base as the module version"
          fi
          [ -n "$base" ] || { echo "::error::no release tag and no SUSFS_VERSION_STR for the module version"; exit 1; }
          tag="${base}-$(git rev-parse --short HEAD)"
          zip="dist/ksu_susfs_lkm-module-$tag-arm64.zip"
          python tools/pack_module.py --ko-dir ko --insmod bin/susfs_insmod \\
            --tag "$tag" --sha "$GITHUB_SHA" --run-id "$GITHUB_RUN_ID" \\
            --ddk-images ddk-images.json \\
            --out "$zip"
          # Add the bootloop guard. Upstream's module scripts are not edited, see pack_extra.py.
          python .susfs-fork/pack_extra.py --zip "$zip" --sc bin/susfs_sc --rejects pack-rejects
          ls -l dist
          echo "zip=$zip" >> "$GITHUB_OUTPUT"

      - name: Upload the pack rejects
        if: failure()
        uses: actions/upload-artifact@v7
        with:
          name: pack-rejects
          path: pack-rejects
          if-no-files-found: ignore

      # The module is already a zip, so upload it as is instead of wrapping it in a second zip.
      # With archive: false the artifact takes the file's name. Needs upload-artifact v7.
      - name: Upload the flashable module
        uses: actions/upload-artifact@v7
        with:
          path: ${{ steps.pack.outputs.zip }}
          archive: false
          if-no-files-found: error

      # The per-variant .ko files and the loader only carry bytes between jobs. Delete them so the
      # zip is the only artifact of the run. If the delete fails they expire after a day.
      - name: Drop the intermediate artifacts
        continue-on-error: true
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          gh api --paginate "repos/${{ github.repository }}/actions/runs/${{ github.run_id }}/artifacts" \\
            --jq '.artifacts[] | select(.name == "susfs_insmod" or (.name | startswith("susfs_guard_lkm.ko-"))) | .id' |
          while read -r id; do
            gh api -X DELETE "repos/${{ github.repository }}/actions/artifacts/$id"
          done
'''


def images(text):
    try:
        pins = json.loads(IMAGES.read_text(encoding="utf-8")) if IMAGES.exists() else {}
    except ValueError as e:
        raise Reject(f"images: images.json is not valid JSON ({e})")
    if not isinstance(pins, dict):
        raise Reject("images: images.json is not an object of variant to image")
    entries = re.findall(r'\{\s*variant:\s*([^,\s]+)\s*,\s*image:\s*"([^"]+)"', text)
    for variant, old in entries:
        new = pins.get(variant)
        if new is None or new == old:
            continue
        if not isinstance(new, str) or not IMAGE.fullmatch(new):
            raise Reject(f"images: {variant} is not a digest pinned ddk-min reference")
        text = text.replace(old, new)
    for variant in sorted(set(pins) - {v for v, _ in entries}):
        print(f"gen_build: images.json has {variant}, which is not in the matrix", file=sys.stderr)
    return text


def release_note(text):
    # Optional, a rewording upstream makes this a no-op.
    return text.replace(
        "Attaching the same ZIP to a published release is still done by\n"
        "  # module-zip.yml, which calls the same tools/pack_module.py - one packer, two callers.",
        "Attaching the same ZIP to a published release is done by\n"
        "  # susfs-release.yml.")


# First major of each action that runs on Node 24. GitHub warns about Node 20 actions and upstream
# has not moved yet. Pins are only raised, so a newer one from upstream stays.
NODE24 = {"actions/checkout": 5, "actions/download-artifact": 7, "actions/setup-python": 6}


def node24(text):
    def raise_pin(m):
        wanted = NODE24.get(m[1])
        return m[0] if wanted is None or int(m[2]) >= wanted else f"{m[1]}@v{wanted}"

    return re.sub(r"(?<![\w./-])(actions/[\w-]+)@v(\d+)(?![\w.])", raise_pin, text)


EDITS = [header, triggers, drop_concurrency, self_reference, drop_probe_uploads, short_retention, ship_probe,
         patch_steps, packing_job, images, release_note, node24]


def generate():
    if not SOURCE.exists():
        raise Reject(f"source: {SOURCE.relative_to(ROOT)} does not exist")
    text = SOURCE.read_text(encoding="utf-8").replace("\r\n", "\n")
    for edit in EDITS:
        text = edit(text)
    return text


def main():
    try:
        out = generate()
    except Reject as e:
        print(f"gen_build: cannot apply {e}", file=sys.stderr)
        return 2
    if "--check" in sys.argv[1:]:
        current = TARGET.read_text(encoding="utf-8").replace("\r\n", "\n") if TARGET.exists() else ""
        if current != out:
            print("gen_build: susfs-build.yml is not what the generator produces, run .susfs-fork/regen.sh",
                  file=sys.stderr)
            return 1
        return 0
    TARGET.write_bytes(out.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
