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

kobo_rtc_wakeup_set() { # $1 = enabled|disabled
    want=$1
    if [ "$want" = disabled ]; then
        [ -w /sys/class/rtc/rtc0/wakealarm ] && echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
    fi
    for f in /sys/devices/platform/soc/2100000.aips-bus/21a8000.i2c/i2c-2/2-0032/rtc_ricoh619/power/wakeup \
             /sys/devices/platform/soc/2000000.aips-bus/20cc000.snvs/20cc000.snvs:snvs-rtc-lp/power/wakeup; do
        [ -w "$f" ] && echo "$want" > "$f" 2>/dev/null || true
    done
}

kobo_wake_irq_sum() {
    awk '$NF == "Power" || $NF == "Hall" || $NF == "PageUp" || $NF == "PageDown" { s += $2 } END { print s + 0 }' /proc/interrupts 2>/dev/null
}

sleep_timeout_get() {
    _to=$(sed -n 's/^SLEEP_TIMEOUT=//p' "$SYS/settings.conf" 2>/dev/null | tail -n 1)
    case "$_to" in
        ''|*[!0-9]*) _to=${SLEEP_TIMEOUT:-600} ;;
    esac
    echo "$_to"
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
    # Skipped while charging so USB charging & SSH debugging stay uninterrupted (screensaver stays active).
    # Spurious RTC/PMIC wakeups (e.g. Android 10-min healthd/AlarmManager alarmtimer) are filtered by
    # checking hardware Power/Hall IRQ counters in /proc/interrupts and immediately re-suspending.
    # Return codes:
    #   0 = resumed by real user wakeup (Power key / Hall sleepcover)
    #   2 = cancelled by user power/wake press during pre-suspend wait
    #   1 = skipped or failed (caller stays in screensaver fallback)
    [ -w /sys/power/state ] && grep -qw mem /sys/power/state 2>/dev/null || return 1
    kobo_is_charging && return 1
    [ -f "$W/saver_nofreeze" ] && return 1

    # Pause USB MTP and Bluetooth radio before mem suspend so they cannot block suspend or drain battery.
    if type usb_mtp_running >/dev/null 2>&1 && usb_mtp_running; then
        echo 1 > "$W/sleep.mtp"
        usb_mtp_stop 2>/dev/null || true
    else
        rm -f "$W/sleep.mtp"
    fi
    if type bt_is_on >/dev/null 2>&1 && bt_is_on; then
        echo 1 > "$W/sleep.bt"
        bt_radio_off 2>/dev/null || true
    else
        rm -f "$W/sleep.bt"
    fi

    # Power off SDIO Wi-Fi (8723ds + sdio_wifi_pwr) so the radio cannot block suspend or leak current.
    if [ "$(kobo_wifi_enabled)" = 1 ]; then
        echo 1 > "$W/sleep.wifi"
        kobo_wifi_set 0
        t "sleep: wifi powered off for deep suspend"
    elif [ ! -f "$W/sleep.wifi" ]; then
        rm -f "$W/sleep.wifi"
    fi

    sync

    # Kobo Libra 2 (1264x1680) mxc_epdc_v2_fb enforces dwSafeTicksEP3V3 = 900 ticks (9.0s @ HZ=100)
    # after epdc_powerdown() for VEE rail stabilization; earlier /sys/power/state writes fail with -2.
    # Wait interruptibly until >= 10s have elapsed since screensaver draw (and EPDC power_state is off).
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
    spurious_burst=0
    spurious_t0=0
    while :; do
        kobo_is_charging && { rc=1; break; }
        i=0
        mem_ok=0
        rm -f "$W/suspend.err"
        [ -w /sys/power/state-extended ] && echo 1 > /sys/power/state-extended 2>/dev/null || true
        # Disable hardware RTC wakeups across mem suspend; also guard against kernel alarmtimer
        # re-arming rtc_ricoh619 inside suspend_devices_and_enter() via Power/Hall IRQ check below.
        kobo_rtc_wakeup_set disabled
        irq_before=$(kobo_wake_irq_sum)
        while [ $i -lt 8 ]; do
            kobo_is_charging && break
            i=$((i + 1))
            if echo mem > /sys/power/state 2>"$W/suspend.err"; then
                mem_ok=1
                break
            fi
            sleep_wait_1s
            if [ $? -eq 2 ]; then
                kobo_rtc_wakeup_set enabled
                [ -w /sys/power/state-extended ] && echo 0 > /sys/power/state-extended 2>/dev/null || true
                t "sleep: deep suspend cancelled by user wakeup (after $i tries)"
                return 2
            fi
        done

        if [ "$mem_ok" -ne 1 ]; then
            rc=1
            break
        fi

        # Give GPIO/PMIC IRQ accounting a brief moment to settle, then check if Power or Hall woke us.
        usleep 150000
        irq_after=$(kobo_wake_irq_sum)
        if [ "${irq_after:-0}" != "${irq_before:-0}" ]; then
            rc=0
            t "sleep: real user wakeup from mem suspend (tries=$i irq $irq_before->$irq_after)"
            break
        fi

        # If a charger was plugged in during mem suspend, stay in charging screensaver (do not light up screen).
        if kobo_is_charging; then
            rc=1
            t "sleep: mem suspend ended on charger connect, staying in charging screensaver"
            break
        fi

        # Spurious wakeup (e.g. kernel alarmtimer / rtc_ricoh61x 10-min alarm or PMIC noise): re-suspend silently.
        now_s=$(date +%s)
        if [ "$spurious_t0" -eq 0 ] || [ $((now_s - spurious_t0)) -gt 30 ]; then
            spurious_t0=$now_s
            spurious_burst=1
        else
            spurious_burst=$((spurious_burst + 1))
        fi
        t "sleep: ignoring spurious mem wakeup (tries=$i irq=$irq_after burst=$spurious_burst), re-suspending"
        if [ "$spurious_burst" -ge 5 ]; then
            t "sleep: spurious wakeup burst limit reached, falling back to screensaver"
            rc=1
            break
        fi
        sleep_wait_1s
        if [ $? -eq 2 ]; then
            kobo_rtc_wakeup_set enabled
            [ -w /sys/power/state-extended ] && echo 0 > /sys/power/state-extended 2>/dev/null || true
            t "sleep: user wakeup pressed during re-suspend wait"
            return 2
        fi
    done

    # Resume subsystems immediately on real wakeup or fallback.
    kobo_rtc_wakeup_set enabled
    [ -w /sys/power/state-extended ] && echo 0 > /sys/power/state-extended 2>/dev/null || true
    usleep 250000
    if [ "$rc" -ne 0 ]; then
        err=$(tr '\n' ' ' < "$W/suspend.err" 2>/dev/null)
        t "sleep: left deep suspend (rc=$rc err=${err:-charger_or_retry})"
    fi
    return $rc
}

audio_active() {
    [ -f "$X/audio.active" ] || return 1
    _am=$(stat -c %Y "$X/audio.active" 2>/dev/null || echo 0)
    _an=$(date +%s)
    [ "$_am" -gt 0 ] && [ $((_an - _am)) -lt 10 ]
}

sleep_transfer_busy() {
    [ -f "$W/fwd.id" ] || alive "$W/installing" || [ -f "$W/compile.lock" ] || alive "$W/compile.guard" \
        || audio_active \
        || { type usb_mtp_active >/dev/null 2>&1 && usb_mtp_active; }
}

kobo_enter_sleep() {
    [ -f "$W/saver_frozen" ] || [ -f "$W/sleeping" ] && return 0
    touch "$W/sleeping" "$X/ctl/sleep"
    type lock_request >/dev/null 2>&1 && lock_request
    usleep 250000
    cur_fl=$(kobo_light_get)
    if [ "${cur_fl:-0}" -eq 0 ] && [ -f "$W/fl.dimmed" ]; then
        dim_fl=$(tr -cd '0-9' < "$W/fl.dimmed" 2>/dev/null)
        [ "${dim_fl:-0}" -gt 0 ] && cur_fl=$dim_fl
        rm -f "$W/fl.dimmed"
    fi
    echo "${cur_fl:-0}" > "$W/sleep.fl"
    kobo_light_set 0
    screensaver_show
    if sleep_transfer_busy; then
        touch "$W/saver_nofreeze"
        t "sleep: transfer/install in progress, leaving android running"
    else
        android_freeze && touch "$W/saver_frozen"
        type wifi_ps_restore >/dev/null 2>&1 && wifi_ps_restore
    fi
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
    touch "$W/lastinput" "$X/lasttouch" 2>/dev/null || true
    chmod 644 "$X/lasttouch" 2>/dev/null || true
    rm -f "$X/ctl/sleep"
    # Reset vinput slot state again after opening the sleep gate so any stale Elan resume event is cleared.
    type vinput_reset >/dev/null 2>&1 && vinput_reset thaw
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
    if [ -f "$W/sleep.mtp" ]; then
        rm -f "$W/sleep.mtp"
        ( type usb_mtp_start >/dev/null 2>&1 && usb_mtp_start ) </dev/null >>"$LOG" 2>&1 &
    fi
    if [ -f "$W/sleep.bt" ]; then
        rm -f "$W/sleep.bt"
        (
            if type bt_radio_on >/dev/null 2>&1 && bt_radio_on; then
                type bt_bridge_start >/dev/null 2>&1 && bt_bridge_start
                type bt_audio_sync >/dev/null 2>&1 && bt_audio_sync
                type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
                t "sleep: bluetooth restored after wakeup"
            fi
        ) </dev/null >>"$LOG" 2>&1 &
    fi
    t "sleep: woke up and redrew screen"
}

sleep_watch() {
    pf=$W/power.fifo
    rm -f "$pf"; mkfifo "$pf" 2>/dev/null || return 1
    chmod 666 "$pf"
    touch "$W/lastinput" "$X/lasttouch" 2>/dev/null || true
    chmod 644 "$X/lasttouch" 2>/dev/null || true
    exec 4<>"$pf"
    SLEEP_FIFO_READY=1
    MEM_WAKE_TS=0
    SUSPEND_BACKOFF_UNTIL=0
    while :; do
        # Non-blocking check with 15s timeout (FIFO events still wake immediately with 0ms latency)
        if read -t 15 -r ev <&4 2>/dev/null; then
            case "$ev" in
                toggle|power)
                    if [ -f "$W/sleeping" ] || [ -f "$W/saver_frozen" ]; then
                        SUSPEND_BACKOFF_UNTIL=0
                        kobo_exit_sleep
                    else
                        now=$(date +%s)
                        if [ "${MEM_WAKE_TS:-0}" -gt 0 ] && [ $((now - MEM_WAKE_TS)) -lt 2 ]; then
                            t "sleep: ignoring trailing $ev right after mem wakeup"
                            continue
                        fi
                        SUSPEND_BACKOFF_UNTIL=0
                        kobo_enter_sleep
                    fi ;;
                sleep) SUSPEND_BACKOFF_UNTIL=0; kobo_enter_sleep ;;
                wake)  SUSPEND_BACKOFF_UNTIL=0; kobo_exit_sleep ;;
            esac
            continue
        fi
        # While sleeping in screensaver fallback (e.g. unplugged after charging sleep or transient suspend failure),
        # automatically upgrade to true mem deep suspend once not charging.
        if [ -f "$W/sleeping" ]; then
            now=$(date +%s)
            if ! kobo_is_charging && [ ! -f "$W/saver_nofreeze" ] && [ "$now" -ge "${SUSPEND_BACKOFF_UNTIL:-0}" ]; then
                kobo_deep_suspend
                ds_rc=$?
                if [ "$ds_rc" -eq 0 ]; then
                    SUSPEND_BACKOFF_UNTIL=0
                    kobo_exit_sleep
                    MEM_WAKE_TS=$(date +%s)
                elif [ "$ds_rc" -eq 2 ]; then
                    SUSPEND_BACKOFF_UNTIL=0
                    kobo_exit_sleep
                elif ! kobo_is_charging; then
                    SUSPEND_BACKOFF_UNTIL=$(( $(date +%s) + 120 ))
                fi
            fi
            continue
        fi
        # Idle timeout check (runs both on battery and while charging; deep mem suspend is skipped while charging)
        to=$(sleep_timeout_get)
        case "$to" in ''|0|*[!0-9]*) continue ;; esac
        last=$(stat -c %Y "$W/lastinput" 2>/dev/null || echo 0)
        now=$(date +%s)
        if [ "$last" -gt "$now" ]; then
            touch "$W/lastinput" "$X/lasttouch" 2>/dev/null || true
    chmod 644 "$X/lasttouch" 2>/dev/null || true
            last=$now
        fi
        if [ "$last" -gt 0 ] && [ $((now - last)) -ge "$to" ]; then
            if sleep_transfer_busy; then
                touch "$W/lastinput" "$X/lasttouch" 2>/dev/null || true
    chmod 644 "$X/lasttouch" 2>/dev/null || true
                continue
            fi
            t "sleep: idle ${to}s reached (charging=$(kobo_is_charging && echo 1 || echo 0))"
            kobo_enter_sleep
        fi
    done
}
