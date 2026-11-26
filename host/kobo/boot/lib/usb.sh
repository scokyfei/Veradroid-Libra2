# SPDX-License-Identifier: GPL-3.0-or-later
# USB MTP live storage mode for VeraDroid on Kobo Libra 2 (ConfigFS + FunctionFS + umtprd).
# Exposes both Android /sdcard ($SYS/data/media/0) and Kobo /mnt/onboard over USB MTP
# without stopping Android or unmounting /mnt/onboard.
# Safety: UMTPRD_HIDE hides $SYSTEM_IMG and $SYS from MTP enumeration & deletion.

USB_CFGFS=/sys/kernel/config
USB_G=$USB_CFGFS/usb_gadget/veradroid
USB_FFS=/dev/ffs-mtp

usb_udc() {
    for u in /sys/class/udc/*; do
        [ -e "$u" ] || continue
        echo "${u##*/}"
        return 0
    done
    return 1
}

usb_udc_state() {
    u=$(usb_udc) || { echo none; return 1; }
    cat "/sys/class/udc/$u/state" 2>/dev/null || echo unknown
}

usb_mtp_running() {
    alive "$W/umtprd.pid"
}

# True when a PC host has enumerated our MTP gadget (never triggered by dumb wall chargers).
usb_mtp_active() {
    usb_mtp_running || return 1
    [ "$(usb_udc_state)" = configured ]
}

usb_mtp_start() {
    [ "${USB_MTP:-1}" = 0 ] && { t "usb: MTP disabled (USB_MTP=0)"; return 0; }
    [ -x "$VD/bin/umtprd" ] || { t "usb: umtprd binary missing, MTP off"; return 0; }

    udc=$(usb_udc) || { t "usb: no UDC found, MTP off"; return 0; }

    # Refuse to collide with an active legacy Kobo mass-storage session
    if grep -qE '^(g_file_storage|g_mass_storage) ' /proc/modules 2>/dev/null; then
        t "usb: legacy mass storage module loaded, skipping MTP"
        return 0
    fi

    # Already running and bound?
    if usb_mtp_running && [ -r "$USB_G/UDC" ] && [ "$(cat "$USB_G/UDC" 2>/dev/null)" = "$udc" ]; then
        return 0
    fi

    usb_mtp_stop

    # Ensure configfs is mounted
    if ! grep -q " $USB_CFGFS " /proc/mounts 2>/dev/null; then
        mkdir -p "$USB_CFGFS" 2>/dev/null || true
        mount -t configfs none "$USB_CFGFS" 2>/dev/null || {
            t "usb: failed to mount configfs"
            return 1
        }
    fi

    # Check if another gadget already owns this UDC
    for g in "$USB_CFGFS"/usb_gadget/*; do
        [ -d "$g" ] || continue
        [ "$g" = "$USB_G" ] && continue
        if [ "$(cat "$g/UDC" 2>/dev/null)" = "$udc" ]; then
            t "usb: UDC $udc already bound to ${g##*/}, skipping MTP"
            return 0
        fi
    done

    sn=$(awk -F, 'NR==1{print $1}' /mnt/onboard/.kobo/version 2>/dev/null | tr -cd 'A-Za-z0-9._-')
    [ -n "$sn" ] || sn=N418VERADROID
    ver=$(head -1 "$VD/VERSION" 2>/dev/null | tr -cd '0-9A-Za-z._-')
    [ -n "$ver" ] || ver=1.0.0

    # Build ConfigFS USB gadget (MTP via FunctionFS)
    mkdir -p "$USB_G" "$USB_G/strings/0x409" "$USB_G/configs/c.1/strings/0x409" "$USB_G/functions/ffs.mtp" 2>/dev/null || {
        t "usb: failed to create configfs gadget $USB_G"
        usb_mtp_stop
        return 1
    }

    echo 0x1D6B > "$USB_G/idVendor" 2>/dev/null || true
    echo 0x0100 > "$USB_G/idProduct" 2>/dev/null || true
    echo 0x0300 > "$USB_G/bcdDevice" 2>/dev/null || true
    echo 0x0200 > "$USB_G/bcdUSB" 2>/dev/null || true
    echo 0x00   > "$USB_G/bDeviceClass" 2>/dev/null || true
    echo 0x00   > "$USB_G/bDeviceSubClass" 2>/dev/null || true
    echo 0x00   > "$USB_G/bDeviceProtocol" 2>/dev/null || true

    printf '%s\n' "$sn" > "$USB_G/strings/0x409/serialnumber" 2>/dev/null || true
    printf '%s\n' "Kobo" > "$USB_G/strings/0x409/manufacturer" 2>/dev/null || true
    printf '%s\n' "Kobo Libra 2 (VeraDroid)" > "$USB_G/strings/0x409/product" 2>/dev/null || true
    printf '%s\n' "MTP" > "$USB_G/configs/c.1/strings/0x409/configuration" 2>/dev/null || true
    echo 500 > "$USB_G/configs/c.1/MaxPower" 2>/dev/null || true

    # Microsoft OS Descriptors 1.0 for driverless Windows 10/11 MTP recognition
    if [ -d "$USB_G/os_desc" ]; then
        echo 1       > "$USB_G/os_desc/use" 2>/dev/null || true
        echo 0x01    > "$USB_G/os_desc/b_vendor_code" 2>/dev/null || true
        echo MSFT100 > "$USB_G/os_desc/qw_sign" 2>/dev/null || true
        [ -L "$USB_G/os_desc/c.1" ] || ln -s "$USB_G/configs/c.1" "$USB_G/os_desc/c.1" 2>/dev/null || true
    fi

    [ -L "$USB_G/configs/c.1/ffs.mtp" ] || ln -s "$USB_G/functions/ffs.mtp" "$USB_G/configs/c.1/ffs.mtp" 2>/dev/null || {
        t "usb: failed to link ffs.mtp into configs/c.1"
        usb_mtp_stop
        return 1
    }

    mkdir -p "$USB_FFS" 2>/dev/null || true
    if ! grep -q " $USB_FFS " /proc/mounts 2>/dev/null; then
        mount -t functionfs mtp "$USB_FFS" 2>/dev/null || {
            t "usb: failed to mount functionfs at $USB_FFS"
            usb_mtp_stop
            return 1
        }
    fi

    # Write runtime umtprd config
    mkdir -p "$SYS/data/media/0" 2>/dev/null || true
    cat > "$W/umtprd.conf" <<EOF
loop_on_disconnect 1
umask 000
storage "$SYS/data/media/0" "VeraDroid" "rw"
storage "/mnt/onboard" "Kobo Onboard" "rw"
manufacturer "Kobo"
product "Kobo Libra 2 (VeraDroid)"
serial "$sn"
firmware_version "$ver"
interface "MTP"
mtp_extensions "microsoft.com: 1.0; android.com: 1.0;"
battery_capacity "/sys/class/power_supply/mc13892_bat/capacity"
perceived_device_type 0x5
usb_vendor_id 0x1D6B
usb_product_id 0x0100
usb_class 0x6
usb_subclass 0x1
usb_protocol 0x1
usb_dev_version 0x3008
sync_when_close 0x1
usb_max_rd_buffer_size 0x4000
usb_max_wr_buffer_size 0x4000
read_buffer_cache_size 0x10000
usb_functionfs_mode 0x1
usb_dev_path "$USB_FFS/ep0"
usb_epin_path "$USB_FFS/ep1"
usb_epout_path "$USB_FFS/ep2"
usb_epint_path "$USB_FFS/ep3"
usb_max_packet_size 0x200
EOF

    : > "$W/umtprd.log"
    UMTPRD_HIDE="$SYSTEM_IMG:$SYS" "$VD/bin/umtprd" -conf "$W/umtprd.conf" >>"$W/umtprd.log" 2>&1 </dev/null &
    echo $! > "$W/umtprd.pid"

    # Wait for umtprd to write FunctionFS descriptors to ep0 and create ep1..ep3
    i=0
    while [ $i -lt 30 ]; do
        [ -e "$USB_FFS/ep1" ] && break
        alive "$W/umtprd.pid" || break
        usleep 100000
        i=$((i + 1))
    done

    if ! alive "$W/umtprd.pid" || [ ! -e "$USB_FFS/ep1" ]; then
        t "usb: umtprd failed to initialize FunctionFS endpoints (see $W/umtprd.log)"
        usb_mtp_stop
        return 1
    fi

    if ! echo "$udc" > "$USB_G/UDC" 2>/dev/null; then
        t "usb: failed to bind UDC $udc"
        usb_mtp_stop
        return 1
    fi

    t "usb: MTP ready on $udc (pid=$(cat "$W/umtprd.pid"), stores=VeraDroid + Kobo Onboard)"
    type status_write >/dev/null 2>&1 && status_write 2>/dev/null || true
    return 0
}

usb_mtp_stop() {
    # 1. Unbind UDC first so host sees clean disconnect
    if [ -w "$USB_G/UDC" ]; then
        echo "" > "$USB_G/UDC" 2>/dev/null || true
    fi

    # 2. Stop umtprd cleanly
    p=$(cat "$W/umtprd.pid" 2>/dev/null)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        kill "$p" 2>/dev/null || true
        i=0
        while kill -0 "$p" 2>/dev/null && [ $i -lt 15 ]; do
            usleep 100000
            i=$((i + 1))
        done
        kill -9 "$p" 2>/dev/null || true
    fi
    rm -f "$W/umtprd.pid"

    # 3. Unmount FunctionFS
    if grep -q " $USB_FFS " /proc/mounts 2>/dev/null; then
        umount "$USB_FFS" 2>/dev/null || umount -l "$USB_FFS" 2>/dev/null || true
    fi
    rmdir "$USB_FFS" 2>/dev/null || true

    # 4. Tear down ConfigFS gadget hierarchy in strict reverse order
    if [ -d "$USB_G" ]; then
        rm -f "$USB_G/os_desc/c.1" 2>/dev/null || true
        rm -f "$USB_G/configs/c.1/ffs.mtp" 2>/dev/null || true
        rmdir "$USB_G/configs/c.1/strings/0x409" 2>/dev/null || true
        rmdir "$USB_G/configs/c.1" 2>/dev/null || true
        rmdir "$USB_G/functions/ffs.mtp" 2>/dev/null || true
        rmdir "$USB_G/strings/0x409" 2>/dev/null || true
        rmdir "$USB_G" 2>/dev/null || true
    fi
    return 0
}

usb_watch_stop() { usb_mtp_stop; }
