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

kobo_deep_suspend() {
    # Enter true Linux mem suspend on Kobo Libra 2 (drops standby draw from ~8.5%/h to <0.1%/h).
    # Skipped while charging so USB charging & SSH debugging stay uninterrupted.
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
    # Wait for EPDC screensaver refresh to finish so /sys/power/state does not return -EBUSY.
    sleep 2

    rc=1
    i=0
    while [ $i -lt 3 ]; do
        if echo mem > /sys/power/state 2>/dev/null; then
            rc=0
            break
        fi
        i=$((i + 1))
        sleep 1
    done

    # Resume subsystems immediately on hardware wakeup (KEY_POWER / sleepcover / USB plug-in).
    [ -w /sys/power/state-extended ] && echo 0 > /sys/power/state-extended 2>/dev/null || true
    usleep 100000
    t "sleep: returned from mem suspend (rc=$rc)"
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

    if kobo_deep_suspend; then
        # Drain any KEY_POWER event queued during hardware wakeup before exiting sleep.
        while read -t 0 -r _ <&4 2>/dev/null; do :; done
        kobo_exit_sleep
        # Brief grace period to swallow late-arriving wakeup KEY_POWER from veradroid-input.
        usleep 300000
        while read -t 0 -r _ <&4 2>/dev/null; do :; done
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
    if [ -f "$W/sleep.wifi" ]; then
        rm -f "$W/sleep.wifi"
        (
            kobo_wifi_set 1
            type hostnet_write >/dev/null 2>&1 && hostnet_write
            type wifi_ps_set >/dev/null 2>&1 && wifi_ps_set on
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
    while :; do
        # Non-blocking check with 15s timeout (FIFO events still wake immediately with 0ms latency)
        if read -t 15 -r ev <&4 2>/dev/null; then
            case "$ev" in
                toggle|power)
                    if [ -f "$W/sleeping" ] || [ -f "$W/saver_frozen" ]; then kobo_exit_sleep
                    else kobo_enter_sleep; fi ;;
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
