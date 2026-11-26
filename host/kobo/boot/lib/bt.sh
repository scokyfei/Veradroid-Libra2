# SPDX-License-Identifier: GPL-3.0-or-later
# Kobo Libra 2 Bluetooth HID (page turner / keyboard) stack + vdbtkeys bridge.
# Uses Kobo's native RTL8723DS BT stack (sdio_bt_pwr.ko + rtk_hciattach + BlueZ 5.63)
# and bridges HID input events into Android via vdbtkeys (uinput -> /dev/input/event3).
# Speaks the exact ctl/bt.list, ctl/bt.result, ctl/status protocol of VeraHome BluetoothActivity.

BT_PWR_KO=/drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko
BT_HCI_BIN=/sbin/rtk_hciattach
BT_UART=/dev/ttymxc1
BT_DAEMON=/libexec/bluetooth/bluetoothd
BT_CTL=/bin/bluetoothctl
BT_BLUEALSA=/bin/bluealsa
BT_APLAY=/bin/aplay

bt_supported() {
    [ "${VD_BT_FORCE:-0}" = 1 ] && return 0
    [ -f "$BT_PWR_KO" ] && [ -x "$BT_HCI_BIN" ] && [ -x "$BT_DAEMON" ] && [ -x "$BT_CTL" ]
}

bt_audio_supported() {
    [ -x "$BT_BLUEALSA" ] && [ -x "$BT_APLAY" ]
}

bt_audio_fifo_ensure() {
    [ -d "$X" ] || return 0
    if [ ! -p "$X/audio.fifo" ]; then
        rm -f "$X/audio.fifo" 2>/dev/null || true
        mkfifo -m 666 "$X/audio.fifo" 2>/dev/null || true
    fi
    chmod 666 "$X/audio.fifo" 2>/dev/null || true
}

bt_bluealsa_start() {
    bt_audio_supported || return 0
    bt_audio_fifo_ensure
    if alive "$W/bluealsa.pid" || pidof bluealsa >/dev/null 2>&1; then
        return 0
    fi
    : > "$W/bluealsa.log"
    "$BT_BLUEALSA" -i hci0 -p a2dp-source --a2dp-force-audio-cd --initial-volume=85 >>"$W/bluealsa.log" 2>&1 </dev/null &
    echo $! > "$W/bluealsa.pid"
    usleep 200000
    if alive "$W/bluealsa.pid"; then
        t "bt: bluealsa a2dp-source started (pid=$(cat "$W/bluealsa.pid"))"
    else
        t "bt: bluealsa failed to start (see $W/bluealsa.log)"
    fi
}

bt_bluealsa_stop() {
    p=$(cat "$W/bluealsa.pid" 2>/dev/null)
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
    killall -q -TERM bluealsa 2>/dev/null || true
    i=0
    while pidof bluealsa >/dev/null 2>&1 && [ $i -lt 10 ]; do usleep 100000; i=$((i + 1)); done
    killall -q -KILL bluealsa 2>/dev/null || true
    rm -f "$W/bluealsa.pid"
}

bt_audio_stop() {
    p=$(cat "$W/bt-audio.pid" 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        kill "$p" 2>/dev/null || true
        usleep 100000
        kill -9 "$p" 2>/dev/null || true
    fi
    killall -q -TERM aplay 2>/dev/null || true
    usleep 100000
    killall -q -KILL aplay 2>/dev/null || true
    rm -f "$W/bt-audio.pid" "$W/bt.audio.mac" "$W/bt.audio.name" "$X/audio.active"
}

bt_audio_start() { # $1 = MAC, $2 = display name
    mac=$1; name=$2
    bt_audio_supported || return 0
    bt_mac_ok "$mac" || return 1
    bt_bluealsa_start
    bt_audio_fifo_ensure

    cur_mac=$(cat "$W/bt.audio.mac" 2>/dev/null)
    if [ "$cur_mac" = "$mac" ] && alive "$W/bt-audio.pid"; then
        return 0
    fi
    bt_audio_stop
    printf '%s\n' "$mac" > "$W/bt.audio.mac"
    printf '%s\n' "${name:-$mac}" > "$W/bt.audio.name"
    : > "$W/bt-audio.log"
    (
        while [ -f "$W/bt.audio.mac" ] && bt_is_on; do
            m=$(cat "$W/bt.audio.mac" 2>/dev/null)
            [ "$m" = "$mac" ] || break
            if ! vd_timeout 3 "$BT_CTL" info "$mac" 2>/dev/null | grep -q 'Connected: yes'; then
                rm -f "$W/bt.audio.mac" "$W/bt.audio.name" "$X/audio.active"
                type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
                break
            fi
            bt_audio_fifo_ensure
            "$BT_APLAY" -q -D "bluealsa:DEV=$mac,PROFILE=a2dp" -f S16_LE -r 44100 -c 2 < "$X/audio.fifo" >>"$W/bt-audio.log" 2>&1
            rc=$?
            [ "$rc" = 0 ] && usleep 200000 || sleep 1
        done
        rm -f "$W/bt-audio.pid" "$X/audio.active"
    ) </dev/null >>"$W/bt-audio.log" 2>&1 &
    echo $! > "$W/bt-audio.pid"
    t "bt: A2DP audio bridge active for ${name:-$mac} ($mac)"
}

# Scan connected paired devices for an A2DP Sink (UUID 0000110b) and keep the FIFO->aplay bridge synced.
bt_audio_sync() {
    bt_audio_supported || return 0
    if ! bt_is_on; then
        bt_audio_stop
        return 0
    fi
    found_mac=
    found_name=
    _pfile="$W/bt.audio.scan.$$"
    vd_timeout 5 "$BT_CTL" paired-devices 2>/dev/null | sed -n 's/^Device \([0-9A-Fa-f:]\{17\}\) \(.*\)$/\1\t\2/p' > "$_pfile"
    while IFS="$(printf '\t')" read -r mac rawname; do
        umac=$(printf '%s' "$mac" | tr 'a-f' 'A-F')
        bt_mac_ok "$umac" || continue
        info=$(vd_timeout 3 "$BT_CTL" info "$umac" 2>/dev/null)
        printf '%s\n' "$info" | grep -q 'Connected: yes' || continue
        printf '%s\n' "$info" | grep -qiE '0000110b|Audio Sink' || continue
        alias_n=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Alias: //p' | head -1)
        [ -n "$alias_n" ] && rawname=$alias_n
        found_mac=$umac
        found_name=$(bt_sanitize_name "$rawname")
        break
    done < "$_pfile"
    rm -f "$_pfile"

    if [ -n "$found_mac" ]; then
        bt_audio_start "$found_mac" "${found_name:-$found_mac}"
    elif [ -f "$W/bt.audio.mac" ] || alive "$W/bt-audio.pid"; then
        bt_audio_stop
    fi
}

bt_mac_ok() {
    case "$1" in ''|*[!0-9A-F:]*) return 1 ;; esac
    printf '%s\n' "$1" | grep -qE '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'
}

# Persist BlueZ pairing keys on ext4 ($SYS/bluetooth) instead of Kobo's 16 KB /var/lib tmpfs.
bt_store_mount() {
    [ -d "$SYS" ] || return 0
    mkdir -p "$SYS/bluetooth" /var/lib/bluetooth 2>/dev/null || true
    chmod 700 "$SYS/bluetooth" 2>/dev/null || true
    if ! grep -q ' /var/lib/bluetooth ' /proc/mounts 2>/dev/null; then
        mount --bind "$SYS/bluetooth" /var/lib/bluetooth 2>/dev/null || true
    fi
}

bt_store_umount() {
    if grep -q ' /var/lib/bluetooth ' /proc/mounts 2>/dev/null; then
        umount /var/lib/bluetooth 2>/dev/null || umount -l /var/lib/bluetooth 2>/dev/null || true
    fi
}

bt_is_on() {
    [ -d /sys/class/bluetooth/hci0 ] || return 1
    pidof bluetoothd >/dev/null 2>&1 || return 1
    hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'
}

bt_has_paired() {
    for f in "$SYS"/bluetooth/*/*/info /var/lib/bluetooth/*/*/info; do
        [ -f "$f" ] && return 0
    done
    # Also check already-connected Bluetooth input devices
    for d in /sys/class/input/input*/id/bustype; do
        [ "$(cat "$d" 2>/dev/null)" = "0005" ] && return 0
    done
    return 1
}

bt_radio_on() {
    bt_supported || return 1
    bt_store_mount

    # 1. Power on RTL8723DS Bluetooth section
    if ! grep -q '^sdio_bt_pwr ' /proc/modules 2>/dev/null; then
        insmod "$BT_PWR_KO" >/dev/null 2>&1 || { t "bt: insmod sdio_bt_pwr failed"; return 1; }
        usleep 350000
    fi

    # 2. Attach Realtek H5 UART HCI on /dev/ttymxc1
    if [ ! -d /sys/class/bluetooth/hci0 ]; then
        killall -q -TERM rtk_hciattach 2>/dev/null || true
        usleep 150000
        killall -q -KILL rtk_hciattach 2>/dev/null || true
        : > "$W/bt-hci.log"
        "$BT_HCI_BIN" -n -s 115200 "$BT_UART" rtk_h5 >>"$W/bt-hci.log" 2>&1 </dev/null &
        echo $! > "$W/bt-hci.pid"
        i=0
        while [ $i -lt 40 ]; do
            [ -d /sys/class/bluetooth/hci0 ] && break
            alive "$W/bt-hci.pid" || break
            usleep 200000
            i=$((i + 1))
        done
    fi
    if [ ! -d /sys/class/bluetooth/hci0 ]; then
        t "bt: hci0 did not appear (see $W/bt-hci.log)"
        return 1
    fi

    # 3. Ensure system dbus-daemon & BlueZ bluetoothd are running
    if ! pidof bluetoothd >/dev/null 2>&1; then
        "$BT_DAEMON" >>"$W/bluetoothd.log" 2>&1 </dev/null &
        echo $! > "$W/bluetoothd.pid"
        i=0
        while [ $i -lt 25 ]; do
            "$BT_CTL" show 2>/dev/null | grep -q 'Controller ' && break
            usleep 200000
            i=$((i + 1))
        done
    fi

    hciconfig hci0 up >/dev/null 2>&1 || true
    "$BT_CTL" power on >/dev/null 2>&1 || true
    i=0
    while [ $i -lt 15 ]; do
        bt_is_on && {
            bt_bluealsa_start
            t "bt: radio powered on (hci0)"
            return 0
        }
        usleep 200000
        i=$((i + 1))
    done
    t "bt: hci0 failed to come UP"
    return 1
}

bt_radio_off() {
    bt_audio_stop
    bt_bluealsa_stop
    if pidof bluetoothd >/dev/null 2>&1; then
        "$BT_CTL" power off >/dev/null 2>&1 || true
        usleep 200000
    fi
    if [ -d /sys/class/bluetooth/hci0 ]; then
        hciconfig hci0 down >/dev/null 2>&1 || true
    fi
    # Stop bluetoothd so /var/lib/bluetooth can unmount cleanly and no idle daemon runs
    killall -q -TERM bluetoothd 2>/dev/null || true
    i=0
    while pidof bluetoothd >/dev/null 2>&1 && [ $i -lt 10 ]; do usleep 100000; i=$((i + 1)); done
    killall -q -KILL bluetoothd 2>/dev/null || true
    rm -f "$W/bluetoothd.pid"

    # Detach UART HCI
    p=$(cat "$W/bt-hci.pid" 2>/dev/null)
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
    killall -q -TERM rtk_hciattach 2>/dev/null || true
    i=0
    while pidof rtk_hciattach >/dev/null 2>&1 && [ $i -lt 10 ]; do usleep 100000; i=$((i + 1)); done
    killall -q -KILL rtk_hciattach 2>/dev/null || true
    rm -f "$W/bt-hci.pid"

    usleep 200000
    if grep -q '^sdio_bt_pwr ' /proc/modules 2>/dev/null; then
        rmmod sdio_bt_pwr >/dev/null 2>&1 || true
    fi
    bt_store_umount
    t "bt: radio powered off"
    return 0
}

# Publish veradroid-btkeys char node into an already-running container (when BT is enabled after boot).
bt_node_publish() {
    ev=$1
    [ -n "$ev" ] || return 1
    cpid=$(cat "$W/pid" 2>/dev/null)
    [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null || return 0
    [ -f "/proc/$cpid/root/system/build.prop" ] || return 0
    cdir="/proc/$cpid/root/dev/input"
    [ -d "$cdir" ] || return 0
    devnum=$(cat "/sys/class/input/$ev/dev" 2>/dev/null)
    [ -n "$devnum" ] || return 1
    ma=${devnum%%:*}; mi=${devnum##*:}

    # If already published with same major:minor, keep it
    old=$(cat "$W/bt.node" 2>/dev/null)
    if [ -n "$old" ] && [ -c "$old" ]; then
        return 0
    fi

    # Pick event3 if free, else event10..event19
    target=
    for n in 3 10 11 12 13 14 15 16 17 18 19; do
        [ -e "$cdir/event$n" ] || { target="$cdir/event$n"; break; }
    done
    [ -n "$target" ] || return 1
    if mknod "$target" c "$ma" "$mi" 2>/dev/null; then
        chmod 666 "$target" 2>/dev/null || true
        echo "$target" > "$W/bt.node"
        t "bt: hot-published $ev ($ma:$mi) -> $target"
        return 0
    fi
    return 1
}

bt_bridge_start() {
    [ "${BT_BRIDGE:-auto}" = 0 ] && return 0
    bt_supported || return 0
    [ -x "$VD/bin/vdbtkeys" ] || { t "bt: vdbtkeys binary missing"; return 0; }
    if alive "$W/bt.pid"; then
        # Ensure late-mounted container node exists if container is already running
        btn=$(input_sysname veradroid-btkeys)
        [ -n "$btn" ] && [ -z "${KFB_BTKEYS:-}" ] && bt_node_publish "$btn"
        return 0
    fi

    case "${BT_PT_MAP:-volume}" in volume|page|dpad|raw) btm=$BT_PT_MAP ;; *) btm=volume ;; esac
    bts=; [ "${BT_PT_SWAP:-0}" = 1 ] && bts=--swap
    chmod 666 /dev/uinput /dev/input/uinput 2>/dev/null || true
    : > "$W/bt.log"
    rm -f "$W/bt.state"
    "$VD/bin/vdbtkeys" "$W/bt.log" --map "$btm" $bts --no-kindle-pt \
        --conf "$SYS/settings.conf" --pidfile "$W/pid" --state "$W/bt.state" \
        --drop-flag "$W/frozen" --drop-flag "$W/saver_frozen" \
        --action "$VD/boot/action.sh" </dev/null >/dev/null 2>&1 &
    echo $! > "$W/bt.pid"

    i=0; btn=
    while [ $i -lt 15 ]; do
        btn=$(input_sysname veradroid-btkeys)
        [ -n "$btn" ] && break
        usleep 200000; i=$((i + 1))
    done
    if [ -z "$btn" ]; then
        t "bt: veradroid-btkeys did not appear, bridge off"
        bt_bridge_stop
        return 0
    fi
    if [ ! -e "/dev/input/$btn" ]; then
        dev=$(cat "/sys/class/input/$btn/dev" 2>/dev/null)
        [ -n "$dev" ] && mknod "/dev/input/$btn" c "${dev%%:*}" "${dev##*:}"
    fi
    if [ ! -c "/dev/input/$btn" ]; then
        t "bt: no node for $btn, bridge off"
        bt_bridge_stop
        return 0
    fi
    KFB_BTKEYS="/dev/input/$btn"
    chmod 666 "$KFB_BTKEYS" 2>/dev/null || true
    export KFB_BTKEYS
    # If container is already running (post-boot enable/pair), hot-publish into container /dev/input
    bt_node_publish "$btn"
    t "bt: bridge up, keys $KFB_BTKEYS map=$btm${bts:+ swap}"
    return 0
}

bt_bridge_stop() {
    p=$(cat "$W/bt.pid" 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        kill "$p" 2>/dev/null || true
        i=0
        while kill -0 "$p" 2>/dev/null && [ $i -lt 10 ]; do usleep 100000; i=$((i + 1)); done
        kill -9 "$p" 2>/dev/null || true
    fi
    old=$(cat "$W/bt.node" 2>/dev/null)
    [ -n "$old" ] && rm -f "$old" 2>/dev/null || true
    rm -f "$W/bt.pid" "$W/bt.state" "$W/bt.node"
    KFB_BTKEYS=; export KFB_BTKEYS
    return 0
}

bt_start() {
    KFB_BTKEYS=; export KFB_BTKEYS
    bt_supported || return 0
    case "${BT_BRIDGE:-auto}" in
        0) return 0 ;;
        1) bt_bridge_start ;;
        *) if bt_has_paired || [ "$(cat "$SYS/bt.enabled" 2>/dev/null)" = 1 ]; then
               bt_bridge_start
           fi ;;
    esac
}

# Called asynchronously after container_start if user left Bluetooth enabled across reboots.
bt_restore_boot() {
    bt_supported || return 0
    [ "$(cat "$SYS/bt.enabled" 2>/dev/null)" = 1 ] || return 0
    (
        if bt_radio_on; then
            bt_bridge_start
            bt_audio_sync
            bt_list_write
            type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
        fi
    ) </dev/null >>"$LOG" 2>&1 &
}

bt_release() { alive "$W/bt.pid" && kill -USR1 "$(cat "$W/bt.pid")" 2>/dev/null || true; return 0; }
bt_grab()    { alive "$W/bt.pid" && kill -USR2 "$(cat "$W/bt.pid")" 2>/dev/null || true; return 0; }

bt_stop() {
    bt_bridge_stop
    bt_radio_off 2>/dev/null || true
    rm -rf "$W/bt.op" 2>/dev/null || true
    return 0
}

# ---- Control files for VeraHome BluetoothActivity ----

bt_result_write() { # key=val ...
    [ -d "$X/ctl" ] || return 0
    _tmp="$X/ctl/bt.result.tmp.$$"
    : > "$_tmp"
    for kv in "$@"; do
        printf '%s\n' "$kv" >> "$_tmp"
    done
    chmod 644 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$X/ctl/bt.result" 2>/dev/null || rm -f "$_tmp"
}

bt_sanitize_name() {
    printf '%s' "$1" | tr -d '\000-\037\177' | cut -c1-64
}

bt_list_write() {
    [ -d "$X/ctl" ] || return 0
    _tmp="$X/ctl/bt.list.tmp.$$"
    _paired="$W/bt.list.p.$$"
    _other="$W/bt.list.o.$$"
    _pmacs="$W/bt.pmacs.$$"
    : > "$_paired"; : > "$_other"; : > "$_pmacs"

    if bt_is_on; then
        # Single fast query for paired devices; only call `info` on paired MACs to check Connected state.
        vd_timeout 5 "$BT_CTL" paired-devices 2>/dev/null | sed -n 's/^Device \([0-9A-Fa-f:]\{17\}\) \(.*\)$/\1\t\2/p' | while IFS="$(printf '\t')" read -r mac rawname; do
            umac=$(printf '%s' "$mac" | tr 'a-f' 'A-F')
            bt_mac_ok "$umac" || continue
            printf '%s\n' "$umac" >> "$_pmacs"
            info=$(vd_timeout 3 "$BT_CTL" info "$umac" 2>/dev/null)
            cn=0
            printf '%s\n' "$info" | grep -q 'Connected: yes' && cn=1
            alias_n=$(printf '%s\n' "$info" | sed -n 's/^[[:space:]]*Alias: //p' | head -1)
            [ -n "$alias_n" ] && rawname=$alias_n
            nm=$(bt_sanitize_name "$rawname")
            [ -n "$nm" ] || nm=$umac
            printf '%s\t%s\t1\t%s\n' "$nm" "$umac" "$cn" >> "$_paired"
        done

        # Single fast query for nearby discovered devices (skip paired duplicates & unnamed XX-XX-XX-XX-XX-XX BLE noise)
        vd_timeout 5 "$BT_CTL" devices 2>/dev/null | sed -n 's/^Device \([0-9A-Fa-f:]\{17\}\) \(.*\)$/\1\t\2/p' | while IFS="$(printf '\t')" read -r mac rawname; do
            umac=$(printf '%s' "$mac" | tr 'a-f' 'A-F')
            bt_mac_ok "$umac" || continue
            grep -qx "$umac" "$_pmacs" 2>/dev/null && continue
            nm=$(bt_sanitize_name "$rawname")
            [ -n "$nm" ] || continue
            # Skip unnamed random BLE beacons whose alias is just their MAC address with dashes
            dash_mac=$(printf '%s' "$umac" | tr ':' '-')
            [ "$nm" = "$dash_mac" ] || [ "$nm" = "$umac" ] && continue
            printf '%s\t%s\t0\t0\n' "$nm" "$umac" >> "$_other"
        done
    else
        # Even while BT is off, display already-paired devices saved in $SYS/bluetooth
        for inf in "$SYS"/bluetooth/*/*/info; do
            [ -f "$inf" ] || continue
            d=${inf%/info}; mac=${d##*/}
            umac=$(printf '%s' "$mac" | tr 'a-f' 'A-F')
            bt_mac_ok "$umac" || continue
            rawname=$(sed -n 's/^Name=//p' "$inf" 2>/dev/null | head -1)
            nm=$(bt_sanitize_name "$rawname")
            [ -n "$nm" ] || nm=$umac
            printf '%s\t%s\t1\t0\n' "$nm" "$umac" >> "$_paired"
        done
    fi

    cat "$_paired" "$_other" > "$_tmp" 2>/dev/null
    rm -f "$_paired" "$_other" "$_pmacs"
    chmod 644 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$X/ctl/bt.list" 2>/dev/null || rm -f "$_tmp"
}

bt_op_lock() {
    if ! mkdir "$W/bt.op" 2>/dev/null; then
        op=$(cat "$W/bt.op/pid" 2>/dev/null)
        [ -n "$op" ] && kill -0 "$op" 2>/dev/null && return 1
        rm -rf "$W/bt.op"
        mkdir "$W/bt.op" 2>/dev/null || return 1
    fi
    _spid=
    [ -r /proc/self/stat ] && read -r _spid _ < /proc/self/stat 2>/dev/null || true
    echo "${_spid:-$$}" > "$W/bt.op/pid"
    return 0
}
bt_op_unlock() { rm -rf "$W/bt.op" 2>/dev/null || true; }

bt_status_lines() {
    if bt_supported; then
        echo "btsupported=1"
        bt_is_on && echo "bton=1" || echo "bton=0"
    else
        echo "btsupported=0"
        echo "bton=0"
    fi
    alive "$W/bt.pid" && echo "bt=1" || echo "bt=0"
    echo "btdev=$(awk -F'\t' '{printf "%s%s:%s", (NR>1?",":""), $1, $2}' "$W/bt.state" 2>/dev/null)"
    echo "btmap=${BT_PT_MAP:-volume}"
    echo "btswap=${BT_PT_SWAP:-0}"
    echo "btbridge=${BT_BRIDGE:-auto}"
    _ba=
    if bt_is_on && [ -f "$W/bt.audio.name" ] && alive "$W/bt-audio.pid"; then
        _ba=$(cat "$W/bt.audio.name" 2>/dev/null)
    fi
    echo "btaudio=$_ba"
}

bt_do_enable() {
    bt_op_lock || { bt_result_write state=done op=power ok=0 error=busy; return 0; }
    trap 'bt_op_unlock' EXIT
    bt_result_write state=running op=power on=1 secs=15
    if bt_radio_on; then
        echo 1 > "$SYS/bt.enabled" 2>/dev/null || true
        bt_bridge_start
        bt_audio_sync
        bt_list_write
        type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
        bt_result_write state=done op=power on=1 ok=1
    else
        type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
        bt_result_write state=done op=power on=0 ok=0 error=lipc
    fi
    bt_op_unlock
}

bt_do_disable() {
    bt_op_lock || { bt_result_write state=done op=power ok=0 error=busy; return 0; }
    trap 'bt_op_unlock' EXIT
    bt_result_write state=running op=power on=0 secs=10
    echo 0 > "$SYS/bt.enabled" 2>/dev/null || true
    bt_radio_off
    bt_list_write
    type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
    bt_result_write state=done op=power on=0 ok=1
    bt_op_unlock
}

bt_do_scan() {
    bt_op_lock || { bt_result_write state=done op=scan ok=0 error=busy; return 0; }
    trap 'bt_op_unlock' EXIT
    if ! bt_is_on; then
        bt_result_write state=done op=scan ok=0 error=off
        bt_op_unlock
        return 0
    fi
    bt_result_write state=running op=scan secs=18
    # BlueZ 5.63 cancels discovery as soon as bluetoothctl exits, so keep it open for 15s
    ( { echo "scan on"; sleep 15; echo "scan off"; echo "quit"; } | "$BT_CTL" >/dev/null 2>&1 ) &
    sc_pid=$!
    i=0
    while [ $i -lt 5 ]; do
        sleep 3
        bt_list_write
        i=$((i + 1))
    done
    wait "$sc_pid" 2>/dev/null || true
    bt_list_write
    type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
    bt_result_write state=done op=scan ok=1
    bt_op_unlock
}

bt_do_bond() {
    mac=$1
    bt_mac_ok "$mac" || { bt_result_write state=done op=bond "mac=$mac" ok=0 error=badmac; return 0; }
    bt_op_lock || { bt_result_write state=done op=bond "mac=$mac" ok=0 error=busy; return 0; }
    trap 'bt_op_unlock' EXIT
    if ! bt_is_on; then
        bt_result_write state=done op=bond "mac=$mac" ok=0 error=off
        bt_op_unlock
        return 0
    fi
    bt_result_write state=running op=bond "mac=$mac" secs=35
    # Non-interactive Just-Works pairing + trust + connect via bluetoothctl
    ( {
        echo "agent NoInputNoOutput"
        echo "default-agent"
        echo "pair $mac"
        sleep 12
        echo "trust $mac"
        echo "connect $mac"
        sleep 8
        echo "quit"
    } | "$BT_CTL" >>"$W/bt-pair.log" 2>&1 ) &
    bp_pid=$!

    paired=0; conn=0; i=0
    while [ $i -lt 30 ]; do
        info=$(vd_timeout 3 "$BT_CTL" info "$mac" 2>/dev/null)
        printf '%s\n' "$info" | grep -q 'Paired: yes' && paired=1
        printf '%s\n' "$info" | grep -q 'Connected: yes' && conn=1
        [ "$paired" = 1 ] && [ "$conn" = 1 ] && break
        kill -0 "$bp_pid" 2>/dev/null || break
        sleep 1
        i=$((i + 1))
    done
    kill "$bp_pid" 2>/dev/null || true
    wait "$bp_pid" 2>/dev/null || true

    # Final trust + connect retry if paired succeeded but not yet connected
    if [ "$paired" = 1 ] && [ "$conn" = 0 ]; then
        vd_timeout 5 "$BT_CTL" trust "$mac" >/dev/null 2>&1 || true
        vd_timeout 8 "$BT_CTL" connect "$mac" >/dev/null 2>&1 || true
        sleep 2
        vd_timeout 3 "$BT_CTL" info "$mac" 2>/dev/null | grep -q 'Connected: yes' && conn=1
    fi

    bt_list_write
    if [ "$paired" = 1 ]; then
        bt_bridge_start
        bt_audio_sync
        type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
        if [ "$conn" = 1 ]; then
            bt_result_write state=done op=bond "mac=$mac" ok=1
        else
            bt_result_write state=done op=bond "mac=$mac" ok=0 error=notconnected
        fi
    else
        type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
        bt_result_write state=done op=bond "mac=$mac" ok=0 error=timeout
    fi
    bt_op_unlock
}

bt_do_connect() {
    mac=$1
    bt_mac_ok "$mac" || { bt_result_write state=done op=connect "mac=$mac" ok=0 error=badmac; return 0; }
    bt_op_lock || { bt_result_write state=done op=connect "mac=$mac" ok=0 error=busy; return 0; }
    trap 'bt_op_unlock' EXIT
    if ! bt_is_on; then
        bt_result_write state=done op=connect "mac=$mac" ok=0 error=off
        bt_op_unlock
        return 0
    fi
    if ! vd_timeout 3 "$BT_CTL" info "$mac" 2>/dev/null | grep -q 'Paired: yes'; then
        bt_result_write state=done op=connect "mac=$mac" ok=0 error=notpaired
        bt_op_unlock
        return 0
    fi
    bt_result_write state=running op=connect "mac=$mac" secs=15
    vd_timeout 5 "$BT_CTL" trust "$mac" >/dev/null 2>&1 || true
    ( vd_timeout 15 "$BT_CTL" connect "$mac" >/dev/null 2>&1 ) &
    cp_pid=$!
    conn=0; i=0
    while [ $i -lt 15 ]; do
        vd_timeout 3 "$BT_CTL" info "$mac" 2>/dev/null | grep -q 'Connected: yes' && { conn=1; break; }
        sleep 1
        i=$((i + 1))
    done
    kill "$cp_pid" 2>/dev/null || true
    bt_list_write
    if [ "$conn" = 1 ]; then
        bt_bridge_start
        bt_audio_sync
        type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
        bt_result_write state=done op=connect "mac=$mac" ok=1
    else
        type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
        bt_result_write state=done op=connect "mac=$mac" ok=0 error=timeout
    fi
    bt_op_unlock
}

bt_do_disconnect() {
    mac=$1
    bt_mac_ok "$mac" || { bt_result_write state=done op=disconnect "mac=$mac" ok=0 error=badmac; return 0; }
    bt_op_lock || { bt_result_write state=done op=disconnect "mac=$mac" ok=0 error=busy; return 0; }
    trap 'bt_op_unlock' EXIT
    if ! bt_is_on; then
        bt_result_write state=done op=disconnect "mac=$mac" ok=0 error=off
        bt_op_unlock
        return 0
    fi
    bt_result_write state=running op=disconnect "mac=$mac" secs=10
    vd_timeout 8 "$BT_CTL" disconnect "$mac" >/dev/null 2>&1 || true
    sleep 1
    bt_audio_sync
    bt_list_write
    type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
    if vd_timeout 3 "$BT_CTL" info "$mac" 2>/dev/null | grep -q 'Connected: yes'; then
        bt_result_write state=done op=disconnect "mac=$mac" ok=0 error=timeout
    else
        bt_result_write state=done op=disconnect "mac=$mac" ok=1
    fi
    bt_op_unlock
}

bt_do_unbond() {
    mac=$1
    bt_mac_ok "$mac" || { bt_result_write state=done op=unbond "mac=$mac" ok=0 error=badmac; return 0; }
    bt_op_lock || { bt_result_write state=done op=unbond "mac=$mac" ok=0 error=busy; return 0; }
    trap 'bt_op_unlock' EXIT
    if ! bt_is_on; then
        bt_result_write state=done op=unbond "mac=$mac" ok=0 error=off
        bt_op_unlock
        return 0
    fi
    bt_result_write state=running op=unbond "mac=$mac" secs=10
    vd_timeout 8 "$BT_CTL" disconnect "$mac" >/dev/null 2>&1 || true
    vd_timeout 8 "$BT_CTL" remove "$mac" >/dev/null 2>&1 || true
    sleep 1
    bt_audio_sync
    bt_list_write
    type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
    if vd_timeout 3 "$BT_CTL" info "$mac" 2>/dev/null | grep -q 'Paired: yes'; then
        bt_result_write state=done op=unbond "mac=$mac" ok=0 error=timeout
    else
        bt_result_write state=done op=unbond "mac=$mac" ok=1
    fi
    bt_op_unlock
}

bt_set_conf() {
    k=$1; v=$2
    touch "$SYS/settings.conf"
    grep -v "^$k=" "$SYS/settings.conf" > "$SYS/settings.conf.tmp" 2>/dev/null || true
    echo "$k=$v" >> "$SYS/settings.conf.tmp"
    mv -f "$SYS/settings.conf.tmp" "$SYS/settings.conf"
    eval "$k=\$v"
}

bt_cmd() {
    set -- $1
    sub=$1; arg=$2
    if ! bt_supported; then
        bt_result_write state=done "op=${sub:-bt}" ok=0 error=unsupported
        return 0
    fi
    case "$sub" in
        list)       ( bt_list_write ) </dev/null >>"$LOG" 2>&1 & ;;
        enable)     ( bt_do_enable ) </dev/null >>"$LOG" 2>&1 & ;;
        disable)    ( bt_do_disable ) </dev/null >>"$LOG" 2>&1 & ;;
        scan)       ( bt_do_scan ) </dev/null >>"$LOG" 2>&1 & ;;
        bond)       ( bt_do_bond "$arg" ) </dev/null >>"$LOG" 2>&1 & ;;
        connect)    ( bt_do_connect "$arg" ) </dev/null >>"$LOG" 2>&1 & ;;
        disconnect) ( bt_do_disconnect "$arg" ) </dev/null >>"$LOG" 2>&1 & ;;
        unbond)     ( bt_do_unbond "$arg" ) </dev/null >>"$LOG" 2>&1 & ;;
        map)
            case "$arg" in volume|page|dpad|raw)
                bt_set_conf BT_PT_MAP "$arg"
                alive "$W/bt.pid" && kill -HUP "$(cat "$W/bt.pid")" 2>/dev/null || true
                t "bt: BT_PT_MAP=$arg"
                type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true ;;
            esac ;;
        swap)
            case "$arg" in 0|1)
                bt_set_conf BT_PT_SWAP "$arg"
                alive "$W/bt.pid" && kill -HUP "$(cat "$W/bt.pid")" 2>/dev/null || true
                t "bt: BT_PT_SWAP=$arg"
                type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true ;;
            esac ;;
        bridge)
            case "$arg" in auto|1|0)
                bt_set_conf BT_BRIDGE "$arg"
                if [ "$arg" = 0 ]; then
                    bt_bridge_stop
                else
                    bt_bridge_start
                fi
                t "bt: BT_BRIDGE=$arg"
                type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true ;;
            esac ;;
    esac
}
