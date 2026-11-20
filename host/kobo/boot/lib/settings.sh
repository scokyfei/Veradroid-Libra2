# SPDX-License-Identifier: GPL-3.0-or-later
# Settings management for VeraDroid on Kobo Libra 2.

settings_defaults() {
    RETURN_MODE=off
    ZRAM_MB=256
    SLIM=1
    LOWMEM=auto
    KINDLE_UI=keep
    SYSTEM_APP=home
    ANDROID_DNS="223.5.5.5 223.6.6.6"
    KFB_CONTRAST=1.3
    KFB_DITHER=3
    KFB_FLASH=8
    KFB_INVERT=0
    KFB_LIGHTF=0
    KFB_DARKEN=0
    KFB_SETTLE=50
    KFB_MODE=0
    KFB_HOLD=70
    KFB_ANIM_MODE=0
    KFB_ANIM_DIR=2
    KFB_ANIM_STEPS=12
    KFB_ANIM_MIN=45
    KFB_ROTATE=0
    G_TL=none; G_TR=none; G_BL=kindle; G_BR=none
    BOOST_MS=150
    BOOST_KHZ=0
    KFB_SCROLLDELAY=500
    KFB_SCROLLSTYLE=1
    KFB_SCROLLWFM=a2
    FAST_DRAG=1
    KFB_EPD_NICE=-8
    BG_NICE=10
    INPUT_RT=5
    KFB_GESTURES=1
    KFB_EDGE_BACK=1
    G_EDGE_BACK=1
    G_EDGE_PANEL=1
    G_TWO_TAP=1
    G_TWO_LONG=1
    G_TWO_BACK=1
    G_TWO_SLIDE=1
    G_EDGE_SENS=1
    G_BACK_EXCLUDE=com.tencent.weread.eink
    UPDATE_BACKUP=off
    DNS_MODE=auto
    G_WINDOW=40
    G_TWO_TAP_ACT=clear
    G_TWO_LONG_ACT=invert
    SAVER_EXIT_H=0
    SLEEP_TIMEOUT=600
    KFB_HWC=1
    KFB_HZ=30
    KFB_DIM=20
    USB_ASK=0
    WIFI_PS=auto
    APP_COMPILE=auto
    COMPILE_RUNNING=auto
    TIME_12_24=auto
    GESTURE_HINT=all
    SYSTEM_FONT=
}

lowmem_ram() { _mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo); [ -n "$_mt" ] && [ "$_mt" -lt 700000 ]; }
lowmem() {
    case "${LOWMEM:-auto}" in on|1) return 0 ;; off|0) return 1 ;; esac
    lowmem_ram
}
kindle_ui_mode() { echo keep; }
model_sub() { echo libra2; }

settings_load() {
    settings_defaults
    MODEL_SUB=libra2
    [ -f "$VD/models/libra2.conf" ] && . "$VD/models/libra2.conf"
    [ -f "$SYS/settings.conf" ] && . "$SYS/settings.conf"
    [ -f "$VD/settings.test" ] && . "$VD/settings.test"
    for k in KFB_CONTRAST KFB_DITHER KFB_FLASH KFB_INVERT KFB_LIGHTF KFB_DARKEN KFB_MODE KFB_SETTLE KFB_HOLD KFB_ANIM_MODE KFB_ANIM_DIR KFB_ANIM_STEPS KFB_ANIM_MIN; do
        eval "GLOB_$k=\$$k"
    done
    [ -f "$SYS/settings.app" ] && . "$SYS/settings.app"
    # On Kobo 4.1.15 (hostns / 512 MB), always exit cleanly so /mnt/onboard can unmount for USB.
    RETURN_MODE=off
}

settings_publish() {
    { for k in KFB_CONTRAST KFB_DITHER KFB_FLASH KFB_INVERT KFB_LIGHTF KFB_DARKEN KFB_MODE KFB_SETTLE KFB_HOLD KFB_ANIM_MODE KFB_ANIM_DIR KFB_ANIM_STEPS KFB_ANIM_MIN KFB_GESTURES KFB_ROTATE RETURN_MODE LOWMEM KINDLE_UI DNS_MODE G_TL G_TR G_BL G_BR G_EDGE_BACK G_EDGE_PANEL G_TWO_TAP G_TWO_LONG G_TWO_BACK G_TWO_SLIDE G_EDGE_SENS G_BACK_EXCLUDE G_TWO_TAP_ACT G_TWO_LONG_ACT WIFI_PS APP_COMPILE TIME_12_24 GESTURE_HINT BOOST_MS BOOST_KHZ KFB_SCROLLDELAY KFB_SCROLLSTYLE KFB_SCROLLWFM FAST_DRAG; do
          eval "echo $k=\${GLOB_$k:-\$$k}"
      done; } > "$X/settings.tmp" \
        && printf 'SYSTEM_FONT=%s\nSYSTEM_FONT_LIVE=%s\n' "$SYSTEM_FONT" "$(cat "$W/sysfont/android" 2>/dev/null)" >> "$X/settings.tmp" \
        && mv -f "$X/settings.tmp" "$X/settings"
    return 0
}

settings_apply() {
    sfile=$W/settings.apply.$$.$(cut -d' ' -f1 /proc/uptime | tr -d .)
    mv -f "$X/ctl/settings.new" "$sfile" 2>/dev/null || return 0
    touch "$SYS/settings.conf"
    for k in KFB_CONTRAST KFB_DITHER KFB_FLASH KFB_INVERT KFB_LIGHTF KFB_DARKEN KFB_MODE KFB_SETTLE KFB_HOLD KFB_ANIM_MODE KFB_ANIM_DIR KFB_ANIM_STEPS KFB_ANIM_MIN KFB_GESTURES KFB_ROTATE RETURN_MODE LOWMEM DNS_MODE G_TL G_TR G_BL G_BR G_EDGE_BACK G_EDGE_PANEL G_TWO_TAP G_TWO_LONG G_TWO_BACK G_TWO_SLIDE G_EDGE_SENS G_BACK_EXCLUDE G_TWO_TAP_ACT G_TWO_LONG_ACT WIFI_PS APP_COMPILE TIME_12_24 GESTURE_HINT BOOST_MS BOOST_KHZ KFB_SCROLLDELAY KFB_SCROLLSTYLE KFB_SCROLLWFM FAST_DRAG SLEEP_TIMEOUT; do
        v=$(sed -n "s/^$k=\([0-9A-Za-z._,]*\)\$/\1/p" "$sfile" | tail -1)
        [ -n "$v" ] || continue
        grep -v "^$k=" "$SYS/settings.conf" > "$sfile.conf" 2>/dev/null || true
        [ "$v" = default ] || echo "$k=$v" >> "$sfile.conf"
        mv -f "$sfile.conf" "$SYS/settings.conf"
    done
    rm -f "$sfile" "$sfile.conf"
    settings_load
    settings_publish
    epd_send ANIM "$KFB_ANIM_MODE" "$KFB_ANIM_DIR" "$KFB_ANIM_STEPS" "$KFB_ANIM_MIN"
    epd_send SET "$KFB_CONTRAST" "$KFB_DITHER" "$KFB_FLASH" "$KFB_INVERT" "$KFB_MODE" "$KFB_SETTLE" "${KFB_LIGHTF:-0}" "${KFB_DARKEN:-0}"
    epd_send HOLD "${KFB_HOLD:-70}"
    epd_send_scroll
    if [ "$KFB_GESTURES" = 0 ]; then touch "$W/nogestures"; else rm -f "$W/nogestures"; fi
    gestures_write
    dns_apply
    rotate_apply
    status_write
}

epd_send_scroll() {
    epd_send SCROLLDELAY "${KFB_SCROLLDELAY:-500}"
    epd_send SCROLLSTYLE "${KFB_SCROLLSTYLE:-1}"
    epd_send SCROLLWFM "${KFB_SCROLLWFM:-a2}"
}

gestures_write() {
    gc=
    for c in tl:G_TL tr:G_TR bl:G_BL br:G_BR; do
        eval "a=\$${c#*:}"
        case "$a" in ''|none) ;; *) gc="${gc:+$gc,}${c%%:*}" ;; esac
    done
    {
        for k in G_EDGE_BACK G_EDGE_PANEL G_TWO_TAP G_TWO_LONG G_TWO_BACK G_TWO_SLIDE G_EDGE_SENS G_BACK_EXCLUDE BOOST_MS BOOST_KHZ FAST_DRAG; do
            eval "echo $k=\$$k"
        done
        echo "G_CORNERS=${gc:-none}"
        echo "ROTATE=$(rot_deg)"
    } > "$W/gestures.tmp" && mv -f "$W/gestures.tmp" "$W/gestures"
}

dns_apply() {
    case "$DNS_MODE" in
        aliyun)  ANDROID_DNS="223.5.5.5 223.6.6.6" ;;
        tencent) ANDROID_DNS="119.29.29.29 182.254.116.116" ;;
        google)  ANDROID_DNS="8.8.8.8 8.8.4.4" ;;
        *)       ANDROID_DNS="223.5.5.5 223.6.6.6" ;;
    esac
    hostnet_write 2>/dev/null || true
}
