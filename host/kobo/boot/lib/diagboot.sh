# SPDX-License-Identifier: GPL-3.0-or-later
# Early-boot diagnostics. Keep this light: the previous version ran logcat/dumpsys
# every 2 seconds for two minutes, which made a slow PW6 feel frozen right after boot.
diagboot() {
    LOG=$VD/logs/boot.log
    mkdir -p "$VD/logs" 2>/dev/null
    : > "$LOG" 2>/dev/null || return 0
    {
        echo "== VeraDroid boot diagnostics $(date) =="
        echo "kernel=$(uname -a)"
        echo "resolution=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
        echo "data dirs:"
        ls -ld "$SYS/data" "$SYS/data/system" "$SYS/data/data" "$SYS/data/media" 2>&1
        echo "settings files:"
        ls -la "$SYS/data/system" 2>&1 | head -30
    } >> "$LOG" 2>&1

    # Sample at 8, 20, 40 and 70 seconds. One bounded logcat per sample; no dumpsys loop.
    for delay in 8 12 20 30; do
        sleep "$delay"
        P=$(cat "$W/pid" 2>/dev/null)
        [ -n "$P" ] && kill -0 "$P" 2>/dev/null || continue
        {
            echo
            echo "== sample $(date +%H:%M:%S) pid=$P =="
            vd_timeout 6 $(vd_in) /system/bin/sh -c \
              'export PATH=/system/bin:/system/xbin ANDROID_ROOT=/system ANDROID_DATA=/data; getprop sys.boot_completed; logcat -b all -d -t 220 2>/dev/null' 2>&1 | tail -45
        } >> "$LOG" 2>&1
        [ -f "$W/boot.done" ] && break
    done
    echo "== diagnostics end $(date) ==" >> "$LOG"
}
