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

_subpid() {
    _sp=
    [ -r /proc/self/stat ] && read -r _sp _ < /proc/self/stat 2>/dev/null || true
    echo "${_sp:-$$}"
}

wifi_list() {
    _tp="$X/ctl/wifi.list.tmp.$(_subpid)"
    cur=$(kobo_wifi_current)
    kobo_wifi_saved | while IFS= read -r n; do
        if [ -n "$cur" ] && [ "$n" = "$cur" ]; then printf '*%s\n' "$n"; else printf ' %s\n' "$n"; fi
    done > "$_tp"
    chmod 644 "$_tp" 2>/dev/null
    mv -f "$_tp" "$X/ctl/wifi.list"
}

wifi_result() {
    _tp="$X/ctl/wifi.result.tmp.$(_subpid)"
    printf '%s\n' "$@" > "$_tp" && chmod 644 "$_tp" 2>/dev/null && mv -f "$_tp" "$X/ctl/wifi.result"
}

wifi_scan() {
    rm -f "$X/ctl/wifi.result" 2>/dev/null || true
    _tp="$X/ctl/wifi.scan.tmp.$(_subpid)"
    kobo_wifi_scan > "$_tp" 2>/dev/null || : > "$_tp"
    chmod 644 "$_tp" 2>/dev/null
    mv -f "$_tp" "$X/ctl/wifi.scan"
}

wifi_connect() {
    rm -f "$X/ctl/wifi.result" 2>/dev/null || true
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
      echo "compile_pending=$cp"; echo "compile_kicked=$ck"; } > "$r.tmp" && chmod 644 "$r.tmp" 2>/dev/null && mv -f "$r.tmp" "$r"
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
        reboot)  do_reboot ;;
        poweroff) do_poweroff ;;
        sleep)   [ -p "$W/power.fifo" ] && ( echo sleep > "$W/power.fifo" ) & ;;
        diag)    ( diag_save; touch "$X/ctl/diag.done"; chmod 644 "$X/ctl/diag.done" 2>/dev/null ) & ;;
        diagexport) ( diag_export ) </dev/null >>"$LOG" 2>&1 & ;;
        cfgbackup)  ( cfg_backup_cmd "$a" ) </dev/null >>"$LOG" 2>&1 & ;;
        offlineupd)
            case "$a" in
                check|'') status_write ;;
                apply|force)
                    ou_hit=$(offline_upd_find || true)
                    if [ -z "$ou_hit" ]; then
                        { echo "ok=0"; echo "error=未检测到离线升级包"; } > "$X/ctl/offlineupd.result.tmp" \
                            && chmod 644 "$X/ctl/offlineupd.result.tmp" 2>/dev/null \
                            && mv -f "$X/ctl/offlineupd.result.tmp" "$X/ctl/offlineupd.result"
                        status_write
                    else
                        _ou_p=${ou_hit%%	*}; _ou_rest=${ou_hit#*	}
                        _ou_v=${_ou_rest%%	*}; _ou_s=${_ou_rest#*	}
                        _ou_bn=${_ou_p##*/}
                        mkdir -p "$VD/update" 2>/dev/null || true
                        _ou_dst="$VD/update/$_ou_bn"
                        _ou_ok=1
                        if [ "$_ou_s" != update ]; then
                            t "offlineupd: staging $_ou_p -> $_ou_dst"
                            if ! cp "$_ou_p" "$_ou_dst.tmp" 2>/dev/null || ! mv -f "$_ou_dst.tmp" "$_ou_dst" 2>/dev/null; then
                                rm -f "$_ou_dst.tmp" 2>/dev/null || true
                                _ou_ok=0
                            fi
                        fi
                        if [ "$_ou_ok" = 1 ] && command -v unzip >/dev/null 2>&1 && ! unzip -lq "$_ou_dst" >/dev/null 2>&1; then
                            [ "$_ou_s" != update ] && rm -f "$_ou_dst" 2>/dev/null || true
                            _ou_ok=0
                            _ou_err="压缩包损坏或下载不完整"
                        fi
                        if [ "$_ou_ok" = 1 ]; then
                            [ "$a" = force ] && touch "$VD/update/.force" 2>/dev/null || rm -f "$VD/update/.force" 2>/dev/null || true
                            [ "$_ou_s" != update ] && rm -f "$_ou_p" 2>/dev/null || true
                            t "offlineupd: applying $_ou_bn (v$_ou_v, mode=$a) via restart"
                            do_restart
                        else
                            { echo "ok=0"; echo "error=${_ou_err:-复制升级包失败（存储空间不足？）}"; } > "$X/ctl/offlineupd.result.tmp" \
                                && chmod 644 "$X/ctl/offlineupd.result.tmp" 2>/dev/null \
                                && mv -f "$X/ctl/offlineupd.result.tmp" "$X/ctl/offlineupd.result"
                        fi
                    fi ;;
            esac ;;
        clear)   epd_send FULL ;;
        screenshot)
            mkdir -p "$SYS/data/media/0/Screenshots"
            sf="$SYS/data/media/0/Screenshots/screen-$(date +%Y%m%d-%H%M%S).png"
            epd_send SHOT "$sf" && t "screenshot saved: $sf" ;;
        fg)      type appprof_fg >/dev/null 2>&1 && appprof_fg "$a"
                 type bgnice_tick >/dev/null 2>&1 && ( sleep 2; bgnice_tick ) </dev/null >>"$LOG" 2>&1 & ;;
        appset)  type appprof_set >/dev/null 2>&1 && appprof_set "$a" ;;
        appdisp)
            if [ "$a" = home ] && type appprof_fg >/dev/null 2>&1; then appprof_fg home; continue; fi
            apkg=${a%%|*}; aspec=${a#*|}
            rm -f "$SYS/settings.app"
            if [ "$apkg" != home ] && [ -n "$aspec" ] && [ "$aspec" != "$a" ]; then
                printf '%s\n' "$aspec" | tr ';' '\n' | grep -E '^KFB_(CONTRAST|DITHER|FLASH|INVERT|LIGHTF|DARKEN|MODE|SETTLE|HOLD|SMOOTH|PACE|CLEAN|REAGL_MIN|SCROLLDU|IMG|SCROLLDELAY|SCROLLSTYLE|GCN|NEWWIN|MONO|MAXDEFER|FLIPINPUT|ECLIPSE|DARKCRUSH|HEAVY_FLASH|IMG_DITHER|ANIM_MODE|ANIM_DIR|ANIM_STEPS|ANIM_MIN)=[0-9.]{1,6}$' > "$SYS/settings.app.tmp"
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
        autorot)
            case "$a" in 0|90|180|270)
                touch "$SYS/settings.conf"
                grep -v "^KFB_ROTATE=" "$SYS/settings.conf" > "$SYS/settings.conf.tmp" 2>/dev/null || true
                echo "KFB_ROTATE=$a" >> "$SYS/settings.conf.tmp"; mv -f "$SYS/settings.conf.tmp" "$SYS/settings.conf"
                echo "$a" > "$W/rotate"
                settings_load; settings_publish; gestures_write ;;
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
                rm -f "$X/ctl/uninst.$a" "$X/ctl/uninst.$a.tmp" 2>/dev/null || true
                ( type compile_hold >/dev/null 2>&1 && compile_hold
                  r=$(adb_sh "cmd package uninstall --user 0 $a" 2>&1 | tr '\n' ' ')
                  type compile_release >/dev/null 2>&1 && compile_release
                  printf '%s\n' "$r" > "$X/ctl/uninst.$a.tmp" && chmod 644 "$X/ctl/uninst.$a.tmp" 2>/dev/null
                  mv -f "$X/ctl/uninst.$a.tmp" "$X/ctl/uninst.$a" ) & ;;
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
                rm -f "$X/ctl/inst.$iname" "$X/ctl/inst.$iname.tmp" 2>/dev/null || true
                ( upload_dir_fix 2>/dev/null; chmod 777 "$SYS/data/local/tmp" 2>/dev/null
                  type compile_hold >/dev/null 2>&1 && compile_hold
                  sz=$(stat -c%s "$SYS$ipath" 2>/dev/null)
                  read -r ipid _ < /proc/self/stat; alive "$W/installing" || echo "$ipid" > "$W/installing"
                  r=$(adb_sh "cmd package install -r -d -g -S $sz < $ipath" 2>&1 | tr '\n' ' ')
                  [ "$(cat "$W/installing" 2>/dev/null)" = "$ipid" ] && rm -f "$W/installing"
                  adb_sh 'cmd package set-home-activity com.veradroid.home/.HomeActivity' >/dev/null 2>&1 || true
                  printf '%s\n' "$r" > "$X/ctl/inst.$iname.tmp" && chmod 644 "$X/ctl/inst.$iname.tmp" 2>/dev/null
                  mv -f "$X/ctl/inst.$iname.tmp" "$X/ctl/inst.$iname"
                  type compile_release >/dev/null 2>&1 && compile_release
                  case "$r" in *Success*) type compile_watch >/dev/null 2>&1 && compile_watch ;; esac ) &
            fi ;;
        saver)   type saver_cmd >/dev/null 2>&1 && saver_cmd "$a" ;;
        storage)
            type st_cmd >/dev/null 2>&1 && case "$a" in
                info) ( st_cmd info ) & ;;
                "resize "*) sa=${a#resize }; st_num "$sa" && ( st_cmd resize "$sa" ) & ;;
                "auto on"|"auto off") st_cmd auto "${a#auto }" ;;
            esac ;;
        wa)      type wa_request >/dev/null 2>&1 && wa_request "$a" ;;
        compile) type compile_cmd >/dev/null 2>&1 && compile_cmd "$a" ;;
        wrmaint) ( wrmaint_cmd "$a" ) </dev/null >>"$LOG" 2>&1 & ;;
        optimize) ( opt_run ) & ;;
        poke)    touch "$W/lastinput" "$X/lasttouch" 2>/dev/null || true; chmod 644 "$X/lasttouch" 2>/dev/null || true ;;
        wifi)
            case "$a" in
                0|1) ( kobo_wifi_set "$a"; [ "$a" = 1 ] && { hostnet_write 2>/dev/null || true; dns_apply 2>/dev/null || true; }; status_write ) </dev/null >>"$LOG" 2>&1 & ;;
                *)   status_write ;;
            esac ;;
        wifilist) ( wifi_list ) & ;;
        wifiscan) ( wifi_scan ) & ;;
        wificonnect) ( wifi_connect "$a" ) & ;;
        bt)      type bt_cmd >/dev/null 2>&1 && bt_cmd "$a" ;;
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

wrmaint_status() {
    _ma=$(awk '/^MemAvailable:/{printf "%.1f MB", $2/1024}' /proc/meminfo 2>/dev/null)
    _zr=$(awk '{printf "%.1f MB", $1/1024/1024}' /sys/block/zram0/compr_data_size 2>/dev/null)
    _cf=$(awk '{printf "%d MHz", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)
    _lps=$(awk '/LPS mode:/{sub(/.*LPS mode:[[:space:]]*/, ""); sub(/[[:space:]]*\(.*/, ""); print; exit}' /proc/net/rtl8723ds/wlan0/ps_info 2>/dev/null)
    _usb="已关闭"
    if type usb_mtp_active >/dev/null 2>&1 && usb_mtp_active; then
        _usb="已连接电脑"
    elif type usb_mtp_running >/dev/null 2>&1 && usb_mtp_running; then
        _usb="已就绪"
    fi
    _bt="关"
    if type bt_is_on >/dev/null 2>&1 && bt_is_on; then
        _ba=$(cat "$W/bt.audio.name" 2>/dev/null)
        if [ -n "$_ba" ] && alive "$W/bt-audio.pid"; then
            _bt="开（音频：$_ba）"
        else
            _bt="开"
        fi
    fi
    _wr="$SYS/data/data/com.tencent.weread.eink"
    _has_wr=0
    [ -d "$_wr" ] && _has_wr=1
    {
        echo "可用内存：${_ma:-?}（ZRAM 已压缩：${_zr:-0 MB}）"
        echo "当前 CPU 上限：${_cf:-?}（静止限频：${IDLE_CAP_MS:-10000}ms / $(( ${IDLE_CAP_KHZ:-792000} / 1000 ))MHz）"
        echo "USB MTP：${_usb}　|　蓝牙：${_bt}　|　Wi-Fi LPS：${_lps:-auto}"
        echo "笔锋加黑档位：${KFB_FONT_GAMMA:-2}　|　插图智能抖动：${KFB_IMG_DITHER:-1}　|　息灯超时：${FL_TIMEOUT:-0} 秒"
        if [ "$_has_wr" = 1 ]; then
            _odex=$(ls -lh "$SYS"/data/app/com.tencent.weread.eink-*/oat/arm/base.odex 2>/dev/null | awk 'NR==1{print $5}')
            _wal_b=0
            for _wf in "$_wr"/databases/*-wal "$_wr"/databases/*/*-wal; do
                [ -f "$_wf" ] || continue
                _sz=$(wc -c < "$_wf" 2>/dev/null || echo 0)
                _wal_b=$((_wal_b + _sz))
            done
            _wal_kb=$((_wal_b / 1024))
            _log_mb=$(du -sm "$_wr/files/log" 2>/dev/null | awk '{print $1}')
            _zip_mb=$(du -sm "$_wr/cache/downloader" 2>/dev/null | awk '{print $1}')
            echo "微信读书热点包 (base.odex)：${_odex:-未编译}"
            echo "微信读书 WAL：${_wal_kb} KB　|　日志：${_log_mb:-0} MB　|　残包：${_zip_mb:-0} MB"
        fi
    } > "$X/wrmaint.txt.tmp" && mv -f "$X/wrmaint.txt.tmp" "$X/wrmaint.txt"
}

wrmaint_cmd() {
    case "$1" in
        wal)
            echo "正在清理微信读书日志/安装残包并压缩 SQLite WAL..." > "$X/wrmaint.txt"
            _wr="$SYS/data/data/com.tencent.weread.eink"
            rm -rf "$_wr/files/log"/* \
                   "$_wr/files/logs"/* \
                   "$_wr/files/BusReport"/* \
                   "$_wr/files"/wr.log.* \
                   "$_wr/cache/downloader"/*.zip 2>/dev/null || true
            _lua=/mnt/onboard/.adds/koreader/luajit
            _sql=
            for _cand in /mnt/onboard/.adds/koreader/libs/libsqlite3.so.0 /mnt/onboard/.adds/koreader/libs/libsqlite3.so /usr/lib/libsqlite3.so.0; do
                [ -f "$_cand" ] && { _sql=$_cand; break; }
            done
            if [ -x "$_lua" ] && [ -n "$_sql" ]; then
                for _f in "$_wr"/databases/WRAccount "$_wr"/databases/*/WRBook "$_wr"/databases/*/WRReader "$_wr"/databases/WRBook "$_wr"/databases/WRReader; do
                    [ -f "$_f" ] || continue
                    WR_DB="$_f" "$_lua" -e '
                        local ffi = require("ffi")
                        ffi.cdef[[int sqlite3_open(const char*, void**); int sqlite3_exec(void*, const char*, void*, void*, char**); int sqlite3_close(void*);]]
                        local sq = ffi.load("'"$_sql"'")
                        local p = ffi.new("void*[1]")
                        if sq.sqlite3_open(os.getenv("WR_DB"), p) == 0 then
                            sq.sqlite3_exec(p[0], "PRAGMA busy_timeout=1500; PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize;", nil, nil, nil)
                            sq.sqlite3_close(p[0])
                        end
                    ' 2>/dev/null || true
                done
            fi
            wrmaint_status
            echo "✔ 日志/残包清理与数据库 WAL 压缩已完成" >> "$X/wrmaint.txt"
            [ -p "$X/epd.fifo" ] && echo "BADGE 1200 t clear DONE|微信读书维护完成" > "$X/epd.fifo" 2>/dev/null || true
            ;;
        profile)
            echo "正在采集热点并刷新微信读书 speed-profile 编译（后台执行约 1–2 分钟）..." > "$X/wrmaint.txt"
            if [ -f "$VD/boot/weread-speed-profile.sh" ]; then
                sh "$VD/boot/weread-speed-profile.sh" >>"$LOG" 2>&1 || true
            elif [ -f "$VD/tools/weread-speed-profile.sh" ]; then
                sh "$VD/tools/weread-speed-profile.sh" >>"$LOG" 2>&1 || true
            elif type weread_profile_refresh >/dev/null 2>&1; then
                weread_profile_refresh >>"$LOG" 2>&1 || true
            fi
            wrmaint_status
            echo "✔ 微信读书热点加速编译已刷新" >> "$X/wrmaint.txt"
            [ -p "$X/epd.fifo" ] && echo "BADGE 1200 t clear DONE|热点编译刷新完成" > "$X/epd.fifo" 2>/dev/null || true
            ;;
        *)
            wrmaint_status
            ;;
    esac
}

# ---- One-tap Configuration Backup & Restore ($VD/backup/veradroid-cfg-*.tar.gz) ----

cfg_backup_write_result() {
    _tmp="$X/ctl/cfgbackup.result.tmp.$$"
    : > "$_tmp"
    for _kv in "$@"; do printf '%s\n' "$_kv" >> "$_tmp"; done
    chmod 644 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$X/ctl/cfgbackup.result" 2>/dev/null || rm -f "$_tmp"
}

cfg_backup_list() {
    mkdir -p "$VD/backup" 2>/dev/null || true
    _tmp="$X/ctl/cfgbackup.list.tmp.$$"
    : > "$_tmp"
    for _f in $(ls -1t "$VD/backup"/veradroid-cfg-*.tar.gz 2>/dev/null); do
        [ -f "$_f" ] || continue
        _bn=${_f##*/}
        _kb=$(( ($(wc -c < "$_f" 2>/dev/null || echo 0) + 1023) / 1024 ))
        _dt=$(printf '%s' "$_bn" | sed -n 's/^veradroid-cfg-\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)[0-9]\{2\}\.tar\.gz$/\1-\2-\3 \4:\5/p')
        printf '%s\t%s\t%s\n' "$_bn" "$_kb" "${_dt:-$_bn}" >> "$_tmp"
    done
    chmod 644 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$X/ctl/cfgbackup.list" 2>/dev/null || rm -f "$_tmp"
}

cfg_backup_save() {
    mkdir -p "$VD/backup" 2>/dev/null || true
    _ts=$(date +%Y%m%d-%H%M%S)
    _bn="veradroid-cfg-${_ts}.tar.gz"
    _st="/tmp/vd-cfg-save.$$"
    rm -rf "$_st"
    mkdir -p "$_st/prefs" 2>/dev/null || { cfg_backup_write_result ok=0 op=save "error=无法创建临时目录"; return 1; }
    {
        echo "time=$(date '+%F %T')"
        echo "version=$(head -1 "$VD/VERSION" 2>/dev/null)"
        echo "model=libra2"
    } > "$_st/meta.txt"
    [ -f "$SYS/settings.conf" ] && cp "$SYS/settings.conf" "$_st/settings.conf" 2>/dev/null || true
    [ -f "$SYS/settings.apps" ] && cp "$SYS/settings.apps" "$_st/settings.apps" 2>/dev/null || true
    [ -f "$SYS/data/media/0/Screensaver/.vd-saver" ] && cp "$SYS/data/media/0/Screensaver/.vd-saver" "$_st/vd-saver" 2>/dev/null || true
    _sp="$SYS/data/data/com.veradroid.home/shared_prefs"
    if [ -d "$_sp" ]; then
        for _xml in "$_sp"/*.xml; do
            [ -f "$_xml" ] || continue
            case "${_xml##*/}" in
                *token*|*lock*|*pin*) continue ;;
            esac
            cp "$_xml" "$_st/prefs/" 2>/dev/null || true
        done
    fi
    _out="$VD/backup/$_bn"
    if tar -czf "$_out.tmp" -C "$_st" . 2>/dev/null && mv -f "$_out.tmp" "$_out" 2>/dev/null; then
        # Keep newest 10 config backups
        _cnt=0
        for _old in $(ls -1t "$VD/backup"/veradroid-cfg-*.tar.gz 2>/dev/null); do
            _cnt=$((_cnt + 1))
            [ "$_cnt" -gt 10 ] && rm -f "$_old" 2>/dev/null || true
        done
        _kb=$(( ($(wc -c < "$_out" 2>/dev/null || echo 0) + 1023) / 1024 ))
        cfg_backup_list
        cfg_backup_write_result ok=1 op=save "file=$_bn" "size_kb=$_kb" "ts=$(date +%s)"
        t "cfgbackup: saved $_out (${_kb} KB)"
    else
        rm -f "$_out.tmp" 2>/dev/null || true
        cfg_backup_write_result ok=0 op=save "error=保存配置备份失败（检查存储空间）"
        t "cfgbackup: failed to write $_out"
    fi
    rm -rf "$_st" 2>/dev/null || true
}

cfg_backup_name_ok() {
    printf '%s\n' "$1" | grep -qE '^veradroid-cfg-[0-9]{8}-[0-9]{6}\.tar\.gz$'
}

cfg_backup_restore() {
    _bn=$1
    if ! cfg_backup_name_ok "$_bn" || [ ! -f "$VD/backup/$_bn" ]; then
        cfg_backup_write_result ok=0 op=restore "error=备份文件不存在或名称无效"
        return 1
    fi
    _st="/tmp/vd-cfg-restore.$$"
    rm -rf "$_st" && mkdir -p "$_st"
    if ! tar -xzf "$VD/backup/$_bn" -C "$_st" 2>/dev/null; then
        rm -rf "$_st"
        cfg_backup_write_result ok=0 op=restore "error=解压备份失败（文件已损坏）"
        return 1
    fi
    [ -f "$_st/settings.conf" ] && cp -f "$_st/settings.conf" "$SYS/settings.conf" 2>/dev/null || true
    [ -f "$_st/settings.apps" ] && cp -f "$_st/settings.apps" "$SYS/settings.apps" 2>/dev/null || true
    if [ -f "$_st/vd-saver" ]; then
        mkdir -p "$SYS/data/media/0/Screensaver" 2>/dev/null || true
        cp -f "$_st/vd-saver" "$SYS/data/media/0/Screensaver/.vd-saver" 2>/dev/null || true
        chmod 644 "$SYS/data/media/0/Screensaver/.vd-saver" 2>/dev/null || true
    fi
    _sp="$SYS/data/data/com.veradroid.home/shared_prefs"
    if [ -d "$_st/prefs" ] && [ -d "$_sp" ]; then
        _own=$(stat -c '%u:%g' "$_sp" 2>/dev/null || true)
        for _xml in "$_st/prefs"/*.xml; do
            [ -f "$_xml" ] || continue
            case "${_xml##*/}" in *token*|*lock*|*pin*|*/*) continue ;; esac
            cp -f "$_xml" "$_sp/${_xml##*/}" 2>/dev/null || true
            [ -n "$_own" ] && chown "$_own" "$_sp/${_xml##*/}" 2>/dev/null || true
            chmod 660 "$_sp/${_xml##*/}" 2>/dev/null || true
        done
    fi
    rm -rf "$_st" 2>/dev/null || true
    # Apply restored host settings immediately
    settings_load 2>/dev/null || true
    settings_publish 2>/dev/null || true
    type appprof_publish >/dev/null 2>&1 && appprof_publish
    epd_send ANIM "$KFB_ANIM_MODE" "$KFB_ANIM_DIR" "$KFB_ANIM_STEPS" "$KFB_ANIM_MIN" 2>/dev/null || true
    epd_send SET "$KFB_CONTRAST" "$KFB_DITHER" "$KFB_FLASH" "$KFB_INVERT" "$KFB_MODE" "$KFB_SETTLE" "${KFB_LIGHTF:-0}" "${KFB_DARKEN:-0}" 2>/dev/null || true
    epd_send HOLD "${KFB_HOLD:-70}" 2>/dev/null || true
    epd_send_scroll 2>/dev/null || true
    skia_opt_sync 2>/dev/null || true
    gestures_write 2>/dev/null || true
    status_write 2>/dev/null || true
    cfg_backup_write_result ok=1 op=restore "file=$_bn" "ts=$(date +%s)"
    t "cfgbackup: restored $_bn"
}

cfg_backup_delete() {
    _bn=$1
    if ! cfg_backup_name_ok "$_bn" || [ ! -f "$VD/backup/$_bn" ]; then
        cfg_backup_write_result ok=0 op=delete "error=备份文件不存在"
        return 1
    fi
    rm -f "$VD/backup/$_bn" 2>/dev/null || true
    cfg_backup_list
    cfg_backup_write_result ok=1 op=delete "file=$_bn" "ts=$(date +%s)"
    t "cfgbackup: deleted $_bn"
}

cfg_backup_cmd() {
    set -- $1
    case "$1" in
        save)    cfg_backup_save ;;
        list)    cfg_backup_list ;;
        restore) cfg_backup_restore "$2" ;;
        delete)  cfg_backup_delete "$2" ;;
        *)       cfg_backup_list ;;
    esac
}
