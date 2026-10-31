#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Other modules have mounted their files by now, so the hide list can be applied.
MODDIR=${0%/*}
/system/bin/sh "$MODDIR/hide_mounts.sh" apply
exec /system/bin/sh "$MODDIR/selinux_ctx.sh" apply
