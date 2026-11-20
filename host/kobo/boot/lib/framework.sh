# SPDX-License-Identifier: GPL-3.0-or-later
# Pause and resume the Kobo UI (KOReader or Nickel) cleanly while VeraDroid runs.
# Never touches dropbear (SSH stays active for management/debugging).
FWD=$W/fw

framework_paused() { [ -f "$FWD/paused" ]; }

kobo_find_ui_pids() {
    # Prefer pausing KOReader if running (luajit reader.lua)
    kpids=
    for d in /proc/[0-9]*; do
        p=${d#/proc/}
        cmd=$(tr '\000' ' ' < "$d/cmdline" 2>/dev/null) || continue
        case "$cmd" in
            *luajit*reader.lua*|*/koreader/luajit*) kpids="$kpids $p" ;;
        esac
    done
    if [ -n "$kpids" ]; then
        echo "koreader $kpids"
        return 0
    fi
    # Otherwise check Nickel
    npids=
    for n in nickel sickel; do
        for p in $(pidof "$n" 2>/dev/null); do npids="$npids $p"; done
    done
    if [ -n "$npids" ]; then
        echo "nickel $npids"
        return 0
    fi
    echo "none"
    return 0
}

fb_geom() {
    FB_STRIDE=$(cat $FB/stride 2>/dev/null)
    FB_PANY=$(cut -d, -f2 $FB/pan 2>/dev/null)
    FB_ROWS=$(sed -n 's/.*U:\([0-9]*\)x\([0-9]*\)p.*/\2/p' $FB/modes 2>/dev/null | awk '$1 >= 1000 { print; exit }')
    [ -n "$FB_STRIDE" ] || FB_STRIDE=1280
    [ -n "$FB_PANY" ] || FB_PANY=0
    [ -n "$FB_ROWS" ] || FB_ROWS=1680
}

framework_stop() {
    mkdir -p "$FWD" "$W" || return 1
    framework_paused && { t "kobo ui already paused"; return 0; }

    set -- $(kobo_find_ui_pids)
    ui=$1; shift
    echo "$ui" > "$FWD/ui"
    echo "$*" > "$FWD/pids"

    # Wait briefly for KOReader to settle, then SIGSTOP
    if [ "$ui" != none ] && [ -n "$*" ]; then
        for p in "$@"; do
            kill -STOP "$p" 2>/dev/null || true
        done
        # Confirm stopped state ('T') up to 2s
        i=0
        while [ $i -lt 20 ]; do
            all_t=1
            for p in "$@"; do
                st=$(awk '/^State:/ {print $2}' "/proc/$p/status" 2>/dev/null)
                [ -z "$st" ] || [ "$st" = T ] || all_t=0
            done
            [ "$all_t" = 1 ] && break
            usleep 100000; i=$((i + 1))
        done
        t "fw: paused $ui (pids: $*)"
    else
        t "fw: no foreground Kobo UI detected (headless/SSH launch)"
    fi

    # Save current screen content on disk ($VD/state) instead of /tmp tmpfs to save 2.1 MB RAM
    fb_geom
    echo "$FB_STRIDE $FB_PANY $FB_ROWS" > "$FWD/geom"
    mkdir -p "$VD/state" 2>/dev/null || true
    SCR_BAK="$VD/state/kobo-screen.raw"
    dd if=/dev/fb0 of="$SCR_BAK" bs="$FB_STRIDE" skip="$FB_PANY" count="$FB_ROWS" 2>/dev/null || true
    if [ -w /proc/sys/kernel/core_pattern ]; then
        cat /proc/sys/kernel/core_pattern > "$FWD/core_pattern" 2>/dev/null || true
        echo "|/bin/true" > /proc/sys/kernel/core_pattern 2>/dev/null || true
    fi
    touch "$FWD/paused"
    t "fw: screen saved (${FB_STRIDE}x${FB_ROWS}, pan=$FB_PANY)"

    [ -n "${FRAMEWORK_AFTER_SAVE:-}" ] && $FRAMEWORK_AFTER_SAVE
    return 0
}

framework_start() {
    framework_paused || { t "kobo ui not paused"; return 0; }
    set -- $(cat "$FWD/geom" 2>/dev/null)
    SCR_BAK="$VD/state/kobo-screen.raw"
    [ -f "$SCR_BAK" ] || SCR_BAK="$W/kobo-screen.raw"
    if [ -f "$SCR_BAK" ] && [ -n "$1" ]; then
        dd if="$SCR_BAK" of=/dev/fb0 bs="$1" seek="$2" count="$3" 2>/dev/null || true
        rm -f "$VD/state/kobo-screen.raw" "$W/kobo-screen.raw"
    fi
    [ -x "$FBINK" ] && "$FBINK" -q -f -s 2>/dev/null || true

    ui=$(cat "$FWD/ui" 2>/dev/null)
    pids=$(cat "$FWD/pids" 2>/dev/null)
    if [ -n "$pids" ]; then
        for p in $pids; do kill -CONT "$p" 2>/dev/null || true; done
        t "fw: resumed $ui (pids: $pids)"
    fi

    [ -f "$FWD/core_pattern" ] && [ -w /proc/sys/kernel/core_pattern ] && cat "$FWD/core_pattern" > /proc/sys/kernel/core_pattern 2>/dev/null || true
    rm -rf "$FWD"
    return 0
}
