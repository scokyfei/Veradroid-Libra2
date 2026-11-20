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
    iwconfig "$d" 2>/dev/null | sed -n 's/.*Power Management:\(o[nf]*\).*/\1/p'
}

wifi_ps_set() {
    d=$(wifi_dev)
    iwconfig "$d" power "$1" 2>/dev/null || true
}

wifi_ps_off() {
    [ -f "$W/wifi.ps" ] && return 0
    [ "$(wifi_ps_state)" = on ] && wifi_ps_set off && touch "$W/wifi.ps" && t "wifi: power saving off"
    return 0
}

wifi_ps_restore() {
    [ -f "$W/wifi.ps" ] && rm -f "$W/wifi.ps" && wifi_ps_set on && t "wifi: power saving restored"
    return 0
}

wifi_ps_tick() {
    case "${WIFI_PS:-auto}" in
        on)  wifi_ps_restore ;;
        off) wifi_ps_off ;;
        *)
            d=$(wifi_dev); now=$(cut -d. -f1 /proc/uptime)
            rx=$(cat "/sys/class/net/$d/statistics/rx_bytes" 2>/dev/null || echo 0)
            set -- $(cat "$W/wifi.rx" 2>/dev/null); prx=${2:-$rx}; pt=${1:-$now}
            echo "$now $rx" > "$W/wifi.rx"
            busy=
            [ -f "$W/fwd.id" ] && busy=fwd
            dt=$((now - pt))
            [ "$dt" -gt 0 ] && [ $(( (rx - prx) / dt )) -ge "${WIFI_BUSY_BPS:-32768}" ] && busy=rx
            if [ -n "$busy" ]; then echo "$now" > "$W/wifi.busy"; wifi_ps_off
            elif [ -f "$W/wifi.ps" ] && [ $((now - $(cat "$W/wifi.busy" 2>/dev/null || echo 0))) -ge 60 ]; then wifi_ps_restore
            fi ;;
    esac
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
}
