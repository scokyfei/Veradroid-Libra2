# SPDX-License-Identifier: GPL-3.0-or-later
# Manage the Kobo UI cleanly while VeraDroid runs:
# - KOReader: SIGSTOP/SIGCONT (fast return, keeps reading state, does not grab event0)
# - Nickel:   cleanly stop nickel/sickel/hindenburg (releases EVIOCGRAB on event0 and
#             ~90 MB RAM), and relaunch them on exit with their saved environment.
# Never touches dropbear or wpa_supplicant (Wi-Fi & SSH stay active).
FWD=$W/fw
FBDEPTH=
for _fd in "$VD/bin/fbdepth" /mnt/onboard/.adds/koreader/fbdepth /usr/bin/fbdepth; do
    [ -x "$_fd" ] && { FBDEPTH=$_fd; break; }
done

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

kobo_save_nickel_env() {
    npid=$1
    envf=$FWD/nickel.env
    : > "$envf"
    if [ -n "$npid" ] && [ -r "/proc/$npid/environ" ]; then
        tr '\000' '\n' < "/proc/$npid/environ" 2>/dev/null | while IFS='=' read -r k v; do
            case "$k" in
                DBUS_SESSION_BUS_ADDRESS|HOME|INTERFACE|LANG|LD_LIBRARY_PATH|NICKEL_HOME|PLATFORM|PRODUCT|QT_GSTREAMER_PLAYBIN_AUDIOSINK|QT_GSTREAMER_PLAYBIN_AUDIOSINK_DEVICE_PARAMETER|WIFI_MODULE|QWS_MOUSE_PROTO|QWS_KEYBOARD|QT_PLUGIN_PATH|QWS_DISPLAY)
                    sv=$(printf '%s' "$v" | sed "s/'/'\\\\''/g")
                    printf "export %s='%s'\n" "$k" "$sv" >> "$envf" ;;
            esac
        done
    fi
    # Fallbacks if any core var was missing
    grep -q '^export LD_LIBRARY_PATH=' "$envf" || echo "export LD_LIBRARY_PATH='/usr/local/Kobo'" >> "$envf"
    grep -q '^export NICKEL_HOME=' "$envf" || echo "export NICKEL_HOME='/mnt/onboard/.kobo'" >> "$envf"
    grep -q '^export PLATFORM=' "$envf" || {
        pl=$(tr '\000' '\n' < "/proc/$(pidof -s udevd 2>/dev/null)/environ" 2>/dev/null | sed -n 's/^PLATFORM=//p' | head -1)
        [ -n "$pl" ] && printf "export PLATFORM='%s'\n" "$pl" >> "$envf"
    }
    grep -q '^export PRODUCT=' "$envf" || {
        pr=$(/bin/kobo_config.sh 2>/dev/null || true)
        [ -n "$pr" ] && printf "export PRODUCT='%s'\n" "$pr" >> "$envf"
    }
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

    if [ "$ui" = koreader ] && [ -n "$*" ]; then
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
        t "fw: paused koreader (pids: $*)"

        # Save current screen content on disk ($VD/state) instead of /tmp tmpfs to save 2.1 MB RAM
        fb_geom
        echo "$FB_STRIDE $FB_PANY $FB_ROWS" > "$FWD/geom"
        mkdir -p "$VD/state" 2>/dev/null || true
        SCR_BAK="$VD/state/kobo-screen.raw"
        dd if=/dev/fb0 of="$SCR_BAK" bs="$FB_STRIDE" skip="$FB_PANY" count="$FB_ROWS" 2>/dev/null || true
        t "fw: screen saved (${FB_STRIDE}x${FB_ROWS}, pan=$FB_PANY)"
    elif [ "$ui" = nickel ]; then
        npid=$(pidof -s nickel 2>/dev/null || echo "${1:-}")
        kobo_save_nickel_env "$npid"
        orig_bpp=$(cat "$FB/bits_per_pixel" 2>/dev/null || true)
        orig_rot=$(cat "$FB/rotate" 2>/dev/null || true)
        [ -n "$orig_bpp" ] && echo "$orig_bpp" > "$FWD/bpp"
        [ -n "$orig_rot" ] && echo "$orig_rot" > "$FWD/rot"
        sync
        # Cleanly terminate Nickel stack so event0 (power/page keys/kx122) EVIOCGRAB and ~90 MB RAM are freed
        killall -q -TERM nickel hindenburg sickel fickel strickel fontickel adobehost foxitpdf iink QtWebEngineProcess 2>/dev/null || true
        i=0
        while [ $i -lt 16 ]; do
            [ -z "$(pidof nickel 2>/dev/null)" ] && break
            usleep 250000; i=$((i + 1))
        done
        if [ -n "$(pidof nickel sickel hindenburg 2>/dev/null)" ]; then
            killall -q -KILL nickel sickel hindenburg 2>/dev/null || true
            usleep 300000
        fi
        rm -f /tmp/nickel-hardware-status
        # Switch fb0 from 32bpp to 8bpp while VeraDroid runs (matches KOReader & saves 4x fb bandwidth)
        if [ "$orig_bpp" != "8" ] && [ -x "$FBDEPTH" ]; then
            "$FBDEPTH" -d 8 >/dev/null 2>&1 && echo 1 > "$FWD/bpp_changed" || true
        fi
        t "fw: stopped nickel cleanly (orig_bpp=${orig_bpp:-?}, freed event0 + RAM)"
    else
        t "fw: no foreground Kobo UI detected (headless/SSH launch)"
    fi

    if [ -w /proc/sys/kernel/core_pattern ]; then
        cat /proc/sys/kernel/core_pattern > "$FWD/core_pattern" 2>/dev/null || true
        echo "|/bin/true" > /proc/sys/kernel/core_pattern 2>/dev/null || true
    fi
    touch "$FWD/paused"

    [ -n "${FRAMEWORK_AFTER_SAVE:-}" ] && $FRAMEWORK_AFTER_SAVE
    return 0
}

framework_start() {
    framework_paused || { t "kobo ui not paused"; return 0; }
    ui=$(cat "$FWD/ui" 2>/dev/null)
    pids=$(cat "$FWD/pids" 2>/dev/null)

    [ -f "$FWD/core_pattern" ] && [ -w /proc/sys/kernel/core_pattern ] && cat "$FWD/core_pattern" > /proc/sys/kernel/core_pattern 2>/dev/null || true

    if [ "$ui" = koreader ]; then
        set -- $(cat "$FWD/geom" 2>/dev/null)
        SCR_BAK="$VD/state/kobo-screen.raw"
        [ -f "$SCR_BAK" ] || SCR_BAK="$W/kobo-screen.raw"
        if [ -f "$SCR_BAK" ] && [ -n "$1" ]; then
            dd if="$SCR_BAK" of=/dev/fb0 bs="$1" seek="$2" count="$3" 2>/dev/null || true
            rm -f "$VD/state/kobo-screen.raw" "$W/kobo-screen.raw"
        fi
        [ -x "$FBINK" ] && "$FBINK" -q -f -s 2>/dev/null || true
        if [ -n "$pids" ]; then
            for p in $pids; do kill -CONT "$p" 2>/dev/null || true; done
            t "fw: resumed koreader (pids: $pids)"
        fi
    elif [ "$ui" = nickel ]; then
        orig_bpp=$(cat "$FWD/bpp" 2>/dev/null || true)
        orig_rot=$(cat "$FWD/rot" 2>/dev/null || true)
        if [ -f "$FWD/bpp_changed" ] && [ -n "$orig_bpp" ] && [ -x "$FBDEPTH" ]; then
            if [ -n "$orig_rot" ]; then
                "$FBDEPTH" -d "$orig_bpp" -r "$orig_rot" >/dev/null 2>&1 || true
            else
                "$FBDEPTH" -d "$orig_bpp" >/dev/null 2>&1 || true
            fi
        fi
        rm -f /tmp/nickel-hardware-status
        mkfifo /tmp/nickel-hardware-status 2>/dev/null || true
        sync
        (
            cd /
            exec 3>&- 4>&- 2>/dev/null || true
            PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/lib:"
            export PATH
            [ -f "$FWD/nickel.env" ] && . "$FWD/nickel.env"
            export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-/usr/local/Kobo}"
            export QT_GSTREAMER_PLAYBIN_AUDIOSINK="${QT_GSTREAMER_PLAYBIN_AUDIOSINK:-alsasink}"
            export QT_GSTREAMER_PLAYBIN_AUDIOSINK_DEVICE_PARAMETER="${QT_GSTREAMER_PLAYBIN_AUDIOSINK_DEVICE_PARAMETER:-bluealsa:DEV=00:00:00:00:00:00}"
            setsid /usr/local/Kobo/hindenburg </dev/null >/dev/null 2>&1 &
            setsid env LIBC_FATAL_STDERR_=1 /usr/local/Kobo/nickel -platform kobo -skipFontLoad </dev/null >/dev/null 2>&1 &
            [ "${PLATFORM:-}" != "freescale" ] && udevadm trigger </dev/null >/dev/null 2>&1 &
        )
        t "fw: restarted nickel"
    fi

    rm -rf "$FWD"
    return 0
}
