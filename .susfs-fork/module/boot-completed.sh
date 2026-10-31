#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Other modules have mounted their files by now, so the hide list can be applied.
exec /system/bin/sh "${0%/*}/hide_mounts.sh" apply
