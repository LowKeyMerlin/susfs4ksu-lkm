#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Installation only: copy and wire the loader.  The KMI is deliberately not
# inspected or selected here - load.sh owns detection and the override, so an
# install can succeed even when the recovery/installer environment cannot read
# the target kernel's release string.
[ "$KSU" = true ] || abort "- KernelSU-compatible manager required."
[ "$ARCH" = arm64 ] || abort "- arm64 only."
INSTALLED=/data/adb/modules/susfs_guard_lkm
HOOK=/data/adb/post-fs-data.d/00-susfs-guard-lkm.sh
if { [ -e "$HOOK" ] || [ -L "$HOOK" ]; } && ! cmp -s "$HOOK" "$MODPATH/early-dispatch.sh"; then
  [ -f "$INSTALLED/early-dispatch.sh" ] && cmp -s "$HOOK" "$INSTALLED/early-dispatch.sh" || abort "- a different early dispatcher already exists at $HOOK."
fi
# Early load defaults on: a module that sends its SUSFS settings in post-fs-data (brene and similar
# config managers do) needs this module already up, or those settings reach a kernel with no susfs
# and are lost. A user who turned it off leaves an early_off marker that survives a module update.
if [ -f "$INSTALLED/early_off" ]; then
  touch "$MODPATH/early_off" || abort "- cannot preserve the early-load choice."
else
  touch "$MODPATH/early_load" || abort "- cannot enable early loading."
fi
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/susfs_insmod" 0 0 0755
for script in early-dispatch.sh load.sh post-fs-data.sh toggle.sh uninstall.sh; do
  set_perm "$MODPATH/$script" 0 0 0755
done
touch "$MODPATH/skip_mount"
mkdir -p /data/adb/post-fs-data.d || abort "- cannot create common script directory."
cp "$MODPATH/early-dispatch.sh" "$HOOK.tmp" || abort "- cannot stage early dispatcher."
chmod 0755 "$HOOK.tmp" || abort "- cannot set dispatcher permissions."
mv -f "$HOOK.tmp" "$HOOK" || abort "- cannot install early dispatcher."
ui_print "- susfs_guard_lkm (arm64)"
ui_print "- KMI is selected by the boot loader, not by this installer"
ui_print "- Loader only; no rules are applied"
ui_print "- Reboot to load; will not stack on an already-present susfs"
ui_print "- Early loading is on by default; turn it off in the WebUI if needed."
