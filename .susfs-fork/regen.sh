#!/bin/sh
# Regenerate susfs-build.yml and fold the change into the commit that added it, so the commit
# count stays the same however often upstream changes the build workflow.
#
# Needs a clean checkout of susfs. On failure the branch is restored.
set -eu

file=.github/workflows/susfs-build.yml

if ! git diff --quiet HEAD; then
	echo "regen: the working tree is not clean" >&2
	exit 1
fi

orig="$(git rev-parse HEAD)"
restore() {
	if [ "$?" -ne 0 ]; then
		git rebase --abort 2>/dev/null || true
		git reset --quiet --hard "$orig"
	fi
}
trap restore EXIT

python3 .susfs-fork/gen_build.py

if git diff --quiet -- "$file"; then
	exit 0
fi

base="$(git log --diff-filter=A --format=%H -1 -- "$file")"
if [ -z "$base" ]; then
	echo "regen: no commit in this branch adds $file" >&2
	exit 1
fi
git add "$file"
git commit --quiet --fixup "$base"
GIT_SEQUENCE_EDITOR=true git rebase --quiet --interactive --autosquash "$base^"
