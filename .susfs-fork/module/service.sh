#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Clear the bootloop guard marker once the boot has settled (see guard.sh).
MODDIR=${0%/*}
# shellcheck source=/dev/null
. "$MODDIR/guard.sh"
(guard_settle >>"$MODDIR/guard.log" 2>&1) &
