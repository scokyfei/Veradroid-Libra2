#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Gesture & hardware-key action handler for VeraDroid on Kobo Libra 2.
# Called by veradroid-input: sh action.sh <action> [arg]

VD=${VD:-$(cd "$(dirname "$0")/.." && pwd)}
W=/tmp/veradroid
X=$W/kfb
SYS=${SYS:-$VD/sys}
[ -f "$VD/boot/lib/kobo.sh" ] && . "$VD/boot/lib/kobo.sh"

AL=/tmp/veradroid-actions.log
if [ "$1" != poke ]; then
    [ -f "$AL" ] && [ "$(wc -c < "$AL" 2>/dev/null || echo 0)" -gt 65536 ] && { tail -c 32768 "$AL" > "$AL.tmp" 2>/dev/null && mv -f "$AL.tmp" "$AL"; }
    echo "[$(date +%T)] action $1 $2" >> "$AL"
fi
[ -f "$SYS/settings.conf" ] && . "$SYS/settings.conf"

send() { kill -0 "$(cat "$W/cmd.pid" 2>/dev/null)" 2>/dev/null || return 0; ( echo "$1" > "$X/ctl/cmd" ) & }
power_send() { [ -p "$W/power.fifo" ] && ( echo "$1" > "$W/power.fifo" ) & }

POS=t
fifo_put() { ( echo "$1" > "$X/epd.fifo" ) & fp=$!; ( sleep 3; kill "$fp" 2>/dev/null ) </dev/null >/dev/null 2>&1 & }
badge() {
    [ -p "$X/epd.fifo" ] && kill -0 "$(cat "$W/epd.pid" 2>/dev/null)" 2>/dev/null || return 0
    fifo_put "BADGE $1 $2 $3 $4"
}
hint() { [ "${GESTURE_HINT:-all}" = all ] && badge 800 "$POS" "$1" "$2"; return 0; }

watch_ctl() {
    [ "${GESTURE_HINT:-all}" = off ] && return 0
    ( sleep 2; [ -e "$X/ctl/$1" ] && { echo "[$(date +%T)] no response: $1" >> "$AL"; badge 3000 "$POS" stuck "NO RESPONSE|没有响应|长按左下角返回 Kobo"; } ) </dev/null >/dev/null 2>&1 &
}

frontlight() {
    cur=$(kobo_light_get)
    case "$1" in
        lightoff) want=off ;;
        lighton)  want=on ;;
        *) [ "${cur:-0}" -gt 0 ] && want=off || want=on ;;
    esac
    if [ "$want" = off ]; then
        [ "${cur:-0}" -gt 0 ] && echo "$cur" > "$W/fl.saved"
        kobo_light_set 0
    else
        [ "${cur:-0}" -gt 0 ] && return 0
        n=$(cat "$W/fl.saved" 2>/dev/null)
        case "$n" in ''|*[!0-9]*|0) n=35 ;; esac
        kobo_light_set "$n"
    fi
}

step_light() {
    cur=$(kobo_light_get)
    [ "$1" = "+" ] && n=$((cur + 10)) || n=$((cur - 10))
    [ "$n" -lt 0 ] && n=0; [ "$n" -gt 100 ] && n=100
    kobo_light_set "$n"
    hint light "LIGHT|亮度 ${n}%"
}

step_warmth() {
    cur=$(kobo_warmth_get)
    [ "$1" = "+" ] && n=$((cur + 3)) || n=$((cur - 3))
    [ "$n" -lt 0 ] && n=0; [ "$n" -gt 24 ] && n=24
    kobo_warmth_set "$n"
    hint warm "WARMTH|暖光 $((n * 100 / 24))%"
}

run_action() {
    case "$1" in
        ''|none) ;;
        back|home|panel|switch)
            case "$1" in back) hint back "BACK|返回" ;; home) hint home "HOME|桌面" ;; panel) hint panel "PANEL|面板" ;; switch) hint switch "SWITCH APPS|切换" ;; esac
            touch "$X/ctl/act.$1"; watch_ctl "act.$1" ;;
        kindle|return) hint kindle "KOBO|返回 Kobo"; send exit ;;
        clear|refresh) hint clear "REFRESH|清残影"; [ -p "$X/epd.fifo" ] && kill -0 "$(cat "$W/epd.pid" 2>/dev/null)" 2>/dev/null && fifo_put FULL ;;
        invert) hint invert "INVERT|反色"; send invert ;;
        stop) hint power "STOP|关闭 Android"; send stop ;;
        restart) hint restart "RESTART|重启 Android"; send restart ;;
        screenshot) hint camera "SCREENSHOT|截图"; send screenshot ;;
        frontlight|lighton|lightoff)
            frontlight "$1"
            [ "$(kobo_light_get)" = 0 ] && hint light "LIGHT|前光 关" || hint light "LIGHT|前光 开" ;;
        sleep) power_send sleep ;;
        wake)  power_send wake ;;
        power) power_send toggle ;;
        wifi)  send status ;;
        app.*)
            pkg=${1#app.}
            case "$pkg" in ''|*[!A-Za-z0-9._]*) ;; *) hint app "OPEN APP|打开应用"; echo "$pkg" > "$X/ctl/app.tmp" && mv -f "$X/ctl/app.tmp" "$X/ctl/app"; watch_ctl app ;; esac ;;
    esac
}

case "$1" in
    clear)  POS=t; run_action "${G_TWO_TAP_ACT:-clear}" ;;
    invert) POS=t; run_action "${G_TWO_LONG_ACT:-invert}" ;;
    light)  POS=l; step_light "$2" ;;
    warmth) POS=r; step_warmth "$2" ;;
    panel)  POS=t; run_action panel ;;
    tl) POS=tl; run_action "${G_TL:-none}" ;;
    tr) POS=tr; run_action "${G_TR:-none}" ;;
    bl) POS=bl; run_action "${G_BL:-kindle}" ;;
    br) POS=br; run_action "${G_BR:-none}" ;;
    power)  power_send toggle ;;
    sleep)  power_send sleep ;;
    wake)   power_send wake ;;
    hint)   case "$2" in back) POS=b; hint back "BACK|返回" ;; esac ;;
    poke)   touch "$W/lastinput" 2>/dev/null || true ;;
esac
