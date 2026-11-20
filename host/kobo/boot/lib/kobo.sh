# SPDX-License-Identifier: GPL-3.0-or-later
# Kobo Libra 2 hardware abstraction layer (HAL).
# Replaces Kindle lipc/powerd/wifid calls with direct Kobo sysfs / wpa_cli / busybox helpers.

# Kobo's /bin/busybox compiles in unshare & nsenter, but does not symlink them into PATH.
unshare() { busybox unshare "$@"; }
nsenter() { busybox nsenter "$@"; }

kobo_model() {
    ver=$(cat /mnt/onboard/.kobo/version 2>/dev/null)
    case "$ver" in
        N418*) echo libra2 ;;
        *)     echo libra2 ;;
    esac
}

kobo_firmware() {
    awk -F, '{print $3}' /mnt/onboard/.kobo/version 2>/dev/null
}

# Battery capacity (0..100) and charging state (returns 0 if charging/external power).
kobo_battery() {
    for p in /sys/class/power_supply/mc13892_bat/capacity /sys/class/power_supply/battery/capacity /sys/class/power_supply/*/capacity; do
        [ -r "$p" ] || continue
        v=$(cat "$p" 2>/dev/null | tr -cd '0-9')
        [ -n "$v" ] && { echo "$v"; return 0; }
    done
    echo 0
}

kobo_is_charging() {
    st=$(cat /sys/class/power_supply/mc13892_bat/status 2>/dev/null)
    case "$st" in Charging|Full) return 0 ;; esac
    for p in /sys/class/power_supply/acpwr/online /sys/class/power_supply/usbpwr/online; do
        [ "$(cat "$p" 2>/dev/null)" = 1 ] && return 0
    done
    return 1
}

# Frontlight brightness: 0..100 via /sys/class/backlight/mxc_msp430.0/brightness
KOBO_BL_BRIGHT=/sys/class/backlight/mxc_msp430.0/brightness
KOBO_BL_MAX=100
# ComfortLight PRO color mixer: 0..10, inverted (10 = coolest / 0 warmth, 0 = warmest / 24 warmth)
KOBO_BL_COLOR=/sys/class/backlight/lm3630a_led/color
KOBO_BL_COLOR_MAX=10

kobo_has_light() { [ -w "$KOBO_BL_BRIGHT" ]; }
kobo_has_warmth() { [ -w "$KOBO_BL_COLOR" ]; }

kobo_light_get() {
    [ -r "$KOBO_BL_BRIGHT" ] || { echo 0; return 1; }
    v=$(cat "$KOBO_BL_BRIGHT" 2>/dev/null | tr -cd '0-9')
    echo "${v:-0}"
}

kobo_light_set() {
    v=$1
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    [ "$v" -lt 0 ] && v=0
    [ "$v" -gt "$KOBO_BL_MAX" ] && v=$KOBO_BL_MAX
    [ -w "$KOBO_BL_BRIGHT" ] && printf '%d\n' "$v" > "$KOBO_BL_BRIGHT" 2>/dev/null
}

# VeraHome warmth scale is 0..24 (0 = cool, 24 = warmest).
# Kobo lm3630a_led/color is 10..0 (10 = cool, 0 = warmest).
kobo_warmth_get() {
    [ -r "$KOBO_BL_COLOR" ] || { echo 0; return 1; }
    raw=$(cat "$KOBO_BL_COLOR" 2>/dev/null | tr -cd '0-9')
    [ -n "$raw" ] || { echo 0; return 1; }
    [ "$raw" -gt "$KOBO_BL_COLOR_MAX" ] && raw=$KOBO_BL_COLOR_MAX
    inv=$(( KOBO_BL_COLOR_MAX - raw ))
    echo $(( (inv * 24 + KOBO_BL_COLOR_MAX / 2) / KOBO_BL_COLOR_MAX ))
}

kobo_warmth_set() {
    v=$1
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    [ "$v" -lt 0 ] && v=0
    [ "$v" -gt 24 ] && v=24
    inv=$(( (v * KOBO_BL_COLOR_MAX + 12) / 24 ))
    raw=$(( KOBO_BL_COLOR_MAX - inv ))
    [ "$raw" -lt 0 ] && raw=0
    [ "$raw" -gt "$KOBO_BL_COLOR_MAX" ] && raw=$KOBO_BL_COLOR_MAX
    [ -w "$KOBO_BL_COLOR" ] && printf '%d\n' "$raw" > "$KOBO_BL_COLOR" 2>/dev/null
}

# Wi-Fi helpers (wlan0 + wpa_cli)
kobo_wifi_ip() {
    ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | head -1
}

kobo_wifi_enabled() {
    [ -d /sys/class/net/wlan0 ] && [ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" != down ] && echo 1 || echo 0
}

kobo_wifi_current() {
    command -v wpa_cli >/dev/null 2>&1 || return 0
    wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^ssid=//p' | head -1
}

kobo_wifi_saved() {
    command -v wpa_cli >/dev/null 2>&1 || return 0
    wpa_cli -i wlan0 list_networks 2>/dev/null | awk -F'\t' 'NR > 1 && $2 != "" { print $2 }' | head -50
}

kobo_wifi_select() { # $1 = ssid
    command -v wpa_cli >/dev/null 2>&1 || return 1
    nid=$(wpa_cli -i wlan0 list_networks 2>/dev/null | awk -F'\t' -v s="$1" 'NR > 1 && $2 == s { print $1; exit }')
    [ -n "$nid" ] || return 1
    wpa_cli -i wlan0 select_network "$nid" >/dev/null 2>&1
}

# Timezone from /etc/localtime symlink (/etc/zoneinfo/Asia/Shanghai -> Asia/Shanghai)
kobo_tz() {
    lt=$(readlink /etc/localtime 2>/dev/null)
    case "$lt" in
        */zoneinfo/*) echo "${lt#*/zoneinfo/}" ;;
        *) echo "Asia/Shanghai" ;;
    esac
}
