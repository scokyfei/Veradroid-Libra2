#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Initialize the ext4 system image (veradroid-sys.img) on Kobo Libra 2 from
# VeraDroid legacy rootfs.tar.gz + user0 seed + APKs.
# Usage: sh init-sysimg.sh <rootfs.tar.gz> [size_mb=2048]
set -eu

VD=${VD:-$(cd "$(dirname "$0")/.." && pwd)}
ROOTFS_TAR=${1:?usage: init-sysimg.sh <rootfs.tar.gz> [size_mb]}
SIZE_MB=${2:-2048}
IMG=$VD/veradroid-sys.img
MP=$VD/sys

[ -f "$ROOTFS_TAR" ] || { echo "init-sysimg: missing $ROOTFS_TAR" >&2; exit 2; }
[ -x "$VD/bin/mke2fs" ] || { echo "init-sysimg: missing $VD/bin/mke2fs" >&2; exit 2; }

# Ensure not mounted
if grep -q " $MP " /proc/mounts; then
    echo "init-sysimg: $MP is mounted, stop VeraDroid first" >&2
    exit 1
fi

mkdir -p "$MP" "$VD/logs" "$VD/apps" "$VD/fonts" "$VD/screensaver"

if [ ! -f "$IMG" ]; then
    echo "[init-sysimg] allocating ${SIZE_MB}MB sparse/zero image at $IMG ..."
    dd if=/dev/zero of="$IMG" bs=1048576 count=0 seek="$SIZE_MB" 2>/dev/null || \
        dd if=/dev/zero of="$IMG" bs=1048576 count="$SIZE_MB"
    echo "[init-sysimg] formatting ext4 ..."
    "$VD/bin/mke2fs" -t ext4 -F -q -L veradroid -O ^metadata_csum,^64bit "$IMG"
fi

echo "[init-sysimg] mounting $IMG -> $MP ..."
mount -t ext4 -o loop,rw,noatime "$IMG" "$MP"
trap 'sync; umount "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null || true' EXIT

echo "[init-sysimg] extracting $ROOTFS_TAR ..."
rm -rf "$MP/rootfs.new"
mkdir -p "$MP/rootfs.new"
tar -xzf "$ROOTFS_TAR" -C "$MP/rootfs.new"
rm -rf "$MP/rootfs"
mv "$MP/rootfs.new" "$MP/rootfs"

# Prepare /data skeleton and seed user0 if fresh
mkdir -p "$MP/data/system/users/0" "$MP/data/media/0/Books" "$MP/data/local/tmp" "$MP/data/cache"
chmod 777 "$MP/data/media" "$MP/data/media/0" "$MP/data/media/0/Books" "$MP/data/local/tmp"

if [ -d "$VD/seed/user0" ] && [ ! -f "$MP/data/system/users/0/settings_global.xml" ]; then
    echo "[init-sysimg] seeding Android user 0 settings ..."
    cp -a "$VD/seed/user0"/* "$MP/data/system/users/0/"
    chown -R 1000:1000 "$MP/data/system/users/0" 2>/dev/null || true
fi
if [ -f "$VD/seed/user0.xml" ] && [ ! -f "$MP/data/system/users/0.xml" ]; then
    cp -a "$VD/seed/user0.xml" "$MP/data/system/users/0.xml"
    chown 1000:1000 "$MP/data/system/users/0.xml" 2>/dev/null || true
fi

# Install hwcomposer.kindle.so into rootfs
if [ -f "$VD/bin/hwcomposer.kindle.so" ] && [ -d "$MP/rootfs/system/lib/hw" ]; then
    cp "$VD/bin/hwcomposer.kindle.so" "$MP/rootfs/system/lib/hw/hwcomposer.kindle.so"
    chmod 644 "$MP/rootfs/system/lib/hw/hwcomposer.kindle.so"
fi

echo "libra2" > "$MP/model"
echo "[init-sysimg] done! $(df -h "$MP" | tail -1)"
sync
