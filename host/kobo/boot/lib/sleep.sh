# SPDX-License-Identifier: GPL-3.0-or-later
# Sleep / screensaver manager for Kobo Libra 2.
# Driven by hardware KEY_POWER (via veradroid-input -> action.sh power -> $W/power.fifo),
# VeraHome "sleep" command, and optional idle timeout ($SLEEP_TIMEOUT).

saver_resolve_img() {
    case "$1" in
        "$SYS/data/media/0/Screensaver/"*)
            c="$SYS/data/media/0/Screensaver/.vd-cache/sd-${1##*/}.png"
            [ -f "$c" ] && { echo "$c"; return 0; } ;;
        "$VD/screensaver/"*)
            c="$SYS/data/media/0/Screensaver/.vd-cache/vd-${1##*/}.png"
            [ -f "$c" ] && { echo "$c"; return 0; } ;;
    esac
    echo "$1"
}

screensaver_show() {
    list=$W/saver.list
    : > "$list"
    smode=; sone=
    type saver_choice >/dev/null 2>&1 && saver_choice
    if [ "$smode" = one ] && [ -n "$sone" ]; then
        echo "$sone" >> "$list"
    elif [ "$smode" = kindle ]; then
        for d in /mnt/onboard/.kobo/screensaver /mnt/onboard/.adds/koreader/screensaver; do
            [ -d "$d" ] || continue
            for f in "$d"/*.[pP][nN][gG] "$d"/*.[jJ][pP][gG] "$d"/*.[jJ][pP][eE][gG] "$d"/*.[bB][mM][pP] "$d"/*.[gG][iI][fF]; do
                [ -f "$f" ] && [ ! -L "$f" ] && echo "$f" >> "$list"
            done
            [ -s "$list" ] && break
        done
    else
        for d in "$VD/screensaver" "$SYS/data/media/0/Screensaver" /mnt/onboard/.kobo/screensaver; do
            [ -d "$d" ] || continue
            for f in "$d"/*.[pP][nN][gG] "$d"/*.[jJ][pP][gG] "$d"/*.[jJ][pP][eE][gG] "$d"/*.[bB][mM][pP] "$d"/*.[gG][iI][fF] "$d"/*.[wW][eE][bB][pP]; do
                [ -f "$f" ] && [ ! -L "$f" ] || continue
                case "$f" in */default.png|*/default.PNG) continue ;; esac
                echo "$f" >> "$list"
            done
        done
    fi
    n=$(wc -l < "$list" 2>/dev/null | tr -d ' ')
    fb_img="$VD/bin/fbink-img"
    [ -x "$fb_img" ] || fb_img="$FBINK"
    if [ "${n:-0}" -gt 0 ] && [ -x "$fb_img" ]; then
        i=$(cat "$W/saver.index" 2>/dev/null || echo 0)
        case "$i" in ''|*[!0-9]*) i=0 ;; esac
        i=$(( (i % n) + 1 ))
        echo "$i" > "$W/saver.index"
        img=$(sed -n "${i}p" "$list")
        draw_img=$(saver_resolve_img "$img")
        if [ -f "$draw_img" ]; then
            if "$fb_img" -q -c -f -i "$draw_img" -g w=-2,h=-2,halign=CENTER,valign=CENTER,dither >/dev/null 2>&1; then
                t "screensaver: $img"
                return 0
            fi
            t "screensaver: fbink failed for $draw_img"
        fi
    fi
    splash "已休眠 · 按电源键唤醒" 40 || true
}

sleep_wait_1s() {
    # Interruptible 1s wait: wakes immediately if user presses power/wake while waiting for EPDC VEE stable.
    if [ "${SLEEP_FIFO_READY:-0}" = 1 ]; then
        if read -t 1 -r _ev <&4 2>/dev/null; then
            case "$_ev" in
                wake|power|toggle) return 2 ;;
            esac
        fi
    else
        sleep 1
    fi
    return 0
}

kobo_deep_suspend() {
    # Enter true Linux mem suspend on Kobo Libra 2 (drops standby draw from ~1.8%/h / 34mA to ~0.1%/h).
    # Skipped while charging so USB charging & SSH debugging stay uninterrupted.
    # Return codes:
    #   0 = resumed from real mem suspend
    #   2 = cancelled by user power/wake press during pre-suspend wait
    #   1 = skipped or failed (caller stays in screensaver fallback)
    [ -w /sys/power/state ] && grep -qw mem /sys/power/state 2>/dev/null || return 1
    kobo_is_charging && return 1
    [ -f "$W/saver_nofreeze" ] && return 1

    # Power off SDIO Wi-Fi (8723ds + sdio_wifi_pwr) so the radio cannot block suspend or leak current.
    if [ "$(kobo_wifi_enabled)" = 1 ]; then
        echo 1 > "$W/sleep.wifi"
        kobo_wifi_set 0
        t "sleep: wifi powered off for deep suspend"
    else
        rm -f "$W/sleep.wifi"
    fi

    sync
    [ -w /sys/power/state-extended ] && echo 1 > /sys/power/state-extended 2>/dev/null || true

    # Kobo Libra 2 (1264x1680) mxc_epdc_v2_fb enforces dwSafeTicksEP3V3 = 900 ticks (9.0s @ HZ=100)
    # after epdc_powerdown() for VEE rail stabilization; earlier /sys/power/state writes fail with -2.
    # Wait interruptibly until >= 10s have elapsed since screensaver draw (and EPDC power_state is off),
    # then retry up to 8 times (1s apart) in case the GC16 waveform finished slightly later.
    t0=$(cat "$W/saver.t0" 2>/dev/null || echo 0)
    case "$t0" in ''|*[!0-9]*) t0=0 ;; esac
    w=0
    while [ $w -lt 12 ]; do
        if kobo_is_charging; then
            [ -w /sys/power/state-extended ] && echo 0 > /sys/power/state-extended 2>/dev/null || true
            t "sleep: deep suspend aborted (charger connected)"
            return 1
        fi
        now=$(date +%s)
        pstate=$(cat /sys/class/graphics/fb0/power_state 2>/dev/null || echo off)
        if [ "$pstate" = off ] && { [ "$t0" -eq 0 ] || [ $((now - t0)) -ge 10 ] || [ "$now" -lt "$t0" ]; }; then
            break
        fi
        sleep_wait_1s
        if [ $? -eq 2 ]; then
            [ -w /sys/power/state-extended ] && echo 0 > /sys/power/state-extended 2>/dev/null || true
            t "sleep: deep suspend cancelled by user wakeup"
            return 2
        fi
        w=$((w + 1))
    done

    rc=1
    i=0
    rm -f "$W/suspend.err"
    while [ $i -lt 8 ]; do
        kobo_is_charging && break
        i=$((i + 1))
        if echo mem > /sys/power/state 2>"$W/suspend.err"; then
            rc=0
            break
        fi
        sleep_wait_1s
        if [ $? -eq 2 ]; then
            [ -w /sys/power/state-extended ] && echo 0 > /sys/power/state-extended 2>/dev/null || true
            t "sleep: deep suspend cancelled by user wakeup (after $i tries)"
            return 2
        fi
    done

    # Resume subsystems immediately on hardware wakeup (KEY_POWER / sleepcover / USB plug-in).
    [ -w /sys/power/state-extended ] && echo 0 > /sys/power/state-extended 2>/dev/null || true
    usleep 100000
    if [ "$rc" -eq 0 ]; then
        t "sleep: returned from mem suspend (rc=0 tries=$i)"
    else
        err=$(tr '\n' ' ' < "$W/suspend.err" 2>/dev/null)
        t "sleep: returned from mem suspend (rc=$rc tries=$i err=${err:-unknown})"
    fi
    return $rc
}

kobo_enter_sleep() {
    [ -f "$W/saver_frozen" ] || [ -f "$W/sleeping" ] && return 0
    touch "$W/sleeping" "$X/ctl/sleep"
    type lock_request >/dev/null 2>&1 && lock_request
    usleep 250000
    cur_fl=$(kobo_light_get)
    echo "${cur_fl:-0}" > "$W/sleep.fl"
    kobo_light_set 0
    screensaver_show
    if alive "$W/installing"; then
        touch "$W/saver_nofreeze"
        t "sleep: apk install in progress, leaving android running"
    else
        android_freeze && touch "$W/saver_frozen"
    fi
    type wifi_ps_restore >/dev/null 2>&1 && wifi_ps_restore
    date +%s > "$W/saver.t0"
    t "sleep: entered screensaver (saved frontlight=$cur_fl)"

    kobo_deep_suspend
    ds_rc=$?
    if [ "$ds_rc" -eq 0 ]; then
        kobo_exit_sleep
        MEM_WAKE_TS=$(date +%s)
    elif [ "$ds_rc" -eq 2 ]; then
        kobo_exit_sleep
    fi
}

kobo_exit_sleep() {
    [ -f "$W/sleeping" ] || [ -f "$W/saver_frozen" ] || return 0
    [ -w /sys/power/state-extended ] && echo 0 > /sys/power/state-extended 2>/dev/null || true
    if [ -f "$W/saver_nofreeze" ]; then
        rm -f "$W/saver_nofreeze"
    else
        android_thaw 2>/dev/null || true
    fi
    rm -f "$W/saver_frozen" "$W/sleeping"
    if [ -f "$W/sleep.fl" ]; then
        kobo_light_set "$(cat "$W/sleep.fl" 2>/dev/null)"
        rm -f "$W/sleep.fl"
    fi
    touch "$W/lastinput" 2>/dev/null || true
    rm -f "$X/ctl/sleep"
    epd_send REDRAW
    type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
    if [ -f "$W/sleep.wifi" ]; then
        rm -f "$W/sleep.wifi"
        (
            kobo_wifi_set 1
            type hostnet_write >/dev/null 2>&1 && hostnet_write
            type wifi_ps_set >/dev/null 2>&1 && wifi_ps_set on
            type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
            t "sleep: wifi restored after wakeup"
        ) </dev/null >>"$LOG" 2>&1 &
    fi
    t "sleep: woke up and redrew screen"
}

sleep_watch() {
    pf=$W/power.fifo
    rm -f "$pf"; mkfifo "$pf" 2>/dev/null || return 1
    chmod 666 "$pf"
    touch "$W/lastinput" 2>/dev/null || true
    exec 4<>"$pf"
    SLEEP_FIFO_READY=1
    MEM_WAKE_TS=0
    while :; do
        # Non-blocking check with 15s timeout (FIFO events still wake immediately with 0ms latency)
        if read -t 15 -r ev <&4 2>/dev/null; then
            case "$ev" in
                toggle|power)
                    if [ -f "$W/sleeping" ] || [ -f "$W/saver_frozen" ]; then
                        kobo_exit_sleep
                    else
                        now=$(date +%s)
                        if [ "${MEM_WAKE_TS:-0}" -gt 0 ] && [ $((now - MEM_WAKE_TS)) -lt 2 ]; then
                            t "sleep: ignoring trailing $ev right after mem wakeup"
                            continue
                        fi
                        kobo_enter_sleep
                    fi ;;
                sleep) kobo_enter_sleep ;;
                wake)  kobo_exit_sleep ;;
            esac
            continue
        fi
        # Idle timeout check (only when awake and not charging)
        [ -f "$W/sleeping" ] && continue
        to=${SLEEP_TIMEOUT:-600}
        case "$to" in ''|0|*[!0-9]*) continue ;; esac
        kobo_is_charging && continue
        last=$(stat -c %Y "$W/lastinput" 2>/dev/null || echo 0)
        now=$(date +%s)
        if [ "$last" -gt 0 ] && [ $((now - last)) -ge "$to" ]; then
            t "sleep: idle ${to}s reached"
            kobo_enter_sleep
        fi
    done
}
