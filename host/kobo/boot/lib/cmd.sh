# SPDX-License-Identifier: GPL-3.0-or-later
# Host command listener ($X/ctl/cmd) for VeraDroid on Kobo Libra 2.

numeric() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
[ -f "$VD/boot/lib/appprof.sh" ] && . "$VD/boot/lib/appprof.sh"

fwd_off() { rm -f "$W/fwd.id"; }
fwd_on() {
    upload_dir_fix 2>/dev/null || true
    # Shared host network (wlan0) has no firewall blocking LAN ports on Kobo
    echo "host:$1" > "$W/fwd.id"
    t "fwd: port $1 reachable directly on $(kobo_wifi_ip):$1 (hostnet)"
}

rotate_apply() {
    [ -f "$W/rotate" ] || return 0
    rnew=$(rot_deg); rold=$(cat "$W/rotate" 2>/dev/null); [ -n "$rold" ] || rold=0
    [ "$rnew" = "$rold" ] && return 0
    if [ $((rnew % 180)) = $((rold % 180)) ] && [ -f "$W/rotate.live" ] && alive "$W/input.pid" && alive "$W/epd.pid"; then
        gestures_write
        epd_send ROT "$rnew"
        echo "$rnew" > "$W/rotate"
        t "rotate $rold -> $rnew (live)"
    else
        t "rotate $rold -> $rnew: restarting Android"
        do_restart
    fi
}

wifi_list() {
    cur=$(kobo_wifi_current)
    kobo_wifi_saved | while IFS= read -r n; do
        if [ -n "$cur" ] && [ "$n" = "$cur" ]; then printf '*%s\n' "$n"; else printf ' %s\n' "$n"; fi
    done > "$X/ctl/wifi.list.tmp"
    mv -f "$X/ctl/wifi.list.tmp" "$X/ctl/wifi.list"
}

wifi_result() { printf '%s\n' "$@" > "$X/ctl/wifi.result.tmp" && mv -f "$X/ctl/wifi.result.tmp" "$X/ctl/wifi.result"; }

wifi_scan() {
    kobo_wifi_scan > "$X/ctl/wifi.scan.tmp" 2>/dev/null || : > "$X/ctl/wifi.scan.tmp"
    chmod 644 "$X/ctl/wifi.scan.tmp" 2>/dev/null
    mv -f "$X/ctl/wifi.scan.tmp" "$X/ctl/wifi.scan"
}

wifi_connect() {
    hex=$1
    case "$hex" in ''|*[!0-9a-f]*) wifi_result ok=0 "error=bad name"; return 1 ;; esac
    want=$(printf "$(printf '%s' "$hex" | sed 's/../\\x&/g')")
    psk=
    if [ -f "$W/wifi.psk" ]; then
        read -r phn php < "$W/wifi.psk" 2>/dev/null || true
        rm -f "$W/wifi.psk"
        if [ "$phn" = "$hex" ] && [ -n "$php" ]; then
            psk=$(printf "$(printf '%s' "$php" | sed 's/../\\x&/g')")
        fi
    fi
    ok_sel=0
    if [ -n "$psk" ]; then
        kobo_wifi_connect_new "$want" "$psk" && ok_sel=1
    elif kobo_wifi_select "$want"; then
        ok_sel=1
    else
        # Open network not yet saved
        kobo_wifi_connect_new "$want" "" && ok_sel=1
    fi
    if [ "$ok_sel" = 1 ]; then
        i=0
        while [ $i -lt 25 ]; do
            sleep 1; i=$((i + 1))
            [ "$(kobo_wifi_current)" = "$want" ] && [ -n "$(kobo_wifi_ip)" ] && break
        done
        if [ "$(kobo_wifi_current)" = "$want" ]; then
            hostnet_write 2>/dev/null || true
            wifi_result ok=1 "essid=$hex"
        else
            wifi_result ok=0 "error=timeout" "essid=$hex"
        fi
    else
        wifi_result ok=0 "error=create" "essid=$hex"
    fi
    wifi_list; status_write
}

opt_run() {
    r=$X/ctl/optimize.result
    b=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
    sync
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
    [ -w /proc/sys/vm/compact_memory ] && echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
    a=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
    zo=; zc=
    if [ -r /sys/block/zram0/mm_stat ]; then
        set -- $(cat /sys/block/zram0/mm_stat)
        zo=$(( ${1:-0} / 1048576 )); zc=$(( ${2:-0} / 1048576 ))
    fi
    cp=0; [ -s "$W/compile.queue" ] && cp=$(wc -l < "$W/compile.queue" | tr -d ' ')
    ck=0
    if [ "$cp" -gt 0 ] && kobo_is_charging && type compile_kick >/dev/null 2>&1; then compile_kick; ck=1; fi
    { echo "before=$b"; echo "after=$a"; echo "zram_orig_mb=$zo"; echo "zram_compr_mb=$zc"
      echo "compile_pending=$cp"; echo "compile_kicked=$ck"; } > "$r.tmp" && mv -f "$r.tmp" "$r"
    t "optimize: MemAvailable $b -> $a MB, zram ${zo:-?}/${zc:-?} MB"
}

cmd_listen() {
    mkdir -p "$X/ctl"
    cmdfifo=$X/ctl/cmd
    i=0
    while [ ! -p "$cmdfifo" ] && [ $i -lt 20 ]; do
        rm -f "$cmdfifo"; mkfifo "$cmdfifo" 2>/dev/null || true; i=$((i + 1))
        [ -p "$cmdfifo" ] || usleep 100000
    done
    [ -p "$cmdfifo" ] || { t "cmd: cannot create $cmdfifo"; return 1; }
    chmod 666 "$cmdfifo"
    exec 3<>"$cmdfifo"
    while :; do
        read -r c a <&3 || { usleep 300000; continue; }
        case "$c" in
        exit)    do_exit ;;
        stop)    do_stop ;;
        restart) do_restart ;;
        diag)    ( diag_save; touch "$X/ctl/diag.done" ) & ;;
        clear)   epd_send FULL ;;
        screenshot)
            mkdir -p "$SYS/data/media/0/Screenshots"
            $(vd_in) /system/bin/screencap -p "/data/media/0/Screenshots/screen-$(date +%Y%m%d-%H%M%S).png" >/dev/null 2>&1 && t "screenshot saved" ;;
        fg)      type appprof_fg >/dev/null 2>&1 && appprof_fg "$a"
                 type bgnice_tick >/dev/null 2>&1 && ( sleep 2; bgnice_tick ) </dev/null >>"$LOG" 2>&1 & ;;
        appset)  type appprof_set >/dev/null 2>&1 && appprof_set "$a" ;;
        appdisp)
            if [ "$a" = home ] && type appprof_fg >/dev/null 2>&1; then appprof_fg home; continue; fi
            apkg=${a%%|*}; aspec=${a#*|}
            rm -f "$SYS/settings.app"
            if [ "$apkg" != home ] && [ -n "$aspec" ] && [ "$aspec" != "$a" ]; then
                printf '%s\n' "$aspec" | tr ';' '\n' | grep -E '^KFB_(CONTRAST|DITHER|FLASH|INVERT|LIGHTF|DARKEN|MODE|SETTLE|HOLD|SMOOTH|PACE|CLEAN|REAGL_MIN|ANIM_MODE|ANIM_DIR|ANIM_STEPS|ANIM_MIN)=[0-9.]{1,6}$' > "$SYS/settings.app.tmp"
                [ -s "$SYS/settings.app.tmp" ] && mv -f "$SYS/settings.app.tmp" "$SYS/settings.app" || rm -f "$SYS/settings.app.tmp"
            fi
            settings_load 2>/dev/null || true
            settings_publish
            epd_send SET "$KFB_CONTRAST" "$KFB_DITHER" "$KFB_FLASH" "$KFB_INVERT" "$KFB_MODE" "$KFB_SETTLE" "${KFB_LIGHTF:-0}" "${KFB_DARKEN:-0}"
            epd_send HOLD "${KFB_HOLD:-70}"
            epd_send_scroll
            echo "$apkg" > "$W/appprof.pkg" ;;
        status)  status_write ;;
        apply)   settings_apply ;;
        rotate)
            case "$a" in 0|90|180|270)
                touch "$SYS/settings.conf"
                grep -v "^KFB_ROTATE=" "$SYS/settings.conf" > "$SYS/settings.conf.tmp" 2>/dev/null || true
                echo "KFB_ROTATE=$a" >> "$SYS/settings.conf.tmp"; mv -f "$SYS/settings.conf.tmp" "$SYS/settings.conf"
                settings_load; settings_publish; rotate_apply ;;
            esac ;;
        invert)
            cur=$(sed -n 's/^KFB_INVERT=//p' "$X/settings" 2>/dev/null); [ "$cur" = 1 ] && n=0 || n=1
            echo "KFB_INVERT=$n" > "$X/ctl/settings.new"; settings_apply ;;
        light)   numeric "$a" && kobo_light_set "$a" && status_write ;;
        warmth)  numeric "$a" && kobo_warmth_set "$a" && status_write ;;
        sleeptime)
            if numeric "$a"; then
                touch "$SYS/settings.conf"
                grep -v "^SLEEP_TIMEOUT=" "$SYS/settings.conf" > "$SYS/settings.conf.tmp" 2>/dev/null || true
                echo "SLEEP_TIMEOUT=$a" >> "$SYS/settings.conf.tmp"; mv -f "$SYS/settings.conf.tmp" "$SYS/settings.conf"
                SLEEP_TIMEOUT=$a; status_write
            fi ;;
        fwd)     numeric "$a" && fwd_on "$a" ;;
        fwdoff)  fwd_off ;;
        appdirs)
            case "$a" in ''|*[!A-Za-z0-9._]*) ;; *)
                mkdir -p "$SYS/data/media/0/WeRead" "$SYS/data/media/0/Download" "$SYS/data/media/0/Android/data/$a" 2>/dev/null
                chmod 777 "$SYS/data/media/0" "$SYS/data/media/0/WeRead" "$SYS/data/media/0/Download" "$SYS/data/media/0/Android/data/$a" 2>/dev/null ;;
            esac ;;
        uninstallapp)
            case "$a" in ''|*[!A-Za-z0-9._]*) ;; *)
                ( type compile_hold >/dev/null 2>&1 && compile_hold
                  r=$(adb_sh "cmd package uninstall --user 0 $a" 2>&1 | tr '\n' ' ')
                  type compile_release >/dev/null 2>&1 && compile_release
                  echo "$r" > "$X/ctl/uninst.$a.tmp"; mv -f "$X/ctl/uninst.$a.tmp" "$X/ctl/uninst.$a" ) & ;;
            esac ;;
        install)
            case "$a" in
              /data/local/tmp/*|/data/media/0/.upload/*|/data/data/com.veradroid.home/files/upload/*) ipath=$a ;;
              ''|*[!A-Za-z0-9._]*) ipath= ;;
              *) ipath=/data/media/0/.upload/$a ;;
            esac
            case "$ipath" in *[!A-Za-z0-9._/-]*|*..*) ipath= ;; esac
            if [ -n "$ipath" ]; then
                iname=${ipath##*/}
                ( upload_dir_fix 2>/dev/null; chmod 777 "$SYS/data/local/tmp" 2>/dev/null
                  type compile_hold >/dev/null 2>&1 && compile_hold
                  sz=$(stat -c%s "$SYS$ipath" 2>/dev/null)
                  read -r ipid _ < /proc/self/stat; alive "$W/installing" || echo "$ipid" > "$W/installing"
                  r=$(adb_sh "cmd package install -r -d -g -S $sz < $ipath" 2>&1 | tr '\n' ' ')
                  [ "$(cat "$W/installing" 2>/dev/null)" = "$ipid" ] && rm -f "$W/installing"
                  adb_sh 'cmd package set-home-activity com.veradroid.home/.HomeActivity' >/dev/null 2>&1 || true
                  echo "$r" > "$X/ctl/inst.$iname.tmp"; mv -f "$X/ctl/inst.$iname.tmp" "$X/ctl/inst.$iname"
                  type compile_release >/dev/null 2>&1 && compile_release
                  case "$r" in *Success*) type compile_watch >/dev/null 2>&1 && compile_watch ;; esac ) &
            fi ;;
        saver)   type saver_cmd >/dev/null 2>&1 && saver_cmd "$a" ;;
        netdiag) type vp_netdiag >/dev/null 2>&1 && ( vp_netdiag "$X/ctl/netdiag.status" ) </dev/null >/dev/null 2>&1 & ;;
        storage)
            type st_cmd >/dev/null 2>&1 && case "$a" in
                info) ( st_cmd info ) & ;;
                "resize "*) sa=${a#resize }; st_num "$sa" && ( st_cmd resize "$sa" ) & ;;
                "auto on"|"auto off") st_cmd auto "${a#auto }" ;;
            esac ;;
        wa)      type wa_request >/dev/null 2>&1 && wa_request "$a" ;;
        compile) type compile_cmd >/dev/null 2>&1 && compile_cmd "$a" ;;
        optimize) ( opt_run ) & ;;
        poke)    touch "$W/lastinput" 2>/dev/null || true ;;
        wifi)    status_write ;;
        wifilist) ( wifi_list ) & ;;
        wifiscan) ( wifi_scan ) & ;;
        wificonnect) ( wifi_connect "$a" ) & ;;
        dns)
            case "$a" in
                auto|aliyun|tencent|google)
                    touch "$SYS/settings.conf"
                    grep -v "^DNS_MODE=" "$SYS/settings.conf" > "$SYS/settings.conf.tmp" 2>/dev/null || true
                    echo "DNS_MODE=$a" >> "$SYS/settings.conf.tmp"; mv -f "$SYS/settings.conf.tmp" "$SYS/settings.conf"
                    settings_load; settings_publish; dns_apply ;;
            esac ;;
        esac
    done
}
