#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Other modules have mounted their files by now, so the hide list can be applied.
MODDIR=${0%/*}

# The init.svc.adbd correction now lives in the event-driven watcher started from service.sh
# (susfs_propwait + adbd_guard.sh): init rewrites that property on every adbd transition, so it has
# to follow each change, not run once here.

/system/bin/sh "$MODDIR/hide_mounts.sh" apply
exec /system/bin/sh "$MODDIR/selinux_ctx.sh" apply
