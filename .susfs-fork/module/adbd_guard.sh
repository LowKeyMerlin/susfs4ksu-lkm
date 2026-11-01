#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Run by susfs_propwait on every init.svc.adbd change (and once when the watcher starts).
#
# Xiaomi's /system_ext/bin/adb_root runs adbd as root under its own init service, so the stock
# "adbd" service stays reported stopped while adbd is in fact live and still owns /dev/socket/adbd
# and the @jdwp-control listener.  Duck Detector reads that disagreement (a running adbd behind an
# init.svc.adbd that says stopped) as an ADB runtime contradiction.  init owns init.svc.adbd and
# rewrites it on every adbd service transition, which is why this has to run on each change and not
# once at boot.
#
# Guarded on adbd actually being up, so this only ever reports reality, never fakes a state adbd is
# not in: if adbd is genuinely stopped the property is left alone.
RESETPROP=/data/adb/ksu/bin/resetprop
[ -x "$RESETPROP" ] || RESETPROP=$(command -v resetprop 2>/dev/null)
[ -n "$RESETPROP" ] || exit 0

if pidof adbd >/dev/null 2>&1 && [ "$(getprop init.svc.adbd)" != running ]; then
	"$RESETPROP" init.svc.adbd running
fi
