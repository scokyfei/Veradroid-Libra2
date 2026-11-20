# SPDX-License-Identifier: GPL-3.0-or-later
# Privileged host request handler (`wa <32-hex-id>`) for VeraHome Web Admin & WifiActivity on Kobo Libra 2.

WA_PKG=com.veradroid.home
WA_OUT=$X/wa

wa_log() { t "$@" >&2; }
wa_uid() { awk -v p=$WA_PKG '$1 == p { print $2; exit }' "$SYS/data/system/packages.list" 2>/dev/null; }

wa_request() {
    n=$1
    case "$n" in ''|*[!0-9a-f]*) t "wa: bad id"; return 1 ;; esac
    [ ${#n} -eq 32 ] || { t "wa: bad id"; return 1; }
    u=$(wa_uid)
    case "$u" in ''|*[!0-9]*) t "wa: VeraHome uid unknown"; return 1 ;; esac
    f=$SYS/data/data/$WA_PKG/files/hostreq/$n.req
    if [ ! -f "$f" ] || [ -L "$f" ] || [ "$(stat -c %u "$f" 2>/dev/null)" != "$u" ]; then
        t "wa: request $n rejected"
        return 1
    fi
    req=$(head -c 9000 "$f" 2>/dev/null)
    rm -f "$f"
    l1=$(printf '%s\n' "$req" | sed -n 1p | tr -cd 'A-Za-z0-9 ._-' | cut -c1-160)
    l2=$(printf '%s\n' "$req" | sed -n 2p | tr -d '\r')
    verb=${l1%% *}; arg=
    [ "$verb" = "$l1" ] || arg=${l1#* }
    mkdir -p "$WA_OUT" && chown 0:0 "$WA_OUT" && chmod 711 "$WA_OUT" || return 1
    ls -t "$WA_OUT" 2>/dev/null | tail -n +13 | while read -r o; do case "$o" in *[!0-9a-f.outmp]*) ;; *) rm -f "$WA_OUT/$o" ;; esac; done
    ( exec 3>&- 3<&- 2>&1; wa_do "$n" "$u" "$verb" "$arg" "$l2" ) </dev/null &
}

wa_put() {
    o=$WA_OUT/$1
    head -c 4194304 > "$o.tmp" && chown "$2" "$o.tmp" && chmod 400 "$o.tmp" && mv -f "$o.tmp" "$o.out" || rm -f "$o.tmp"
}

wa_do() {
    n=$1; u=$2; verb=$3; arg=$4; data=$5
    case "$verb" in
    sysinfo)       wa_sysinfo | wa_put "$n" "$u" ;;
    du)            wa_du | wa_put "$n" "$u" ;;
    logtail)       wa_logtail "$arg" | wa_put "$n" "$u" ;;
    shot)          wa_shot "$n" "$u" ;;
    sshstate)      wa_sshstate | wa_put "$n" "$u" ;;
    storage)       { echo "ok=1"; type st_info >/dev/null 2>&1 && st_info; } | wa_put "$n" "$u" ;;
    storageresize) case "$arg" in ''|*[!0-9]*) echo "error=nan" ;; *) type st_request >/dev/null 2>&1 && st_request "$arg" || echo "error=notool" ;; esac | wa_put "$n" "$u" ;;
    storageauto)   case "$arg" in 0|1) type st_cmd >/dev/null 2>&1 && st_cmd auto "$arg" >/dev/null 2>&1; echo "ok=1"; type st_info >/dev/null 2>&1 && st_info ;; *) echo "error=bad value" ;; esac | wa_put "$n" "$u" ;;
    wifipsk)       wa_wifipsk "$arg" "$data" | wa_put "$n" "$u" ;;
    libput)        wa_libput "$arg" "$u" "$data" | wa_put "$n" "$u" ;;
    *)             wa_log "wa: unsupported request '$verb'"; echo "error=unsupported" | wa_put "$n" "$u" ;;
    esac
}

wa_clean() { tr -cd 'A-Za-z0-9 ._:/()+,=@#%-' | cut -c1-"${1:-120}"; }
wa_df() {
    [ -e "$2" ] || return 0
    l=$(df -kP "$2" 2>/dev/null | tail -1)
    [ -n "$l" ] || l=$(df -k "$2" 2>/dev/null | tail -1)
    set -- "$1" $l
    [ $# -ge 5 ] && echo "df.$1=$3 $4 $5"
}

wa_sysinfo() {
    echo "ok=1"
    echo "model=Kobo Libra 2 (N418)"
    echo "firmware=$(kobo_firmware 2>/dev/null | wa_clean 80)"
    echo "vdversion=$(cat "$VD/VERSION" 2>/dev/null | wa_clean 32)"
    echo "kernel=$(uname -r | wa_clean 60)"
    up=$(cut -d' ' -f1 /proc/uptime); up=${up%%.*}
    echo "uptime=$up"
    p=$(cat "$W/pid" 2>/dev/null)
    if [ -n "$p" ] && [ -r "/proc/$p/stat" ]; then
        st=$(awk '{ print int($22 / 100) }' "/proc/$p/stat" 2>/dev/null)
        [ -n "$st" ] && echo "androidup=$((up - st))"
    fi
    echo "mode=$(cat "$W/mode" 2>/dev/null | wa_clean 12)"
    [ -f "$W/frozen" ] && echo "frozen=1" || echo "frozen=0"
    [ -f "$W/fw/paused" ] && echo "fwpaused=1" || echo "fwpaused=0"
    echo "autoupdate=0"
    echo "autoupdaterun=0"
    wa_df kindle /mnt/onboard
    wa_df android "$SYS"
    wa_df root /
    [ -f "$SYSTEM_IMG" ] && echo "sysimg=$(stat -c %s "$SYSTEM_IMG" 2>/dev/null)"
    type st_info >/dev/null 2>&1 && st_info
    [ -f "$W/wa.du" ] && cat "$W/wa.du"
    cat /proc/[0-9]*/status 2>/dev/null | awk '
        function out() { if (n ~ /^(veradroid-.*|pivot_init|dropbear|luajit|nickel|sickel|wpa_supplicant|vdloopdio)$/ && p != "") {
                             gsub(/[^A-Za-z0-9._-]/, "", n); printf "hp=%s|%s|%s|%d\n", p, substr(n, 1, 24), st, r } }
        /^Name:/ { out(); n = $2; st = "?"; r = 0; p = "" }
        /^State:/ { st = $2 } /^Pid:/ { p = $2 } /^VmRSS:/ { r = $2 }
        END { out() }'
    for k in cmd watchdog sleep dedup; do
        p=$(cat "$W/$k.pid" 2>/dev/null)
        [ -n "$p" ] && [ -r "/proc/$p/status" ] || continue
        s=$(sed -n 's/^State:[[:space:]]*\([A-Z]\).*/\1/p' "/proc/$p/status" 2>/dev/null)
        r=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$p/status" 2>/dev/null)
        echo "hs=$p|$k|${s:-?}|${r:-0}"
    done
    wa_sshstate
}

wa_dusum() { du -sk "$@" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'; }
wa_du() {
    {
        echo "du.system=$(wa_dusum "$R/system")"
        echo "du.apps=$(wa_dusum "$SYS/data/app" "$SYS/data/app-lib" "$SYS/data/dalvik-cache")"
        echo "du.appdata=$(wa_dusum "$SYS/data/data")"
        m=0
        for d in "$SYS"/data/media/0/* "$SYS"/data/media/0/.[!.]*; do
            [ -e "$d" ] || continue
            case "${d##*/}" in KindleLibrary|KindleFonts|Fonts) continue ;; esac
            m=$((m + $(wa_dusum "$d")))
        done
        echo "du.media=$m"
        echo "du.program=$(wa_dusum "$VD")"
        echo "du.kindledocs=$(wa_dusum "$DOCS_DIR")"
        echo "du.time=$(date +%s)"
    } > "$W/wa.du.tmp" && mv -f "$W/wa.du.tmp" "$W/wa.du"
    echo "ok=1"; cat "$W/wa.du"
}

wa_logtail() {
    nl=${1%% *}; w=main
    [ "$nl" = "$1" ] || w=${1#* }
    case "$nl" in ''|*[!0-9]*) nl=200 ;; esac
    [ "$nl" -ge 1 ] && [ "$nl" -le 2000 ] || nl=200
    case "$w" in
        main) lf=$LOG ;;
        fsck) lf=$VD/logs/resize.log ;;
        *)    lf=$LOG ;;
    esac
    [ -f "$lf" ] && [ ! -L "$lf" ] || { echo "(暂无日志)"; return; }
    tail -n "$nl" "$lf" 2>/dev/null | tr -d '\000' | tail -c 524288
}

wa_shot() {
    o=$WA_OUT/$1
    fbd=/sys/class/graphics/fb0
    bpp=$(cat "$fbd/bits_per_pixel" 2>/dev/null)
    stride=$(cat "$fbd/stride" 2>/dev/null)
    pany=$(cut -d, -f2 "$fbd/pan" 2>/dev/null)
    xres=1264; yres=1680
    if [ "$bpp" = 8 ] && [ -n "$stride" ] && [ "$xres" -le "$stride" ] 2>/dev/null; then
        { echo "fb $xres $yres $stride"; dd if=/dev/fb0 bs="$stride" skip="${pany:-0}" count="$yres" 2>/dev/null; } > "$o.tmp"
    else
        $(vd_in) /system/bin/screencap -p "/dev/kfb/wa/$1.tmp" >/dev/null 2>&1
    fi
    if [ -s "$o.tmp" ]; then chown "$2" "$o.tmp" && chmod 400 "$o.tmp" && mv -f "$o.tmp" "$o.out"
    else rm -f "$o.tmp"; echo "error=screenshot failed" | wa_put "$1" "$2"; fi
}

wa_sshstate() {
    echo "ok=1"
    dp=$(pidof dropbear 2>/dev/null | awk '{print $1}')
    if [ -n "$dp" ]; then
        echo "running=1"
        echo "port=2222"
    else
        echo "running=0"
    fi
    echo "script=1"
    echo "ip=$(kobo_wifi_ip)"
}

# Store Wi-Fi hex SSID + hex PSK securely in root-only $W/wifi.psk for immediate wificonnect
wa_wifipsk() {
    hn=$1; hp=$2
    case "$hn" in ''|*[!0-9a-f]*) echo "ok=0"; echo "error=bad_ssid"; return 0 ;; esac
    case "$hp" in ''|*[!0-9a-f]*) echo "ok=0"; echo "error=bad_psk"; return 0 ;; esac
    ( umask 077; printf '%s %s\n' "$hn" "$hp" > "$W/wifi.psk.tmp" && mv -f "$W/wifi.psk.tmp" "$W/wifi.psk" )
    echo "ok=1"
}

wa_libput() {
    id=$1; lu=$2; name=$(printf '%s' "$3" | tr -d '\000-\037\177' | head -c 200)
    case "$id" in ''|*[!0-9a-f]*) echo "error=badid"; return 0 ;; esac
    src=$SYS/data/data/$WA_PKG/files/libput/$id.part
    if [ ! -f "$src" ] || [ -L "$src" ] || [ "$(stat -c %u "$src" 2>/dev/null)" != "$lu" ]; then
        echo "error=source"; return 0
    fi
    case "$name" in ''|.*|*/*) rm -f "$src"; echo "error=name"; return 0 ;; esac
    mkdir -p "$DOCS_DIR" 2>/dev/null || true
    final=$name; base=${name%.*}; ext=; [ "$base" != "$name" ] && ext=.${name##*.}; k=2
    while [ -e "$DOCS_DIR/$final" ] && [ $k -le 99 ]; do
        final="$base ($k)$ext"; k=$((k + 1))
    done
    sz=$(stat -c %s "$src" 2>/dev/null)
    if cp "$src" "$DOCS_DIR/$final" 2>/dev/null; then
        rm -f "$src"
        echo "ok=1"; echo "name=$final"; echo "size=${sz:-0}"
    else
        rm -f "$src"
        echo "error=write"
    fi
}
