#!/system/bin/sh
# Bootloop guard on an Android guest: the module's scripts with the guest's own getprop, date, boot
# id and kernel release. Only the loader is stubbed, so no module is inserted.
#
# Usage: guard-guest.sh pre|post
#   pre    arm the guard as a boot that is about to be cut short
#   post   after a reboot: the reboot itself is not counted, two cut-off boots in a row trip the
#          guard, and a settled boot does not

D=/data/local/tmp/gm
MODS=$D/modules
M=$MODS/susfs_guard_lkm
say() { echo "ANDROID $1=$2"; }
yn() { if "$@" > /dev/null 2>&1; then echo yes; else echo no; fi; }
bootid() { cat /proc/sys/kernel/random/boot_id; }

case $1 in
  pre)
    rm -rf "$D"
    mkdir -p "$M" "$MODS/other_a" "$MODS/other_b"
    : > "$MODS/other_b/disable"
    cp -r /data/local/tmp/mod/. "$M/"
    echo "exit 0" > "$M/load.upstream.sh"
    chmod 755 "$M"/*.sh "$M"/bin/*
    sh "$M/load.sh"
    say load_rc $?
    say boot_id "$(bootid)"
    say armed "$(cat "$M/guard.armed" 2> /dev/null)"
    say tripped "$(yn [ -f "$M/guard.tripped" ])"
    say disabled "$(yn [ -f "$M/disable" ])"
    say scope "$(cat "$M/guard.scope" 2> /dev/null || echo default)"
    sed 's/^/GUARDLOG: /' "$M/guard.log" 2> /dev/null
    ;;
  post)
    say new_boot_id "$(bootid)"
    say marker_survived "$(cat "$M/guard.armed" 2> /dev/null)"
    sh "$M/load.sh"
    say first_load_rc $?
    say first_tripped "$(yn [ -f "$M/guard.tripped" ])"
    say first_fails "$(cat "$M/guard.fails" 2> /dev/null)"
    say first_armed "$(cat "$M/guard.armed" 2> /dev/null)"
    say boot_reason "$(getprop sys.boot.reason)"
    # The guest has one real reboot, so the cut-off boots that follow are simulated: another boot
    # id each time, and a getprop that reports the end of the previous boot as a plain "reboot",
    # which nobody asked for.
    mkdir -p "$D/bin"
    printf '#!/system/bin/sh\ncase $1 in sys.boot.reason | ro.boot.bootreason) echo reboot ;; *) exec /system/bin/getprop "$@" ;; esac\n' > "$D/bin/getprop"
    chmod 755 "$D/bin/getprop"
    PATH=$D/bin:$PATH
    export PATH
    echo fake-boot-1 > "$D/boot_id"
    GUARD_BOOT_ID_FILE=$D/boot_id sh "$M/load.sh"
    say cut_tripped "$(yn [ -f "$M/guard.tripped" ])"
    say cut_fails "$(cat "$M/guard.fails" 2> /dev/null)"
    echo fake-boot-2 > "$D/boot_id"
    GUARD_BOOT_ID_FILE=$D/boot_id sh "$M/load.sh"
    say load_rc $?
    say tripped "$(yn [ -f "$M/guard.tripped" ])"
    say reason "$(cat "$M/guard.tripped" 2> /dev/null)"
    say disabled "$(yn [ -f "$M/disable" ])"
    say armed_after "$(yn [ -f "$M/guard.armed" ])"
    say other_a_disabled "$(yn [ -f "$MODS/other_a/disable" ])"
    say other_b_listed "$(yn grep -qx other_b "$M/guard.disabled")"
    say listed "$(tr '\n' , < "$M/guard.disabled" 2> /dev/null)"
    say card "$(sed -n 's/^description=//p' "$M/module.prop")"
    sed 's/^/GUARDLOG: /' "$M/guard.log" 2> /dev/null

    # Enabled again, the guard starts over, and a boot that settles clears the marker.
    rm -f "$M/disable"
    sh "$M/load.sh"
    say restart_armed "$(cat "$M/guard.armed" 2> /dev/null)"
    say restart_tripped "$(yn [ -f "$M/guard.tripped" ])"
    GUARD_SETTLE=2 GUARD_POLL=1 sh "$M/service.sh"
    n=0
    while [ -f "$M/guard.armed" ] && [ "$n" -lt 30 ]; do
      sleep 1
      n=$((n + 1))
    done
    say settled_armed "$(yn [ -f "$M/guard.armed" ])"
    say settled_after "$n"
    ;;
  *)
    echo "usage: guard-guest.sh pre|post" >&2
    exit 2
    ;;
esac
