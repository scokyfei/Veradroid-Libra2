# SPDX-License-Identifier: GPL-3.0-or-later
# 看着 Android 开机：把它自己的 boot_progress 事件换成进度条和文字；开机完成（或超时）就放开显示桥。
boot_stage() {   # $1 = 最后一个 boot_progress 事件名（可为空）→ 设 PCT / TXT
    case "$1" in
    boot_progress_enable_screen)   PCT=92; TXT="正在显示桌面" ;;
    boot_progress_ams_ready)       PCT=86; TXT="准备桌面" ;;
    boot_progress_pms_ready)       PCT=78; TXT="准备桌面" ;;
    boot_progress_pms_scan_end)    PCT=72; TXT="应用已就绪" ;;
    boot_progress_pms_data_scan_start) PCT=64; TXT="扫描已安装的应用" ;;
    boot_progress_pms_system_scan_start) PCT=60; TXT="扫描系统应用" ;;
    boot_progress_pms_start)       PCT=57; TXT="启动包管理" ;;
    boot_progress_system_run)      PCT=52; TXT="启动系统服务" ;;
    boot_progress_preload_end)     PCT=48; TXT="启动系统服务" ;;
    boot_progress_preload_start)   PCT=34; TXT="加载常用类库" ;;
    boot_progress_start)           PCT=28; TXT="启动 Android" ;;
    *)                             PCT=20; TXT="正在启动 Android 内核服务" ;;
    esac
}

# 开机画面上“已用时间”每 5 秒走一次；PackageManager 在优化（dexopt）应用时写出是第几个、哪个应用
# （logcat 里 PackageManager.DexOptimizer 的 "Running dexopt … pkg=…"；只在包管理阶段看，过滤到这一个标签，很便宜）
boot_tick() {
    type splash_tick >/dev/null 2>&1 || return 0
    if [ "${PCT:-0}" -ge 57 ] 2>/dev/null && [ "${PCT:-0}" -lt 86 ] 2>/dev/null; then
        dx=$($(vd_in) /system/bin/sh -c 'export PATH=/system/bin; logcat -d -s PackageManager.DexOptimizer 2>/dev/null' 2>/dev/null | grep "Running dexopt")
        if [ -n "$dx" ]; then
            dn=$(printf '%s\n' "$dx" | grep -c .); dp=$(printf '%s\n' "$dx" | tail -n 1 | sed -n 's/.* pkg=\([A-Za-z0-9._]*\).*/\1/p')
            echo "正在优化应用 第 $dn 个 · ${dp:-?}" > $W/splash.dexopt
        fi
    fi
    splash_tick
}
boot_watch() {
    rm -f $W/splash.dexopt
    last=0; n=0; lastev=; forced=; es=0
    # TCG/older-PW5 boots are much slower than PW6 hardware; do not abort at 45 s.
    stall=${KFB_BOOT_TIMEOUT:-150}
    while [ $n -lt 180 ]; do
        n=$((n + 1))
        kill -0 "$P" 2>/dev/null || break
        # tail / sed 在宿主这边做：kindle32 系统镜像的 toybox 没有可用的 tail（PW3 实测 `tail -1` 原样输出全部行），
        # 结果 ev 永远是第一条事件（preload_start），进度卡在 28–34%
        out=$($(vd_in) /system/bin/sh -c 'export PATH=/system/bin; logcat -b events -d 2>/dev/null | grep boot_progress; echo "BC=$(getprop sys.boot_completed)"' 2>/dev/null)
        done_flag=$(echo "$out" | sed -n 's/^BC=//p' | tail -1)
        ev=$(echo "$out" | grep boot_progress | tail -1 | sed "s/.* I \(boot_progress[a-z_]*\).*/\1/")
        case "$ev" in boot_progress*) ;; *) ev= ;; esac
        if [ "$done_flag" = 1 ]; then splash_update 100 "启动完成"; rm -f $W/boot.retry; break; fi
        # 桌面已经亮了（enable_screen），sys.boot_completed 却一直没有（没有 SELinux 的 3.0 内核 + 没打 property_service
        # 补丁的旧系统镜像：setprop 全被 init 拒绝）。亮屏后再等 60 轮还没完成就放开显示，不再干等。
        if [ "$ev" = boot_progress_enable_screen ] && [ -z "$forced" ]; then
            es=$((${es:-0} + 1))
            [ $es -ge 60 ] && { t "boot watch: screen enabled but sys.boot_completed never set: releasing the display"; rm -f $W/boot.retry; break; }
        fi
        boot_stage "$ev"
        # No boot_progress event yet: keep crawling, but never park at 27%
        # forever (the old clamp made a slow/quiet boot look frozen).
        [ -z "$ev" ] && { PCT=$((20 + n / 2)); [ $PCT -gt 45 ] && PCT=45; }
        [ "$PCT" -gt "$last" ] && { [ -n "$forced" ] || splash_update $PCT "$TXT"; last=$PCT; }
        # A quiet/slow boot must not leave the splash stuck forever. If we
        # still have no boot_completed and no late events after 120s, release
        # the display bridge so the user can see Android or the error screen.
        # 放开画面后继续盯着：以前这里直接 break，下面“卡住就重试 / 回 Kindle”的分支永远走不到，
        # 开机失败的设备会停在暂停了 Kindle 界面的空白画面上，只能强制重启。
        if [ -z "$forced" ] && [ $n -ge 60 ] && [ $last -lt 60 ]; then
            splash_update 90 "正在显示桌面"
            splash_end
            forced=1
            t "boot watch: forced splash end after ${n}s (last=$last%)"
        fi
        # 卡在 early boot（27% 左右）时自动回 Kindle 并重试一次；第二次仍失败就停在 Kindle，不再循环
        if [ $n -ge "$stall" ] && [ $last -lt 60 ]; then
            if [ -f $W/boot.retry ]; then
                t "boot stalled again at ${last}%: return to kindle"
                log_release
                sh $VD/boot/stop.sh >/dev/null 2>&1
            else
                touch $W/boot.retry
                t "boot stalled at ${last}% after ${n}s: retry"
                ( log_release; sh $VD/boot/stop.sh >/dev/null 2>&1; setsid sh $VD/boot/veradroid.sh home </dev/null >/tmp/vdretry.out 2>&1 & ) &
            fi
            return
        fi
        [ -n "$forced" ] || boot_tick
        sleep 2
    done
    [ -n "$forced" ] || splash_end
    t "boot watch: done after ${n}s (last=$last%)"
}
