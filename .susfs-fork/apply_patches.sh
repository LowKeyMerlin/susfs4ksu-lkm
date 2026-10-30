#!/bin/sh
# Apply .susfs-fork/patches/*.patch in name order. This changes upstream files without editing
# them, so a sync cannot conflict.
#
# A patch that fails to apply fails the build. The patch, its target files and the rejected hunks
# are left in patch-rejects, which the workflow uploads.
set -eu

dir=.susfs-fork/patches
out=patch-rejects

[ -d "$dir" ] || exit 0
git config --global --add safe.directory "$PWD"

for p in "$dir"/*.patch; do
	[ -e "$p" ] || exit 0

	if git apply --check "$p"; then
		git apply "$p"
		echo "applied $p"
		continue
	fi

	mkdir -p "$out/original"
	cp "$p" "$out/"
	git apply --numstat "$p" | cut -f3 | while read -r f; do
		if [ -f "$f" ]; then
			cp --parents "$f" "$out/original/"
		fi
	done
	git apply --reject "$p" || true
	find . -name '*.rej' -not -path './.git/*' | while read -r f; do
		cp --parents "$f" "$out/"
	done
	echo "::error::$p does not apply"
	exit 1
done

# Guard for 0001: a kprobe handler that skips the function it probed must clear BTYPE through
# susfs_probe_return(), not assign regs->pc directly - a direct assignment traps on a BTI kernel
# (0001-clear-btype-when-a-probe-skips-a-call.patch).
if grep -n 'regs->pc[[:space:]]*=[[:space:]]*regs->regs\[30\]' kernel/*.c; then
	echo "::error::a kprobe handler sets regs->pc directly - use susfs_probe_return() instead (see patch 0001)"
	exit 1
fi
