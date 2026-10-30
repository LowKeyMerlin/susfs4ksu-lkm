# Helpers for the Android jobs. CF names the fetched build.
FLAGS=(--vm_manager=qemu_cli --cpus=4 --memory_mb=4096 --enable_sandbox=false
	--boot_timeout_secs=2600 --gpu_mode=guest_swiftshader --start_webrtc=false
	--enable_bootanimation=false)
ADB="$CF/bin/adb"
SERIAL=127.0.0.1:6520

# start_device LOGFILE: launch the device in the background, set CREATE_PID
start_device() {
	sudo -u "$USER" -- env HOME="$HOME" bash -c \
		"cd '$CF' && timeout 2700 cvd create --host_path='$CF' --product_path='$CF' ${FLAGS[*]}" \
		> "$1" 2>&1 &
	CREATE_PID=$!
}

# wait_boot START LIMIT: succeed once adb reports sys.boot_completed=1.
# A launcher that exited is given a minute to leave adb reachable before failing.
wait_boot() {
	local start=$1 limit=$2 value gone=
	while [ $(( $(date +%s) - start )) -lt "$limit" ]; do
		"$ADB" connect "$SERIAL" > /dev/null 2>&1 || true
		value=$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
		[ "$value" = 1 ] && return 0
		if ! kill -0 "$CREATE_PID" 2>/dev/null; then
			gone=${gone:-$(date +%s)}
			[ $(( $(date +%s) - gone )) -ge 60 ] && return 1
		fi
		sleep 5
	done
	return 1
}

stop_device() {
	sudo -u "$USER" -- env HOME="$HOME" bash -c "cd '$CF' && cvd reset -y" > /dev/null 2>&1 || true
}