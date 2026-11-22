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
    KFB_DITHER=0
    KFB_FLASH=6
    KFB_INVERT=0
    KFB_LIGHTF=0
    KFB_DARKEN=0
    KFB_SETTLE=50
    KFB_MODE=0
    KFB_HOLD=70
    KFB_ANIM_MODE=0
    KFB_ANIM_DIR=2
    KFB_ANIM_STEPS=8
    KFB_ANIM_MIN=45
    KFB_ROTATE=0
    KFB_AUTO_ROTATE=0
    PAGE_KEYS_SWAP=0
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
    G_EDGE_THIRDS=0
    G_EB_L=appopt; G_EB_M=home; G_EB_R=back
    G_EB_HOLD=switch; G_EB_HOLD_MS=500
    G_BACK_EXCLUDE=com.tencent.weread.eink
    UPDATE_BACKUP=off
    DNS_MODE=auto
    G_WINDOW=60
    G_TWO_TAP_ACT=clear
    G_TWO_LONG_ACT=invert
    SAVER_EXIT_H=0
    SLEEP_TIMEOUT=600
    STORAGE_AUTO=1
    KFB_HWC=1
    KFB_HZ=20
    KFB_DIM=off
    KFB_IMG=0
    KFB_SMOOTH=0
    KFB_PACE=1
    KFB_CLEAN=0
    KFB_REAGL_MIN=35
    KFB_SCROLLDU=0
    KFB_GCN=0
    KFB_NEWWIN=0
    KFB_ECLIPSE=1
    KFB_DARKCRUSH=36
    KFB_HEAVY_FLASH=1
    KFB_SKIA_OPT=1
    KFB_FONT_GAMMA=2
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

smooth_apply() {
    case "$KFB_SMOOTH" in
        1) KFB_PACE=1; KFB_HOLD=0;  KFB_CLEAN=500; KFB_REAGL_MIN=85; KFB_MODE=0 ;;                 # 流畅优先：马上快刷（DU），跟着面板走，停下来再补一遍灰度
        2) KFB_PACE=1; KFB_HOLD=70; KFB_CLEAN=0;   KFB_REAGL_MIN=35; KFB_MODE=0 ;;                 # 均衡：按钮高亮和整页合成一次刷新；变化超过 35% 直接用 REAGL
        3) KFB_PACE=1; KFB_HOLD=70; KFB_CLEAN=0;   KFB_REAGL_MIN=35; KFB_MODE=3; KFB_SETTLE=120 ;; # 画质优先：驱动自动选波形（整页 REAGL / 灰度 GC16），防碰撞合并中间帧
        *) KFB_SMOOTH=0 ;;
    esac
}

settings_load() {
    settings_defaults
    MODEL_SUB=libra2
    [ -f "$VD/models/libra2.conf" ] && . "$VD/models/libra2.conf"
    [ -f "$SYS/settings.conf" ] && . "$SYS/settings.conf"
    [ -f "$VD/settings.test" ] && . "$VD/settings.test"
    for k in KFB_CONTRAST KFB_DITHER KFB_FLASH KFB_INVERT KFB_LIGHTF KFB_DARKEN KFB_MODE KFB_SETTLE KFB_HOLD KFB_SMOOTH KFB_PACE KFB_CLEAN KFB_REAGL_MIN KFB_SCROLLDU KFB_IMG KFB_ANIM_MODE KFB_ANIM_DIR KFB_ANIM_STEPS KFB_ANIM_MIN KFB_GCN KFB_NEWWIN KFB_ECLIPSE KFB_DARKCRUSH KFB_HEAVY_FLASH; do
        eval "GLOB_$k=\$$k"
    done
    smooth_apply
    if [ -f "$SYS/settings.app" ]; then
        _glob_sm=$KFB_SMOOTH
        . "$SYS/settings.app"
        # Only re-apply smooth preset if the per-app profile explicitly overrode KFB_SMOOTH
        if grep -q '^KFB_SMOOTH=' "$SYS/settings.app" 2>/dev/null && [ "$KFB_SMOOTH" != "$_glob_sm" ]; then
            smooth_apply
            . "$SYS/settings.app"
        fi
    fi
    # On Kobo 4.1.15 (hostns / 512 MB), always exit cleanly so /mnt/onboard can unmount for USB.
    RETURN_MODE=off
}

settings_publish() {
    { for k in KFB_CONTRAST KFB_DITHER KFB_FLASH KFB_INVERT KFB_LIGHTF KFB_DARKEN KFB_MODE KFB_SETTLE KFB_HOLD KFB_ANIM_MODE KFB_ANIM_DIR KFB_ANIM_STEPS KFB_ANIM_MIN KFB_IMG KFB_SMOOTH KFB_REAGL_MIN KFB_SCROLLDU KFB_GCN KFB_NEWWIN KFB_ECLIPSE KFB_DARKCRUSH KFB_HEAVY_FLASH KFB_SKIA_OPT KFB_FONT_GAMMA KFB_GESTURES KFB_ROTATE KFB_AUTO_ROTATE PAGE_KEYS_SWAP RETURN_MODE LOWMEM KINDLE_UI DNS_MODE G_TL G_TR G_BL G_BR G_EDGE_BACK G_EDGE_PANEL G_EDGE_THIRDS G_EB_L G_EB_M G_EB_R G_EB_HOLD G_EB_HOLD_MS G_TWO_TAP G_TWO_LONG G_TWO_BACK G_TWO_SLIDE G_EDGE_SENS G_BACK_EXCLUDE G_TWO_TAP_ACT G_TWO_LONG_ACT STORAGE_AUTO USB_ASK WIFI_PS APP_COMPILE TIME_12_24 GESTURE_HINT BOOST_MS BOOST_KHZ KFB_SCROLLDELAY KFB_SCROLLSTYLE KFB_SCROLLWFM FAST_DRAG; do
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
    dns_changed=0
    tf_changed=0
    while IFS='=' read -r k v; do
        case "$k" in
            KFB_CONTRAST|KFB_DITHER|KFB_FLASH|KFB_INVERT|KFB_LIGHTF|KFB_DARKEN|KFB_MODE|KFB_SETTLE|KFB_HOLD|KFB_ANIM_MODE|KFB_ANIM_DIR|KFB_ANIM_STEPS|KFB_ANIM_MIN|KFB_IMG|KFB_SMOOTH|KFB_REAGL_MIN|KFB_SCROLLDU|KFB_GCN|KFB_NEWWIN|KFB_ECLIPSE|KFB_DARKCRUSH|KFB_HEAVY_FLASH|KFB_SKIA_OPT|KFB_FONT_GAMMA|KFB_GESTURES|KFB_ROTATE|KFB_AUTO_ROTATE|PAGE_KEYS_SWAP|RETURN_MODE|LOWMEM|DNS_MODE|G_TL|G_TR|G_BL|G_BR|G_EDGE_BACK|G_EDGE_PANEL|G_EDGE_THIRDS|G_EB_L|G_EB_M|G_EB_R|G_EB_HOLD|G_EB_HOLD_MS|G_TWO_TAP|G_TWO_LONG|G_TWO_BACK|G_TWO_SLIDE|G_EDGE_SENS|G_BACK_EXCLUDE|G_TWO_TAP_ACT|G_TWO_LONG_ACT|STORAGE_AUTO|USB_ASK|WIFI_PS|APP_COMPILE|TIME_12_24|GESTURE_HINT|BOOST_MS|BOOST_KHZ|KFB_SCROLLDELAY|KFB_SCROLLSTYLE|KFB_SCROLLWFM|FAST_DRAG|SLEEP_TIMEOUT)
                case "$v" in ''|*[!0-9A-Za-z._,]*) continue ;; esac
                grep -v "^$k=" "$SYS/settings.conf" > "$sfile.conf" 2>/dev/null || true
                [ "$v" = default ] || echo "$k=$v" >> "$sfile.conf"
                mv -f "$sfile.conf" "$SYS/settings.conf"
                [ "$k" = DNS_MODE ] && dns_changed=1
                [ "$k" = TIME_12_24 ] && tf_changed=1 ;;
            SYSTEM_FONT)
                case "$v" in
                    ''|default|none) v= ;;
                    *[\'\"\$\`\\]*) v=bad ;;
                    *) sysfont_host "$v" >/dev/null 2>&1 || v=bad ;;
                esac
                if [ "$v" != bad ]; then
                    grep -v '^SYSTEM_FONT=' "$SYS/settings.conf" > "$sfile.conf" 2>/dev/null || true
                    [ -n "$v" ] && printf "SYSTEM_FONT='%s'\n" "$v" >> "$sfile.conf"
                    mv -f "$sfile.conf" "$SYS/settings.conf"
                fi ;;
        esac
    done < "$sfile"
    rm -f "$sfile" "$sfile.conf"
    settings_load
    settings_publish
    epd_send ANIM "$KFB_ANIM_MODE" "$KFB_ANIM_DIR" "$KFB_ANIM_STEPS" "$KFB_ANIM_MIN"
    epd_send SET "$KFB_CONTRAST" "$KFB_DITHER" "$KFB_FLASH" "$KFB_INVERT" "$KFB_MODE" "$KFB_SETTLE" "${KFB_LIGHTF:-0}" "${KFB_DARKEN:-0}"
    epd_send HOLD "${KFB_HOLD:-70}"
    [ -n "${KFB_REAGL_MIN:-}" ] && epd_send REAGL "$KFB_REAGL_MIN"
    epd_send_scroll
    if [ "$KFB_GESTURES" = 0 ]; then touch "$W/nogestures"; else rm -f "$W/nogestures"; fi
    skia_opt_sync
    gestures_write
    [ "$dns_changed" = 1 ] && ( dns_apply ) </dev/null >>"$LOG" 2>&1 &
    [ "$tf_changed" = 1 ] && type time_format_apply >/dev/null 2>&1 && ( time_format_apply ) </dev/null >>"$LOG" 2>&1 &
    rotate_apply
    status_write
}

epd_send_smooth() {
    epd_send PACE "${KFB_PACE:-0}"
    epd_send CLEAN "${KFB_CLEAN:-0}"
    epd_send REAGL "${KFB_REAGL_MIN:-35}"
    epd_send SCROLLDU "${KFB_SCROLLDU:-0}"
    epd_send IMG "${KFB_IMG:-0}"
    epd_send SCROLLDELAY "${KFB_SCROLLDELAY:-500}"
    epd_send SCROLLSTYLE "${KFB_SCROLLSTYLE:-1}"
    epd_send SCROLLWFM "${KFB_SCROLLWFM:-a2}"
    epd_send GCN "${KFB_GCN:-0}"
    epd_send MONO "${KFB_MONO:-0}"
    epd_send MAXDEFER "${KFB_MAXDEFER:-1200}"
    epd_send FLIPINPUT "${KFB_FLIPINPUT:-1000}"
    epd_send ECLIPSE "${KFB_ECLIPSE:-1}"
    epd_send DARKCRUSH "${KFB_DARKCRUSH:-36}"
    epd_send HEAVYFLASH "${KFB_HEAVY_FLASH:-1}"
}

epd_send_scroll() { epd_send_smooth; }

skia_opt_sync() {
    mkdir -p "$SYS/data/local/tmp" 2>/dev/null || true
    chmod 755 "$SYS/data/local/tmp" 2>/dev/null || true
    if [ "${KFB_SKIA_OPT:-1}" = 0 ]; then
        rm -f "$SYS/data/local/tmp/kobo-skia-all" 2>/dev/null || true
    else
        echo 1 > "$SYS/data/local/tmp/kobo-skia-all" 2>/dev/null || true
        chmod 644 "$SYS/data/local/tmp/kobo-skia-all" 2>/dev/null || true
    fi
    fg_val="${KFB_FONT_GAMMA:-2}"
    case "$fg_val" in 0|1|2|3) ;; *) fg_val=2 ;; esac
    echo "$fg_val" > "$SYS/data/local/tmp/kobo-font-gamma" 2>/dev/null || true
    chmod 644 "$SYS/data/local/tmp/kobo-font-gamma" 2>/dev/null || true
}

gestures_write() {
    gc=
    for c in tl:G_TL tr:G_TR bl:G_BL br:G_BR; do
        eval "a=\$${c#*:}"
        case "$a" in ''|none) ;; *) gc="${gc:+$gc,}${c%%:*}" ;; esac
    done
    {
        for k in G_EDGE_BACK G_EDGE_PANEL G_EDGE_THIRDS G_EB_L G_EB_M G_EB_R G_EB_HOLD G_EB_HOLD_MS G_TWO_TAP G_TWO_LONG G_TWO_BACK G_TWO_SLIDE G_EDGE_SENS G_BACK_EXCLUDE BOOST_MS BOOST_KHZ FAST_DRAG; do
            eval "echo $k=\$$k"
        done
        echo "G_CORNERS=${gc:-none}"
        echo "AUTO_ROTATE=${KFB_AUTO_ROTATE:-0}"
        echo "KEY_SWAP=${PAGE_KEYS_SWAP:-0}"
        echo "ROTATE=$(rot_deg)"
    } > "$W/gestures.tmp" && mv -f "$W/gestures.tmp" "$W/gestures"
}

dns_apply() {
    case "$DNS_MODE" in
        aliyun)  ANDROID_DNS="223.5.5.5 223.6.6.6"; d1=223.5.5.5; d2=223.6.6.6 ;;
        tencent) ANDROID_DNS="119.29.29.29 182.254.116.116"; d1=119.29.29.29; d2=182.254.116.116 ;;
        google)  ANDROID_DNS="8.8.8.8 8.8.4.4"; d1=8.8.8.8; d2=8.8.4.4 ;;
        *)       ANDROID_DNS="223.5.5.5 223.6.6.6"; d1=223.5.5.5; d2=223.6.6.6 ;;
    esac
    hostnet_write 2>/dev/null || true
    pid=$(cat "$W/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && type vd_in >/dev/null 2>&1; then
        P=$pid; $(vd_in) /system/bin/sh -c "export ANDROID_DATA=/data ANDROID_ROOT=/system PATH=/system/bin; ndc resolver setnetdns 100 '' $d1 $d2" >/dev/null 2>&1 || true
    fi
}
