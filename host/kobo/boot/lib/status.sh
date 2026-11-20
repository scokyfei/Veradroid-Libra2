# SPDX-License-Identifier: GPL-3.0-or-later
# Status reporter for VeraHome / panel on Kobo Libra 2.

status_write() {
    bat=$(kobo_battery)
    kobo_is_charging && chg=1 || chg=0
    fl=$(kobo_light_get)
    warm=$(kobo_warmth_get)
    wifi=$(kobo_wifi_enabled)
    slp=${SLEEP_TIMEOUT:-600}
    lan=$(kobo_wifi_ip)
    inv=$(sed -n 's/^KFB_INVERT=//p' "$X/settings" 2>/dev/null)
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
        lowmem && echo "lowmem=1" || echo "lowmem=0"
        echo "lowmem_setting=${LOWMEM:-auto}"
        echo "kindleui=$(kindle_ui_mode)"
        echo "sysversion=$(head -1 "$VD/VERSION" 2>/dev/null | tr -cd '0-9.')"
        echo "imageclass=kobo-libra2"
        echo "autoupdate=0"
        echo "update_available="
        echo "memtotal_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)"
        echo "memavail_mb=$(awk '/^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Cached:/{c=$2} END{print int((a ? a : f + c) / 1024)}' /proc/meminfo)"
        kobo_has_warmth && echo "haswarmth=1" || echo "haswarmth=0"
        echo "hassleeptime=1"
        kobo_has_light && echo "haslight=1" || echo "haslight=0"
        echo "haslightauto=0"
        type bat_status_lines >/dev/null 2>&1 && bat_status_lines
        ps=$(type wifi_ps_state >/dev/null 2>&1 && wifi_ps_state)
        [ -n "$ps" ] && echo "wifips=$ps"
        echo "wifipsmode=${WIFI_PS:-auto}"
        echo "model=libra2"
    } > "$X/ctl/status.tmp" && mv -f "$X/ctl/status.tmp" "$X/ctl/status"
}
