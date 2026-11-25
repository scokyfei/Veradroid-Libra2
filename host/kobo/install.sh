#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# VeraDroid for Kobo Libra 2 (N418) — CLI / SSH Installer & Upgrader.
# Automatically detects Fresh Install vs Incremental Upgrade, and configures
# both NickelMenu and KOReader entry points.
#
# Usage (run on Kobo Libra 2 via SSH):
#   sh /mnt/onboard/.adds/veradroid-libra2/install.sh [options]
# Options:
#   --auto            Install NickelMenu & KOReader entries if present (default)
#   --both            Install both NickelMenu & KOReader entries unconditionally
#   --nm              Install NickelMenu entry only
#   --koreader        Install KOReader plugin only
#   --size-mb <N>     Fresh image size in MB (default: 2048)
#   --force-fresh     Rebuild veradroid-sys.img from scratch (WIPES Android /data!)
set -eu

VD=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
NM_DIR=/mnt/onboard/.adds/nm
KO_DIR=/mnt/onboard/.adds/koreader
KO_PLUGINS=$KO_DIR/plugins
ENTRY_MODE=auto
SIZE_MB=2048
FORCE_FRESH=0

while [ $# -gt 0 ]; do
    case "$1" in
        --auto)        ENTRY_MODE=auto ;;
        --both)        ENTRY_MODE=both ;;
        --nm)          ENTRY_MODE=nm ;;
        --koreader)    ENTRY_MODE=koreader ;;
        --size-mb)     SIZE_MB=${2:?missing size}; shift ;;
        --force-fresh) FORCE_FRESH=1 ;;
        -h|--help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "install.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

echo "=== VeraDroid for Kobo Libra 2 Installer ==="
echo "Install dir: $VD"
echo "Version:     $(cat "$VD/VERSION" 2>/dev/null || echo unknown)"

# 1. Verify kernel compatibility
KREL=$(uname -r)
if [ ! -f "$VD/kmod/$KREL/binder_linux.ko" ]; then
    echo "ERROR: Unsupported Kobo kernel: $KREL" >&2
    echo "Supported kernels bundled in $VD/kmod/:" >&2
    ls -1 "$VD/kmod/" >&2 || true
    exit 1
fi
echo "Kernel OK:   $KREL"

# 2. Stop VeraDroid safely if running (without restarting Nickel to preserve SSH/Wi-Fi)
if [ -f /tmp/veradroid/pid ] && kill -0 "$(cat /tmp/veradroid/pid 2>/dev/null)" 2>/dev/null; then
    echo "Stopping running VeraDroid safely ..."
    mkdir -p /tmp/veradroid
    touch /tmp/veradroid/restarting
    sh "$VD/boot/stop.sh" || true
    rm -f /tmp/veradroid/restarting
fi

# 3. Ensure executable permissions
chmod 755 "$VD/bin/"* "$VD/boot/"*.sh "$VD/install.sh" 2>/dev/null || true
mkdir -p "$VD/apps" "$VD/fonts" "$VD/logs" "$VD/screensaver" "$VD/state" "$VD/update"

# 4. Install entry points (NickelMenu & KOReader)
inst_nm=0
inst_ko=0
case "$ENTRY_MODE" in
    both)     inst_nm=1; inst_ko=1 ;;
    nm)       inst_nm=1 ;;
    koreader) inst_ko=1 ;;
    auto)
        [ -d "$NM_DIR" ] && inst_nm=1
        [ -d "$KO_DIR" ] && inst_ko=1
        # If neither directory exists yet, stage NickelMenu entry by default
        [ "$inst_nm" = 0 ] && [ "$inst_ko" = 0 ] && inst_nm=1
        ;;
esac

if [ "$inst_nm" = 1 ] && [ -f "$VD/nm/veradroid_libra2" ]; then
    mkdir -p "$NM_DIR"
    cp -f "$VD/nm/veradroid_libra2" "$NM_DIR/veradroid_libra2"
    echo "Entry OK:    NickelMenu -> $NM_DIR/veradroid_libra2"
fi

if [ "$inst_ko" = 1 ] && [ -d "$VD/koplugin/veradroid_libra2.koplugin" ]; then
    mkdir -p "$KO_PLUGINS"
    rm -rf "$KO_PLUGINS/veradroid_libra2.koplugin"
    cp -a "$VD/koplugin/veradroid_libra2.koplugin" "$KO_PLUGINS/"
    echo "Entry OK:    KOReader   -> $KO_PLUGINS/veradroid_libra2.koplugin"
fi

# 5. Fresh install vs Incremental upgrade
IMG=$VD/veradroid-sys.img
if [ "$FORCE_FRESH" = 1 ] && [ -f "$IMG" ]; then
    echo "Removing existing $IMG (--force-fresh) ..."
    rm -f "$IMG"
fi

if [ ! -f "$IMG" ]; then
    echo "Mode:        FRESH INSTALL"
    if [ ! -f "$VD/rootfs.tar.gz" ]; then
        echo "ERROR: Fresh install requires $VD/rootfs.tar.gz (please use the -full.zip package)." >&2
        exit 2
    fi
    sh "$VD/boot/init-sysimg.sh" "$VD/rootfs.tar.gz" "$SIZE_MB"
    rm -f "$VD/rootfs.tar.gz"
    echo "Fresh install complete! Launch from NickelMenu or KOReader."
else
    echo "Mode:        INCREMENTAL UPGRADE (preserving existing $IMG & all user data)"
    if [ -f "$VD/rootfs.tar.gz" ]; then
        # Check whether rootfs changed
        want_sha=$(sha256sum "$VD/rootfs.tar.gz" 2>/dev/null | awk '{print $1}')
        have_sha=
        if mount -t ext4 -o loop,ro "$IMG" "$VD/sys" 2>/dev/null; then
            have_sha=$(cat "$VD/sys/rootfs.sha256" 2>/dev/null | tr -cd '0-9a-f')
            umount "$VD/sys" 2>/dev/null || true
        fi
        if [ -n "$want_sha" ] && [ -n "$have_sha" ] && [ "$want_sha" != "$have_sha" ]; then
            echo "Detected updated rootfs.tar.gz — upgrading rootfs while keeping /data ..."
            sh "$VD/boot/init-sysimg.sh" --upgrade-rootfs "$VD/rootfs.tar.gz"
        else
            echo "Android rootfs unchanged — keeping existing system image and /data."
        fi
        rm -f "$VD/rootfs.tar.gz"
    fi
    echo "Incremental upgrade complete! Launch from NickelMenu or KOReader."
fi
sync
