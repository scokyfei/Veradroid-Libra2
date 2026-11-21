# SPDX-License-Identifier: GPL-3.0-or-later
# 看门狗：每 10 秒看一次容器还在不在。桌面的命令走 lib/cmd.sh 的 FIFO（即时），这里只留旧的“命令文件”作后备：
#   $X/ctl/exit 返回 Kindle   $X/ctl/stop 关机   $X/ctl/restart 只重启系统   $X/ctl/diag 存诊断日志
# 诊断日志：存进 Android 存储的 Diagnostics/<时间>/，不含书的文件
diag_save() {
    d=$SYS/data/media/0/Diagnostics/$(date +%Y%m%d-%H%M%S)
    mkdir -p $d && chmod 777 $SYS/data/media/0/Diagnostics $d 2>/dev/null
    {
        echo "VeraDroid diagnostics (Kobo Libra 2)"
        date
        echo "model=$(cat $SYS/model 2>/dev/null)"
        echo "version=$(cat $SYS/version 2>/dev/null)"
        echo "firmware=$(kobo_firmware 2>/dev/null)"
        echo "mode=$(cat $W/mode 2>/dev/null || echo chroot)"
        echo "kernel=$(uname -a 2>/dev/null)"
        echo "cmdline=$(cat /proc/cmdline 2>/dev/null)"
        echo "soc=$(cat /proc/device-tree/compatible 2>/dev/null | tr '\0' ' ')"
        echo "fb=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
        echo "battery=$(kobo_batt_cap 2>/dev/null)"
    } > $d/README.txt 2>/dev/null
    cp $LOG $d/veradroid.log 2>/dev/null
    cp $W/epd.log $d/epd.log 2>/dev/null
    cp $W/input.log $d/input.log 2>/dev/null
    # 停止 / 安装的记录不在 veradroid.log 里：用户诊断 里更新后有一次“启动后 10 秒被停掉、再点启动 20 分钟没反应”，
    # 当时 stop.sh 和安装器写了什么没有带上来
    tail -c 65536 /tmp/veradroid-stop.log > $d/stop.log 2>/dev/null
    # 诊断包里的文件名照旧（veradroid-install.log 等）：新位置 veradroid/logs/ 没有就取根目录老版本写的那份   (root-legacy: 只是诊断包里的名字)
    for f in install install-detail uninstall autoupdate fsck localupdate; do
        dsl=$VD/logs/$f.log
        [ -f "$dsl" ] && tail -c 65536 "$dsl" | tr '\r' '\n' | grep -av '下载中' > "$d/veradroid-$f.log" 2>/dev/null
    done
    ls -la $VD/apps $VD/update 2>/dev/null > $d/kobo-apps-folder.txt
    # Full host-side picture, not a 300-line tail.
    dmesg > $d/kobo-dmesg.txt 2>/dev/null
    cat /proc/last_kmsg > $d/kobo-last_kmsg.txt 2>/dev/null
    cat /proc/meminfo > $d/kobo-meminfo.txt 2>/dev/null
    cat /proc/loadavg > $d/kobo-loadavg.txt 2>/dev/null
    cat /proc/interrupts > $d/kobo-interrupts.txt 2>/dev/null
    cat /proc/diskstats > $d/kobo-diskstats.txt 2>/dev/null
    cat /proc/mounts > $d/kobo-mounts.txt 2>/dev/null
    ps > $d/kobo-ps.txt 2>/dev/null
    df -h > $d/kobo-df.txt 2>/dev/null
    free > $d/kobo-free.txt 2>/dev/null
    for f in version cmdline cpuinfo partitions filesystems modules devices buddyinfo vmstat zoneinfo slabinfo pagetypeinfo softirqs locks keys; do
        cat /proc/$f > $d/kobo-proc-$f.txt 2>/dev/null
    done
    cp -a /sys/fs/pstore "$d/kobo-pstore" 2>/dev/null || true
    for f in /var/log/messages /var/log/syslog; do
        [ -f "$f" ] && cp "$f" "$d/host-$(basename $f).txt" 2>/dev/null || true
    done
    # Android crash/ANR state is more useful than another summary dump.
    for x in anr tombstones system/dropbox log; do
        if [ -e "$SYS/data/$x" ]; then
            cp -a "$SYS/data/$x" "$d/android-$(echo $x | tr / -)" 2>/dev/null || true
        fi
    done
    if kill -0 "$P" 2>/dev/null && [ ! -f $W/frozen ]; then
        # Full Android state: all logcat buffers (main/system/crash/events/
        # kernel/radio), every dumpsys service, props, settings, network.
        adb_sh 'export PATH=/system/bin:/system/xbin; logcat -G 8M' >/dev/null 2>&1 || true
        adb_sh 'export PATH=/system/bin:/system/xbin; logcat -b all -d -v threadtime' > $d/android-logcat-all.txt 2>&1
        adb_sh 'export PATH=/system/bin:/system/xbin; logcat -b events -d -v threadtime' > $d/android-logcat-events.txt 2>&1
        adb_sh 'export PATH=/system/bin:/system/xbin; logcat -b crash -d -v threadtime' > $d/android-logcat-crash.txt 2>&1
        adb_sh 'export PATH=/system/bin:/system/xbin; getprop' > $d/android-getprop.txt 2>&1
        # 没开机完成（system_server 起不来、binder 不通）时 dumpsys / settings / pm 每条都只会留下一行
        # "Aborted"（用户诊断：几十个 23 字节的文件）。日志和属性上面已经有了，这里只记一句。
        if ! grep -q '^\[sys.boot_completed\]: \[1\]' $d/android-getprop.txt 2>/dev/null; then
            echo "android has not finished booting: dumpsys skipped (see android-logcat-all.txt and android-tombstones)" > $d/android-NOT-BOOTED.txt
        else
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys' > $d/android-dumpsys-all.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys meminfo' > $d/android-meminfo.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys activity activities' > $d/android-activities.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys activity processes' > $d/android-processes.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys window' > $d/android-window.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys input' > $d/android-input.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys battery' > $d/android-battery.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys power' > $d/android-power.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys connectivity' > $d/android-connectivity.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys wifi' > $d/android-wifi.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys display' > $d/android-display.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys SurfaceFlinger' > $d/android-surfaceflinger.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys package com.tencent.weread.eink' > $d/android-weread-package.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; settings list global' > $d/android-settings-global.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; settings list secure' > $d/android-settings-secure.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; ip addr' > $d/android-ip.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; netstat -tunlp' > $d/android-netstat.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; top -n 1 -d 1 -m 40' > $d/android-top.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; top -H -n 1 -d 1 -m 60' > $d/android-top-threads.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; ps -A -o USER,PID,PPID,VSZ,RSS,STAT,NAME' > $d/android-ps-all.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys -l' > $d/android-dumpsys-list.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys cpuinfo' > $d/android-cpuinfo.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys meminfo -a' > $d/android-meminfo-all.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys procstats --hours 6' > $d/android-procstats.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys batterystats --charged' > $d/android-batterystats.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys alarm' > $d/android-alarm.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys jobscheduler' > $d/android-jobscheduler.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys package' > $d/android-package-all.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys activity top' > $d/android-activity-top.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys gfxinfo com.veradroid.home' > $d/android-gfx-home.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys gfxinfo com.tencent.weread.eink' > $d/android-gfx-weread.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys media.audio_flinger' > $d/android-audio.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys thermalservice' > $d/android-thermal.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys sensorservice' > $d/android-sensors.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys deviceidle' > $d/android-deviceidle.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys usagestats' > $d/android-usagestats.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; dumpsys diskstats' > $d/android-diskstats.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; df -h' > $d/android-df.txt 2>&1
            adb_sh 'export PATH=/system/bin:/system/xbin; mount' > $d/android-mounts.txt 2>&1
        fi
    fi
    t "diagnostics saved: $d"
}

# 返回 Kobo：Kobo Libra 2 默认完整停止以释放挂载供 USB 存储使用。
do_exit() {
    settings_load
    t "return to kobo requested"
    if [ "$RETURN_MODE" = freeze ] && [ -d $FZ ]; then
        touch $X/ctl/sleep
        type appprof_density_reset >/dev/null 2>&1 && appprof_density_reset
        if android_freeze; then
            touch $W/frozen
            cpu_gov_restore 2>/dev/null || true
            input_release
            wifi_ps_restore 2>/dev/null || true
            for f in sleep lipc watchdog; do kill $(cat $W/$f.pid 2>/dev/null) 2>/dev/null; done
            type usb_watch_stop >/dev/null 2>&1 && usb_watch_stop
            framework_start
            userstore_check freeze
            t "frozen, kobo ui back"
            exit 0
        fi
        t "freeze failed, stopping"
    fi
    log_release; sh $VD/boot/stop.sh >/dev/null 2>&1
    exit 0
}
# 调 stop.sh 之前先把自己的输出从系统盘上的 veradroid.log 挪开：stop.sh 不杀调用自己的进程，
# 这个打开的文件会让 loop 系统盘卸不掉。
log_release() { t "releasing the log on the system image (stop follows)"; exec >>/tmp/veradroid-stop.log 2>&1; }
do_stop() { t "stop requested"; log_release; sh $VD/boot/stop.sh >/dev/null 2>&1; exit 0; }
do_restart() {
    t "restart requested"; touch $W/restarting
    log_release; sh $VD/boot/stop.sh >/dev/null 2>&1
    sh $VD/boot/veradroid.sh </dev/null >/dev/null 2>&1 &
    exit 0
}

# /tmp tmpfs 日志限额：显示桥每刷一次写一行，超过上限就留后一半
log_cap() {   # log_cap <文件> <字节>
    sz=$(wc -c < "$1" 2>/dev/null || echo 0)
    [ "$sz" -gt "$2" ] 2>/dev/null || return 0
    tail -c $(($2 / 2)) "$1" > "$1.tmp" 2>/dev/null && cat "$1.tmp" > "$1"; rm -f "$1.tmp"
}
# Kobo 无 Kindle fastmetrics 遥测目录，保留空钩子兼容看门狗调用
var_guard() { return 0; }

helpers_supervise() {
    if [ -x "$VD/bin/veradroid-epd" ] && [ -f $W/epd.pid ] && ! alive $W/epd.pid; then
        n=$(cat $W/epd.restarts 2>/dev/null || echo 0)
        if [ "$n" -lt 3 ]; then
            echo $((n + 1)) > $W/epd.restarts
            t "display bridge (pid $(cat $W/epd.pid)) gone, restarting it ($((n + 1))/3); last log: $(tail -n 2 $W/epd.log 2>/dev/null | tr '\n' ' ')"
            cp $W/epd.log $W/epd.log.crashed 2>/dev/null
            display_start; epd_send REDRAW
        fi
    fi
    if [ -f $W/input.pid ] && ! alive $W/input.pid && [ ! -f $W/frozen ]; then
        n=$(cat $W/input.restarts 2>/dev/null || echo 0)
        if [ "$n" -lt 3 ]; then
            echo $((n + 1)) > $W/input.restarts
            t "touch front end (pid $(cat $W/input.pid)) gone, restarting it ($((n + 1))/3); last log: $(tail -n 2 $W/input.log 2>/dev/null | tr '\n' ' ')"
            cp $W/input.log $W/input.log.crashed 2>/dev/null
            if input_touch_start; then
                # 容器里的 /dev/input/event0、event1 是开机时绑进去的；Android 的 EventHub 在旧设备挂断时把它们删了，
                # 只有目录里出现新文件（inotify）才会再打开。按新设备的设备号在容器的 /dev/input 里建两个新节点
                ci=/proc/$(cat $W/pid 2>/dev/null)/root/dev/input   # 容器自己的 /dev（挂载命名空间里的 tmpfs），宿主的 $R/dev 看不到
                rm -f $ci/event1[0-9] 2>/dev/null
                k=0; for d in $KFB_TOUCH $KFB_KEYS_VIRT; do
                    dn=$(cat /sys/class/input/${d##*/}/dev 2>/dev/null)
                    [ -n "$dn" ] && mknod -m 666 $ci/event1$((n * 2 + k)) c ${dn%%:*} ${dn##*:} 2>/dev/null   # 建出来就要是 666：EventHub 收到 inotify 立刻打开，晚一步 chmod 就是 Permission denied
                    k=$((k + 1))
                done
                t "touch front end restarted: $KFB_TOUCH / $KFB_KEYS_VIRT handed to android as $(ls $ci | grep '^event1[0-9]' | tr '\n' ' ')"
            else t "touch front end: restart failed"; fi
        fi
    fi
}

watchdog() {
    # PERF: poll every 60s while frozen to cut host wakeups. FIFO cmd.sh still handles UI.
    # MEM: re-apply kernel LMK each tick (lab126 can reset minfree).
    last_st_bat=
    last_st_chg=
    while :; do
        if [ -f $W/saver_frozen ] || [ -f $W/frozen ]; then sleep_for=60; else sleep_for=20; fi
        sleep $sleep_for
        kill -0 $P 2>/dev/null || { t "system exited"; log_release; sh $VD/boot/stop.sh >/dev/null 2>&1; break; }
        lmk_kernel_tune 2>/dev/null || true
        var_guard
        log_cap $W/epd.log 262144; log_cap $W/input.log 131072; log_cap $W/input.err 65536
        if [ ! -f $W/saver_frozen ] && [ ! -f $W/frozen ]; then
            # 命令监听没了（FIFO 建不起来、被杀）：桌面的“返回 Kindle”、设置、手势全都没反应，只能重启 Kindle。重新起一个。
            alive $W/cmd.pid || { t "cmd listener gone, restarting it"; cmd_listen & echo $! > $W/cmd.pid; }
            # 显示桥 / 触摸前端没了（崩溃、被 OOM 杀掉）：以前没人管，屏幕永远停在最后一帧，或者 Android 再也收不到触摸，
            # 只能重启 Kindle。重新起一个（每次开机各最多 3 次，再多就是程序本身起不来，留给诊断）。
            helpers_supervise
            # system_server 重启（Watchdog 杀掉后软重启）以后 ActivityManager 会把 lmkd 的门槛写回原厂的大屏手机档，
            # 512 MB 机型上前台的微信读书又会被反复杀掉（用户诊断）。pid 变了就重新设一次。
            ss=$(pidof system_server 2>/dev/null | cut -d' ' -f1)
            if [ -n "$ss" ] && [ "$ss" != "$(cat $W/ss.pid 2>/dev/null)" ]; then
                [ -f $W/ss.pid ] && [ -f $W/booted ] && { t "system_server restarted ($(cat $W/ss.pid) -> $ss): re-tuning lmkd"; ( sleep 20; lmk_tune; i=0; while [ $i -lt 30 ] && [ "$(adb_sh 'getprop sys.boot_completed' 2>/dev/null | tr -d '\r\n')" != 1 ]; do sleep 5; i=$((i+1)); done; trust_unlock ) & }
                echo "$ss" > $W/ss.pid
            fi
        fi
        [ -f $W/saver_frozen ] || [ -f $W/frozen ] || { [ -f $X/ctl/settings.new ] && settings_apply; }
        # Wi-Fi 省电（network.sh）、新装 / 更新的应用排队预编译（compile.sh）、电量记录（energy.sh）
        if [ ! -f $W/saver_frozen ] && [ ! -f $W/frozen ]; then
            type wifi_ps_tick >/dev/null 2>&1 && wifi_ps_tick
            [ -f $W/booted ] && type bgnice_tick >/dev/null 2>&1 && bgnice_tick     # 后台应用降优先级（bgnice.sh）
            [ -f $W/booted ] && type compile_watch >/dev/null 2>&1 && compile_watch
            cur_st_bat=$(kobo_battery 2>/dev/null)
            kobo_is_charging && cur_st_chg=1 || cur_st_chg=0
            if [ "$cur_st_bat" != "$last_st_bat" ] || [ "$cur_st_chg" != "$last_st_chg" ]; then
                last_st_bat=$cur_st_bat; last_st_chg=$cur_st_chg
                type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
            fi
        fi
        type bat_log >/dev/null 2>&1 && bat_log
        # 系统盘快满了就自动扩（storage.sh）。冻结时不做。
        [ -f $W/saver_frozen ] || [ -f $W/frozen ] || { type st_auto_tick >/dev/null 2>&1 && st_auto_tick; }
        if [ -f $X/ctl/diag ]; then rm -f $X/ctl/diag; ( diag_save; touch $X/ctl/diag.done ) & fi
        [ -f $X/ctl/stop ] && { rm -f $X/ctl/stop; do_stop; }
        [ -f $X/ctl/restart ] && { rm -f $X/ctl/restart; do_restart; }
        [ -f $X/ctl/exit ] && { rm -f $X/ctl/exit; do_exit; }
    done
}
