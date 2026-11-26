# SPDX-License-Identifier: GPL-3.0-or-later
# Input front end for Kobo Libra 2:
#   - Grabs Elan Touchscreen (MT-B, raw 1680x1264 -> --swap-xy -> 1264x1680)
#   - Grabs gpio-keys (193 upper page, 194 lower page, 116 power button)
#   - Exposes virtual uinput devices veradroid-touch and veradroid-keys to Android

type bt_start >/dev/null 2>&1 || { bt_start() { :; }; bt_release() { :; }; bt_grab() { :; }; bt_stop() { :; }; }

input_sysname() {
    for d in /sys/class/input/input*; do
        [ "$(cat "$d/name" 2>/dev/null)" = "$1" ] && { ls "$d" | grep '^event' | head -1; return; }
    done
}

input_start() { input_touch_start || return 1; bt_start; return 0; }

input_touch_start() {
    REAL=$(input_find 'Elan Touchscreen|elan|touch|cyttsp|goodix|fts_ts')
    [ -n "$REAL" ] || { t "input: no touch screen found"; return 1; }
    HW_KEYS=$(input_find '"gpio-keys"')
    t "input: real touch=$REAL hw_keys=${HW_KEYS:-none}"

    [ -x "$VD/bin/veradroid-input" ] || {
        t "input: veradroid-input missing, raw passthrough $REAL"
        KFB_TOUCH=$REAL; chmod 666 "$KFB_TOUCH" 2>/dev/null
        export KFB_TOUCH
        return 0
    }

    chmod 666 /dev/uinput /dev/input/uinput 2>/dev/null || true
    : > "$W/input.log"
    if [ "${KFB_GESTURES:-1}" = 0 ]; then touch "$W/nogestures"; else rm -f "$W/nogestures"; fi
    gestures_write

    ge=${TOUCH_EDGE_PX:-120}; case "$ge" in ''|*[!0-9]*) ge=120 ;; esac
    extra=
    [ "${TOUCH_SWAP_XY:-1}" = 1 ] && extra="$extra --swap-xy"
    [ "${TOUCH_FLIP_X:-0}" = 1 ] && extra="$extra --flip-x"
    [ "${TOUCH_FLIP_Y:-0}" = 1 ] && extra="$extra --flip-y"
    [ -n "$HW_KEYS" ] && extra="$extra --keydev $HW_KEYS --key-map ${PAGE_KEYS_MAP:-volume}"
    [ "${PAGE_KEYS_SWAP:-0}" = 1 ] && extra="$extra --key-swap"

    "$VD/bin/veradroid-input" "$REAL" "$W/input.log" "$VD/boot/action.sh" \
        --w "${viewWidth:-1264}" --h "${viewHeight:-1680}" \
        --edge "$ge" --window "${G_WINDOW:-25}" \
        --edge-hold $((ge / 2)) --edge-swipe $((ge * 2 / 3)) \
        --edge-back "${KFB_EDGE_BACK:-1}" --corner-ms 2000 \
        --flag "$W/nogestures" --inject "$W/inject" \
        --gconf "$W/gestures" --fg "$X/fg" \
        --epd-fifo "$X/epd.fifo" --sleep-flag "$X/ctl/sleep" \
        --rt "${INPUT_RT:-5}" $(input_cpufreq_arg) $(rot_args) $extra >"$W/input.err" 2>&1 &
    echo $! > "$W/input.pid"

    i=0
    while [ $i -lt 25 ]; do
        vt=$(input_sysname veradroid-touch)
        vk=$(input_sysname veradroid-keys)
        [ -n "$vt" ] && [ -n "$vk" ] && break
        usleep 200000; i=$((i + 1))
    done

    if [ -z "$vt" ]; then
        t "input: virtual touch device did not appear (err: $(cat "$W/input.err" 2>/dev/null | tr '\n' ' '))"
        input_touch_stop
        KFB_TOUCH=$REAL; KFB_KEYS_VIRT=
        chmod 666 "$KFB_TOUCH" 2>/dev/null
        export KFB_TOUCH KFB_KEYS_VIRT
        return 0
    fi

    KFB_TOUCH=/dev/input/$vt
    KFB_KEYS_VIRT=/dev/input/$vk
    for n in $vt $vk; do
        [ -e "/dev/input/$n" ] && continue
        dev=$(cat "/sys/class/input/$n/dev" 2>/dev/null)
        [ -n "$dev" ] && mknod "/dev/input/$n" c "${dev%%:*}" "${dev##*:}"
    done
    chmod 666 "$KFB_TOUCH" "$KFB_KEYS_VIRT" 2>/dev/null || true
    export KFB_TOUCH KFB_KEYS_VIRT
    t "input: touch $REAL -> $KFB_TOUCH, keys ${HW_KEYS:-none} -> $KFB_KEYS_VIRT"
}

input_release() { bt_release; alive "$W/input.pid" && kill -USR1 "$(cat "$W/input.pid")" 2>/dev/null || true; }
input_grab()    { bt_grab; alive "$W/input.pid" && kill -USR2 "$(cat "$W/input.pid")" 2>/dev/null || true; }
input_stop()    { bt_stop; input_touch_stop; }
input_touch_stop() { alive "$W/input.pid" && kill "$(cat "$W/input.pid")" 2>/dev/null || true; rm -f "$W/input.pid"; }

input_cpufreq_arg() {
    for d in /sys/devices/system/cpu/cpu0/cpufreq /sys/devices/system/cpu/cpufreq/policy0; do
        [ -w "$d/scaling_min_freq" ] && { echo "--cpufreq $d"; return 0; }
    done
}
