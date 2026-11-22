# SPDX-License-Identifier: GPL-3.0-or-later
# Shared host networking for Kobo Libra 2 (HOSTNS=1 / VdHostNet).
# Android shares Kobo's wlan0 directly without net namespace or slirp4netns.

net_setup() {
    { for d in $ANDROID_DNS; do echo "nameserver $d"; done
      grep '^nameserver' "$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)" 2>/dev/null; } > "$W/resolv.conf"
}

wifi_dev() { for d in wlan0 eth0; do [ -d "/sys/class/net/$d" ] && { echo "$d"; return 0; }; done; echo wlan0; }

wifi_ps_state() {
    d=$(wifi_dev)
    if [ -r "/proc/net/rtl8723ds/$d/ps_info" ]; then
        grep -q 'LPS mode: NO LPS' "/proc/net/rtl8723ds/$d/ps_info" 2>/dev/null && echo off || echo on
        return 0
    fi
    iwconfig "$d" 2>/dev/null | sed -n 's/.*Power Management:\(o[nf]*\).*/\1/p'
}

wifi_ps_set() {
    d=$(wifi_dev)
    if [ -r "/proc/net/rtl8723ds/$d/ps_info" ] && command -v iwpriv >/dev/null 2>&1; then
        if [ "$1" = off ]; then
            echo 0 > /sys/module/8723ds/parameters/rtw_power_mgnt 2>/dev/null || true
            iwpriv "$d" pm_set "lps=0" >/dev/null 2>&1 || true
            iwpriv "$d" pm_set "ips=0" >/dev/null 2>&1 || true
        else
            echo 2 > /sys/module/8723ds/parameters/rtw_power_mgnt 2>/dev/null || true
            iwpriv "$d" pm_set "lps=2" >/dev/null 2>&1 || true
            iwpriv "$d" pm_set "ips=1" >/dev/null 2>&1 || true
        fi
        return 0
    fi
    iwconfig "$d" power "$1" 2>/dev/null || true
}

wifi_ps_off() {
    [ -f "$W/wifi.ps" ] && return 0
    if [ "$(wifi_ps_state)" = on ]; then
        wifi_ps_set off
        touch "$W/wifi.ps"
        t "wifi: power saving off"
    fi
    return 0
}

wifi_ps_restore() {
    [ -f "$W/wifi.ps" ] && rm -f "$W/wifi.ps" && wifi_ps_set on && t "wifi: power saving restored"
    if [ ! -f "$W/sleeping" ] && [ -f "$W/net.rmem.state" ]; then
        read -r rm wm < "$W/net.rmem.state"
        [ -n "$rm" ] && echo "$rm" > /proc/sys/net/core/rmem_max 2>/dev/null || true
        [ -n "$wm" ] && echo "$wm" > /proc/sys/net/core/wmem_max 2>/dev/null || true
        rm -f "$W/net.rmem.state"
    fi
    return 0
}

wifi_ps_tick() {
    case "${WIFI_PS:-auto}" in
        on)  wifi_ps_restore; return 0 ;;
        off) [ -f "$W/sleeping" ] || [ -f "$W/saver_frozen" ] || wifi_ps_off; return 0 ;;
    esac
    [ -f "$W/sleeping" ] || [ -f "$W/saver_frozen" ] && return 0
    # Adaptive Wi-Fi power saving on RTL8723DS:
    # Keep LPS=0 during active interaction (<15s since last touch/key) or downloads (>64 KB/tick);
    # drop to LPS=2 (saves ~70-80 mA) during idle reading pauses (>=15s since last input).
    d=$(wifi_dev)
    rx=$(cat "/sys/class/net/$d/statistics/rx_bytes" 2>/dev/null || echo 0)
    prev=$(cat "$W/wifi.rx" 2>/dev/null || echo "$rx")
    echo "$rx" > "$W/wifi.rx"
    delta=$((rx - prev))
    now_s=$(date +%s 2>/dev/null || echo 0)
    last_s=$(stat -c %Y "$W/lastinput" 2>/dev/null || echo 0)
    idle_s=$((now_s - last_s))
    if [ "$delta" -gt 65536 ] || { [ "$last_s" -gt 0 ] && [ "$idle_s" -lt 15 ]; }; then
        wifi_ps_off
    else
        [ -f "$W/wifi.ps" ] && rm -f "$W/wifi.ps" && wifi_ps_set on && t "wifi: idle (${idle_s}s) -> power saving on"
    fi
    return 0
}

hostnet_write() {
    dev=$(ip route 2>/dev/null | awk '$1 == "default" { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
    gw=$(ip route 2>/dev/null | awk '$1 == "default" { for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')
    [ -n "$dev" ] || dev=wlan0
    addr=$(ip -4 addr show dev "$dev" 2>/dev/null | awk '$1 == "inet" { print $2; exit }')
    if [ -z "$addr" ]; then
        ip4=$(kobo_wifi_ip)
        [ -n "$ip4" ] && addr="$ip4/24"
    fi
    {
        echo "iface=$dev"
        [ -n "$addr" ] && echo "addr=$addr"
        [ -n "$gw" ] && echo "gw=$gw"
        for d in $ANDROID_DNS; do echo "dns=$d"; done
        sed -n 's/^nameserver[[:space:]]*\([0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\)[[:space:]]*$/dns=\1/p' "$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)" 2>/dev/null
    } > "$X/hostnet.tmp"
    if [ -f "$X/hostnet" ] && cmp -s "$X/hostnet.tmp" "$X/hostnet"; then
        rm -f "$X/hostnet.tmp"
        return 0
    fi
    chmod 644 "$X/hostnet.tmp"
    mv -f "$X/hostnet.tmp" "$X/hostnet"
    t "net: hostnet $(tr '\n' ' ' < "$X/hostnet")"
}

hostnet_fix_rules() {
    for v in -4 -6; do
        ip $v rule 2>/dev/null | grep -qE '^(1[0-9]{4}|2[0-9]{4}|3[01][0-9]{3}|32000):' || continue
        ip $v rule 2>/dev/null | grep -q '^32766:' || ip $v rule add pref 32766 lookup main 2>/dev/null || true
        ip $v rule 2>/dev/null | grep -q '^32767:' || ip $v rule add pref 32767 lookup default 2>/dev/null || true
        for p in $(ip $v rule 2>/dev/null | sed -n 's/^\([0-9]*\):.*/\1/p'); do
            [ "$p" -ge 10000 ] && [ "$p" -le 32000 ] && ip $v rule del pref "$p" 2>/dev/null || true
        done
    done
    return 0
}

net_start() {
    hostnet_fix_rules
    hostnet_write
    # Default to power-saving LPS=2; adaptive wifi_ps_tick() boosts to LPS=0 during downloads.
    case "${WIFI_PS:-auto}" in
        off) wifi_ps_off ;;
        *)   wifi_ps_set on ;;
    esac
    if [ ! -f "$W/net.rmem.state" ] && [ -w /proc/sys/net/core/rmem_max ]; then
        echo "$(cat /proc/sys/net/core/rmem_max 2>/dev/null) $(cat /proc/sys/net/core/wmem_max 2>/dev/null)" > "$W/net.rmem.state"
        echo 1048576 > /proc/sys/net/core/rmem_max 2>/dev/null || true
        echo 1048576 > /proc/sys/net/core/wmem_max 2>/dev/null || true
    fi
}
