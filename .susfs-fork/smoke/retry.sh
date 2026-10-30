#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Run a command up to three times, for the network calls of the smoke test.
#
# Usage: retry.sh COMMAND [ARG ...]
#
# Exits 0 on the first success, 1 if the last try fails too.
set -u

[ "$#" -gt 0 ] || { echo "usage: retry.sh COMMAND [ARG ...]" >&2; exit 2; }

for attempt in 1 2 3; do
  if "$@"; then
    exit 0
  fi
  echo "retry.sh: $1 failed, attempt $attempt of 3" >&2
  if [ "$attempt" -lt 3 ]; then
    sleep $((attempt * 10))
  fi
done
exit 1
