# SPDX-License-Identifier: GPL-3.0-or-later
# Status reporter for VeraHome / panel on Kobo Libra 2.

vd_ver_gt() { # returns 0 if $1 > $2
    [ "$1" = "$2" ] && return 1
    printf '%s\n%s\n' "$1" "$2" | awk -F. '
        NR == 1 { n1 = split($0, a, ".") }
        NR == 2 { n2 = split($0, b, ".") }
        END {
            n = n1 > n2 ? n1 : n2
            for (i = 1; i <= n; i++) {
                x = a[i] + 0; y = b[i] + 0
                if (x > y) exit 0
                if (x < y) exit 1
            }
            exit 1
        }'
}

# Scan $VD/update/ and /sdcard/Download/ for Veradroid-Libra2-*.zip offline upgrade packages.
# Prints: "<fullpath>\t<version>\t<src>" (src = update|download) or empty if none.
offline_upd_find() {
    _best=; _bestv=; _bestsrc=
    for _dir_spec in "update:$VD/update" "download:$SYS/data/media/0/Download"; do
        _src=${_dir_spec%%:*}
        _dir=${_dir_spec#*:}
        [ -d "$_dir" ] || continue
        for _f in "$_dir"/Veradroid-Libra2-*.zip "$_dir"/VeraDroid-Kobo-Libra2-*.zip "$_dir"/veradroid-kobo-libra2-*.zip; do
            [ -f "$_f" ] || continue
            _bn=${_f##*/}
            _v=$(printf '%s' "$_bn" | sed -n 's/.*-\([0-9][0-9.]*\)\(-[a-zA-Z0-9_]*\)\{0,1\}\.zip$/\1/p')
            [ -n "$_v" ] || continue
            if [ -z "$_best" ] || vd_ver_gt "$_v" "$_bestv"; then
                _best=$_f; _bestv=$_v; _bestsrc=$_src
            fi
        done
    done
    [ -n "$_best" ] && printf '%s\t%s\t%s\n' "$_best" "$_bestv" "$_bestsrc"
}

status_write() {
    bat=$(kobo_battery)
    kobo_is_charging && chg=1 || chg=0
    fl=$(kobo_light_get)
    warm=$(kobo_warmth_get)
    wifi=$(kobo_wifi_enabled)
    slp=$(sed -n 's/^SLEEP_TIMEOUT=//p' "$SYS/settings.conf" 2>/dev/null | tail -n 1)
    case "$slp" in ''|*[!0-9]*) slp=${SLEEP_TIMEOUT:-600} ;; esac
    lan=$(kobo_wifi_ip)
    sshp=$(kobo_ssh_port)
    inv=$(sed -n 's/^KFB_INVERT=//p' "$X/settings" 2>/dev/null)
    sver=$(head -1 "$VD/VERSION" 2>/dev/null | sed 's/-.*//' | tr -cd '0-9.')
    ou_v=; ou_f=; ou_s=; ou_new=0
    ou_hit=$(offline_upd_find || true)
    if [ -n "$ou_hit" ]; then
        _ou_p=${ou_hit%%	*}; _ou_rest=${ou_hit#*	}
        ou_v=${_ou_rest%%	*}; ou_s=${_ou_rest#*	}
        ou_f=${_ou_p##*/}
        if [ -z "$sver" ] || vd_ver_gt "$ou_v" "$sver"; then ou_new=1; fi
    fi
    {
        echo "battery=${bat:-0}"
        echo "charging=${chg:-0}"
        echo "light=${fl:-0}"
        echo "lightmax=${KOBO_BL_MAX:-100}"
        echo "warmth=${warm:-0}"
        echo "wifi=${wifi:-1}"
        echo "invert=${inv:-0}"
        echo "sleep=${slp:-600}"
        echo "lanip=$lan"
        echo "ssh=${sshp:-0}"
        lowmem && echo "lowmem=1" || echo "lowmem=0"
        echo "sysversion=${sver}"
        echo "imageclass=kobo-libra2"
        echo "autoupdate=0"
        echo "update_available="
        echo "offline_upd=${ou_v}"
        echo "offline_upd_file=${ou_f}"
        echo "offline_upd_src=${ou_s}"
        echo "offline_upd_newer=${ou_new}"
        echo "memtotal_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)"
        echo "memavail_mb=$(awk '/^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Cached:/{c=$2} END{print int((a ? a : f + c) / 1024)}' /proc/meminfo)"
        kobo_has_warmth && echo "haswarmth=1" || echo "haswarmth=0"
        echo "hassleeptime=1"
        kobo_has_light && echo "haslight=1" || echo "haslight=0"
        echo "haslightauto=0"
        type bat_status_lines >/dev/null 2>&1 && bat_status_lines
        type bt_status_lines >/dev/null 2>&1 && bt_status_lines
        type usb_mtp_running >/dev/null 2>&1 && { usb_mtp_running && echo "usbmtp=1" || echo "usbmtp=0"; }
        type usb_mtp_active >/dev/null 2>&1 && { usb_mtp_active && echo "usbconn=1" || echo "usbconn=0"; }
        ps=$(type wifi_ps_state >/dev/null 2>&1 && wifi_ps_state)
        [ -n "$ps" ] && echo "wifips=$ps"
        echo "wifipsmode=${WIFI_PS:-auto}"
        echo "model=libra2"
    } > "$X/ctl/status.tmp" && mv -f "$X/ctl/status.tmp" "$X/ctl/status"
}
