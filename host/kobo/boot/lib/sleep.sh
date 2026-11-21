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
}

kobo_exit_sleep() {
    [ -f "$W/sleeping" ] || [ -f "$W/saver_frozen" ] || return 0
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
    type wifi_ps_off >/dev/null 2>&1 && wifi_ps_off
    epd_send REDRAW
    t "sleep: woke up and redrew screen"
}

sleep_watch() {
    pf=$W/power.fifo
    rm -f "$pf"; mkfifo "$pf" 2>/dev/null || return 1
    chmod 666 "$pf"
    touch "$W/lastinput" 2>/dev/null || true
    exec 4<>"$pf"
    while :; do
        # Non-blocking check with 5s timeout (busybox read -t)
        if read -t 5 -r ev <&4 2>/dev/null; then
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
