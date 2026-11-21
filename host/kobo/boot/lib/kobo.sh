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
        v=$(cat "$p" 2>/dev/null | tr -cd '0-9')
        [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && return 0
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
    [ -d /sys/class/net/wlan0 ] || { echo 0; return 0; }
    st=$(cat /sys/class/net/wlan0/operstate 2>/dev/null)
    case "$st" in
        down) echo 0 ;;
        *)    [ -n "$(kobo_wifi_ip)" ] || [ "$st" = up ] && echo 1 || echo 0 ;;
    esac
}

kobo_wifi_set() { # $1 = 0|1
    wdir=/drivers/mx6sll-ntx/wifi
    if [ "$1" = 0 ]; then
        cp -a /etc/resolv.conf /tmp/vd-resolv.bak 2>/dev/null || true
        if [ -x /sbin/dhcpcd ]; then
            /sbin/dhcpcd -k wlan0 >/dev/null 2>&1 || true
        fi
        killall -q -TERM udhcpc dhcpcd 2>/dev/null || true
        command -v wpa_cli >/dev/null 2>&1 && wpa_cli -i wlan0 terminate >/dev/null 2>&1 || true
        killall -q -TERM wpa_supplicant 2>/dev/null || true
        ifconfig wlan0 down 2>/dev/null || true
        if grep -q '^8723ds ' /proc/modules 2>/dev/null; then
            usleep 200000
            rmmod 8723ds >/dev/null 2>&1 || true
        fi
        if grep -q '^sdio_wifi_pwr ' /proc/modules 2>/dev/null; then
            usleep 200000
            rmmod sdio_wifi_pwr >/dev/null 2>&1 || true
        fi
        [ -s /tmp/vd-resolv.bak ] && [ ! -s /etc/resolv.conf ] && mv -f /tmp/vd-resolv.bak /etc/resolv.conf 2>/dev/null || rm -f /tmp/vd-resolv.bak
    elif [ "$1" = 1 ]; then
        if ! grep -q '^sdio_wifi_pwr ' /proc/modules 2>/dev/null && [ -f "$wdir/sdio_wifi_pwr.ko" ]; then
            insmod "$wdir/sdio_wifi_pwr.ko" >/dev/null 2>&1 || true
            usleep 250000
        fi
        if ! grep -q '^8723ds ' /proc/modules 2>/dev/null && [ -f "$wdir/8723ds.ko" ]; then
            insmod "$wdir/8723ds.ko" >/dev/null 2>&1 || true
            sleep 1
        fi
        ifconfig wlan0 up 2>/dev/null || true
        kobo_wpa_ensure >/dev/null 2>&1 || true
        command -v wpa_cli >/dev/null 2>&1 && wpa_cli -i wlan0 reconnect >/dev/null 2>&1 || true
        if [ -x /sbin/dhcpcd ]; then
            /sbin/dhcpcd -d -t 20 -w wlan0 >/dev/null 2>&1 || true
        else
            udhcpc -S -i wlan0 -s /etc/udhcpc.d/default.script -b -q >/dev/null 2>&1 || true
        fi
        # Wait briefly for IP assignment so status_write and hostnet_write see the live IP
        i=0
        while [ $i -lt 10 ]; do
            [ -n "$(kobo_wifi_ip)" ] && break
            sleep 1; i=$((i + 1))
        done
    fi
}

kobo_wpa_ensure() {
    [ -S /var/run/wpa_supplicant/wlan0 ] && return 0
    [ -f /etc/wpa_supplicant/wpa_supplicant.conf ] || return 1
    mkdir -p /var/run/wpa_supplicant 2>/dev/null || true
    killall -q -TERM wpa_supplicant 2>/dev/null || true
    usleep 300000
    wpa_supplicant -D nl80211 -s -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf -C /var/run/wpa_supplicant -B >/dev/null 2>&1 || return 1
    i=0
    while [ $i -lt 15 ]; do
        [ -S /var/run/wpa_supplicant/wlan0 ] && return 0
        usleep 200000; i=$((i + 1))
    done
    [ -S /var/run/wpa_supplicant/wlan0 ]
}

kobo_wifi_current() {
    cur=
    if [ -S /var/run/wpa_supplicant/wlan0 ] && command -v wpa_cli >/dev/null 2>&1; then
        cur=$(wpa_cli -i wlan0 status 2>/dev/null | sed -n 's/^ssid=//p' | head -1)
    fi
    if [ -z "$cur" ] && command -v iwconfig >/dev/null 2>&1; then
        cur=$(iwconfig wlan0 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p' | head -1)
    fi
    [ -n "$cur" ] && printf '%s\n' "$cur"
}

kobo_wifi_saved() {
    out=
    if [ -S /var/run/wpa_supplicant/wlan0 ] && command -v wpa_cli >/dev/null 2>&1; then
        out=$(wpa_cli -i wlan0 list_networks 2>/dev/null | awk -F'\t' 'NR > 1 && $2 != "" { print $2 }' | head -50)
    fi
    if [ -z "$out" ] && [ -r /etc/wpa_supplicant/wpa_supplicant.conf ]; then
        out=$(sed -n 's/^[[:space:]]*ssid="\([^"]*\)".*/\1/p' /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null | head -50)
    fi
    [ -n "$out" ] && printf '%s\n' "$out"
}

kobo_wifi_select() { # $1 = ssid
    command -v wpa_cli >/dev/null 2>&1 || return 1
    kobo_wpa_ensure || return 1
    nid=$(wpa_cli -i wlan0 list_networks 2>/dev/null | awk -F'\t' -v s="$1" 'NR > 1 && $2 == s { print $1; exit }')
    [ -n "$nid" ] || return 1
    wpa_cli -i wlan0 enable_network "$nid" >/dev/null 2>&1
    wpa_cli -i wlan0 select_network "$nid" >/dev/null 2>&1
}

# Scan nearby Wi-Fi APs via wpa_cli (or iwlist fallback when wpa ctrl socket was removed by Nickel)
# and print TAB-separated lines for WifiActivity:
#   saved(y|n) \t secured(y|n) \t bars(1..5) \t mgmt \t ssid
kobo_wifi_scan() {
    saved=$(kobo_wifi_saved)
    if [ -S /var/run/wpa_supplicant/wlan0 ] && command -v wpa_cli >/dev/null 2>&1; then
        wpa_cli -i wlan0 scan >/dev/null 2>&1 || true
        sleep 2
        res=$(wpa_cli -i wlan0 scan_results 2>/dev/null | awk -F'\t' -v saved="$saved" '
            BEGIN {
                n = split(saved, sv, "\n")
                for (i = 1; i <= n; i++) if (sv[i] != "") is_saved[sv[i]] = 1
            }
            NR > 1 && NF >= 5 && $5 != "" {
                ssid = $5; sig = $3 + 0; flags = $4
                if (!(ssid in best) || sig > best[ssid]) {
                    best[ssid] = sig
                    flg[ssid] = flags
                }
            }
            END {
                for (s in best) {
                    sig = best[s]
                    bars = (sig >= -55) ? 5 : (sig >= -65) ? 4 : (sig >= -75) ? 3 : (sig >= -85) ? 2 : 1
                    f = flg[s]
                    sec = (f ~ /WPA|WEP|RSN/) ? "y" : "n"
                    mgmt = (f ~ /WPA2/) ? "WPA2" : (f ~ /WPA/) ? "WPA" : (f ~ /WEP/) ? "WEP" : "NONE"
                    sv_f = (s in is_saved) ? "y" : "n"
                    printf "%s\t%s\t%d\t%s\t%s\n", sv_f, sec, bars, mgmt, s
                }
            }' | sort -t"$(printf '\t')" -k3,3nr)
        if [ -n "$res" ]; then
            printf '%s\n' "$res"
            return 0
        fi
    fi
    command -v iwlist >/dev/null 2>&1 || return 1
    iwlist wlan0 scan 2>/dev/null | awk -v saved="$saved" '
        BEGIN {
            n = split(saved, sv, "\n")
            for (i = 1; i <= n; i++) if (sv[i] != "") is_saved[sv[i]] = 1
        }
        function flush() {
            if (ssid != "") {
                if (!(ssid in best) || qual > best[ssid]) {
                    best[ssid] = qual
                    bsec[ssid] = sec
                    bmgmt[ssid] = mgmt
                }
            }
            ssid = ""; qual = 0; sec = "n"; mgmt = "NONE"
        }
        /Cell [0-9]+ - Address:/ { flush(); next }
        /ESSID:"/ {
            s = $0; sub(/.*ESSID:"/, "", s); sub(/".*/, "", s)
            ssid = s; next
        }
        /Encryption key:on/ { sec = "y"; if (mgmt == "NONE") mgmt = "WEP"; next }
        /WPA2|IEEE 802\.11i/ { sec = "y"; mgmt = "WPA2"; next }
        /WPA Version/ { sec = "y"; if (mgmt != "WPA2") mgmt = "WPA"; next }
        /Quality=/ {
            q = $0; sub(/.*Quality=/, "", q); sub(/\/.*/, "", q)
            qual = q + 0; next
        }
        END {
            flush()
            for (s in best) {
                q = best[s]
                bars = (q >= 80) ? 5 : (q >= 60) ? 4 : (q >= 40) ? 3 : (q >= 20) ? 2 : 1
                sv_f = (s in is_saved) ? "y" : "n"
                printf "%s\t%s\t%d\t%s\t%s\n", sv_f, bsec[s], bars, bmgmt[s], s
            }
        }' | sort -t"$(printf '\t')" -k3,3nr
}

# Add & connect to a new Wi-Fi network (open if $2 empty, WPA-PSK if $2 non-empty).
kobo_wifi_connect_new() { # $1 = ssid  $2 = psk (optional)
    command -v wpa_cli >/dev/null 2>&1 || return 1
    kobo_wpa_ensure || return 1
    nid=$(wpa_cli -i wlan0 list_networks 2>/dev/null | awk -F'\t' -v s="$1" 'NR > 1 && $2 == s { print $1; exit }')
    if [ -z "$nid" ]; then
        nid=$(wpa_cli -i wlan0 add_network 2>/dev/null | tail -1 | tr -cd '0-9')
        [ -n "$nid" ] || return 1
        wpa_cli -i wlan0 set_network "$nid" ssid "\"$1\"" >/dev/null 2>&1 || return 1
    fi
    if [ -n "$2" ]; then
        wpa_cli -i wlan0 set_network "$nid" psk "\"$2\"" >/dev/null 2>&1 || return 1
    else
        wpa_cli -i wlan0 set_network "$nid" key_mgmt NONE >/dev/null 2>&1 || return 1
    fi
    wpa_cli -i wlan0 enable_network "$nid" >/dev/null 2>&1 || return 1
    wpa_cli -i wlan0 select_network "$nid" >/dev/null 2>&1 || return 1
    wpa_cli -i wlan0 save_config >/dev/null 2>&1 || true
    return 0
}

# Timezone from /etc/localtime symlink (/etc/zoneinfo/Asia/Shanghai -> Asia/Shanghai)
kobo_tz() {
    lt=$(readlink /etc/localtime 2>/dev/null)
    case "$lt" in
        */zoneinfo/*) echo "${lt#*/zoneinfo/}" ;;
        *) echo "Asia/Shanghai" ;;
    esac
}
