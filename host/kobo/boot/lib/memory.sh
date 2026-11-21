# SPDX-License-Identifier: GPL-3.0-or-later
# Memory, zram, ART heap, VM tuning, readahead, and loop page-cache deduplication for Kobo Libra 2 (512 MB RAM).

overcommit_on() {
    [ -f "$W/overcommit.state" ] || cat /proc/sys/vm/overcommit_memory > "$W/overcommit.state"
    echo 1 > /proc/sys/vm/overcommit_memory && t "memory: overcommit_memory=1"
}

overcommit_restore() {
    [ -f "$W/overcommit.state" ] || return 0
    cat "$W/overcommit.state" > /proc/sys/vm/overcommit_memory 2>/dev/null || true
    rm -f "$W/overcommit.state"
}

heap_values() {
    echo "${HEAP_GROWTH:-128m} ${HEAP_SIZE:-192m}"
}

heap_fix() {
    f=$R/system/build.prop
    [ -f "$f" ] || return 0
    _prop() {
        k=$1; v=$2
        if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"
        else echo "$k=$v" >> "$f"; fi
    }
    set -- $(heap_values); hg=$1; hs=$2
    _prop dalvik.vm.heapstartsize "${HEAP_START:-8m}"
    _prop dalvik.vm.heapgrowthlimit "$hg"
    _prop dalvik.vm.heapsize "$hs"
    _prop dalvik.vm.heapminfree "${HEAP_MINFREE:-2m}"
    _prop dalvik.vm.heapmaxfree "${HEAP_MAXFREE:-8m}"
    _prop dalvik.vm.heaptargetutilization "${HEAP_TARGET_UTIL:-0.75}"
    _prop ro.config.low_ram true
    _prop ro.config.max_starting_bg "${MAX_STARTING_BG:-2}"
    _prop ro.sys.fw.bg_apps_limit "${PROC_LIMIT:-2}"
    _prop persist.sys.strictmode.disable true
    _prop ro.product.model "VeraDroid on Kobo Libra 2"
    t "memory: heap ${HEAP_START:-8m}/$hg/$hs (${HEAP_MINFREE:-2m}-${HEAP_MAXFREE:-8m}) + ro.config.low_ram=true"
}

zram_on() {
    overcommit_on
    heap_fix
    tune_apply
    Z=/sys/block/zram0
    [ -e "$Z/disksize" ] || { t "zram: /sys/block/zram0 not available"; return 0; }
    [ "${ZRAM_MB:-256}" -gt 0 ] || return 0
    [ "$ZRAM_MB" -gt 256 ] && ZRAM_MB=256
    if ! grep -q '^/dev/zram0 ' /proc/swaps; then
        [ "$(cat "$Z/disksize" 2>/dev/null)" != 0 ] && echo 1 > "$Z/reset" 2>/dev/null || true
        mksw=mkswap
        [ -x "$VD/bin/vdmkswap" ] && mksw="$VD/bin/vdmkswap"
        if echo $((ZRAM_MB * 1048576)) > "$Z/disksize" && "$mksw" /dev/zram0 >/dev/null 2>&1 && { swapon -p 100 /dev/zram0 2>/dev/null || swapon /dev/zram0 2>/dev/null; }; then
            t "zram: ${ZRAM_MB}MB active"
        else
            echo 1 > "$Z/reset" 2>/dev/null || true
            t "zram: activation failed"
            return 0
        fi
    fi
    [ -f "$W/zram.state" ] || echo "$(cat /proc/sys/vm/swappiness) $(cat /proc/sys/vm/page-cluster)" > "$W/zram.state"
    echo "${VM_SWAPPINESS:-100}" > /proc/sys/vm/swappiness
    echo 0 > /proc/sys/vm/page-cluster
}

zram_restore() {
    overcommit_restore
    tune_restore
    [ -f "$W/zram.state" ] || return 0
    read sw pc < "$W/zram.state"
    echo "$sw" > /proc/sys/vm/swappiness 2>/dev/null || true
    [ -n "$pc" ] && echo "$pc" > /proc/sys/vm/page-cluster 2>/dev/null || true
    rm -f "$W/zram.state"
}

cpu_gov_set() {
    want=$1; [ -n "$want" ] || return 0
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$g" ] || continue
        [ -f "$W/cpu_gov.state" ] || cat "$g" > "$W/cpu_gov.state"
        echo "$want" > "$g" 2>/dev/null || true
    done
}

cpu_gov_restore() {
    [ -f "$W/cpu_gov.state" ] || return 0
    prev=$(cat "$W/cpu_gov.state")
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$g" ] && echo "$prev" > "$g" 2>/dev/null || true
    done
    rm -f "$W/cpu_gov.state"
}

# READAHEAD_KB: eMMC; LOOP_READAHEAD_KB: loop over veradroid-sys.img (set exactly, may lower).
# Libra 2 WeRead cold start (drop_caches, 3-4 runs each): eMMC 256/loop 256 = 20.7 s avg, 290 MB read;
# eMMC 128/loop 64 = 18.6 s avg, 250 MB read (loop readahead stacks on eMMC readahead and wastes I/O on random .odex faults).
readahead_on() {
    : > "$W/readahead.saved"
    for b in /sys/block/mmcblk[0-9] /sys/block/loop[0-9]*; do
        f=$b/queue/read_ahead_kb
        [ -w "$f" ] || continue
        case "$b" in
            */loop*) [ -s "$b/loop/backing_file" ] || continue; want=${LOOP_READAHEAD_KB:-} ;;
            *) want=${READAHEAD_KB:-} ;;
        esac
        case "$want" in ''|*[!0-9]*|0) continue ;; esac
        old=$(cat "$f" 2>/dev/null); [ -n "$old" ] && [ "$old" != "$want" ] || continue
        echo "$b $old" >> "$W/readahead.saved"
        echo "$want" > "$f" 2>/dev/null || true
    done
}

readahead_restore() {
    [ -f "$W/readahead.saved" ] || return 0
    while read b old; do
        [ -w "$b/queue/read_ahead_kb" ] && echo "$old" > "$b/queue/read_ahead_kb" 2>/dev/null || true
    done < "$W/readahead.saved"
    rm -f "$W/readahead.saved"
}

TUNE_VM="vfs_cache_pressure:VM_VFS_CACHE_PRESSURE min_free_kbytes:VM_MIN_FREE_KB"
tune_apply() {
    t "profile: kobo libra2 ($(uname -r), fw $(kobo_firmware), MemTotal $(awk '/^MemTotal:/{print $2}' /proc/meminfo) kB)"
    for kv in $TUNE_VM; do
        k=${kv%%:*}; eval "v=\$${kv#*:}"
        f=/proc/sys/vm/$k
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ -w "$f" ] || continue
        [ "$k" = min_free_kbytes ] && [ "$(cat "$f")" -ge "$v" ] 2>/dev/null && [ ! -f "$W/vm.$k.state" ] && continue
        [ -f "$W/vm.$k.state" ] || cat "$f" > "$W/vm.$k.state"
        echo "$v" > "$f" 2>/dev/null && t "vm: $k=$v (was $(cat "$W/vm.$k.state"))"
    done
    f=$R/system/build.prop
    case "${LCD_DENSITY:-300}" in
        ''|*[!0-9]*) ;;
        *) if [ -f "$f" ] && ! grep -q "^ro.sf.lcd_density=${LCD_DENSITY:-300}\$" "$f"; then
               if grep -q '^ro.sf.lcd_density=' "$f"; then sed -i "s|^ro.sf.lcd_density=.*|ro.sf.lcd_density=${LCD_DENSITY:-300}|" "$f"
               else echo "ro.sf.lcd_density=${LCD_DENSITY:-300}" >> "$f"; fi
               t "display: ro.sf.lcd_density=${LCD_DENSITY:-300}"
           fi ;;
    esac
    # Tune interactive governor for single-core race-to-idle (stock go_hispeed_load=99, io_is_busy=0
    # throttles CPU to 198 MHz during WeRead .odex / LevelDB I/O and page rendering).
    ig=/sys/devices/system/cpu/cpufreq/interactive
    if [ -d "$ig" ]; then
        [ -f "$W/cpufreq.interactive.state" ] || {
            for k in go_hispeed_load target_loads io_is_busy min_sample_time; do
                [ -r "$ig/$k" ] && echo "$k $(cat "$ig/$k")"
            done > "$W/cpufreq.interactive.state"
        }
        for kv in "go_hispeed_load:65" "target_loads:65" "io_is_busy:1" "min_sample_time:60000"; do
            k=${kv%%:*}; v=${kv#*:}
            [ -w "$ig/$k" ] && echo "$v" > "$ig/$k" 2>/dev/null || true
        done
        t "cpufreq: interactive tuned (go_hispeed=65 target=65 io_is_busy=1)"
    fi
    return 0
}

tune_restore() {
    for kv in $TUNE_VM; do
        k=${kv%%:*}
        [ -f "$W/vm.$k.state" ] || continue
        cat "$W/vm.$k.state" > "/proc/sys/vm/$k" 2>/dev/null || true
        rm -f "$W/vm.$k.state"
    done
    ig=/sys/devices/system/cpu/cpufreq/interactive
    if [ -f "$W/cpufreq.interactive.state" ] && [ -d "$ig" ]; then
        while read -r k v; do
            [ -w "$ig/$k" ] && echo "$v" > "$ig/$k" 2>/dev/null || true
        done < "$W/cpufreq.interactive.state"
        rm -f "$W/cpufreq.interactive.state"
    fi
}

proc_limit_apply() {
    case "$PROC_LIMIT" in ''|*[!0-9]*) return 0 ;; esac
    r=$(adb_sh "service call activity 51 i32 $PROC_LIMIT" 2>/dev/null | tr -d '\r\n')
    t "am: background process limit $PROC_LIMIT (${r:-no reply})"
}

# Drop duplicate vfat backing page cache for veradroid-sys.img on 4.1 kernel
dedup_start() {
    [ "${CACHE_DEDUP:-1}" = 1 ] && [ -x "$VD/bin/vdloopdio" ] && [ -f "$SYSTEM_IMG" ] || return 0
    alive "$W/dedup.pid" && return 0
    (
        while [ -f "$W/pid" ]; do
            if [ -f "$W/frozen" ] || [ -f "$W/saver_frozen" ]; then sleep 30; continue; fi
            "$VD/bin/vdloopdio" --drop "$SYSTEM_IMG" 2>/dev/null || true
            sleep "${CACHE_DEDUP_S:-3}"
        done
    ) </dev/null >/dev/null 2>&1 &
    echo $! > "$W/dedup.pid"
    t "cache dedup: dropping duplicate pages of $SYSTEM_IMG every ${CACHE_DEDUP_S:-3}s"
}

dedup_stop() {
    p=$(cat "$W/dedup.pid" 2>/dev/null); rm -f "$W/dedup.pid"
    [ -n "$p" ] && kill "$p" 2>/dev/null || true
}
