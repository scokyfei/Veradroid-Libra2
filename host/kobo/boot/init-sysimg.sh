#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Initialize or upgrade the ext4 system image (veradroid-sys.img) on Kobo Libra 2
# from a clean VeraDroid legacy rootfs.tar.gz + scrubbed user0 seed.
#
# Usage:
#   sh init-sysimg.sh <rootfs.tar.gz> [size_mb=2048]          (fresh install; preserves /data if img exists)
#   sh init-sysimg.sh --upgrade-rootfs <rootfs.tar.gz>        (replace rootfs only, keep all /data & settings)
set -eu

VD=${VD:-$(cd "$(dirname "$0")/.." && pwd)}
UPGRADE_ONLY=0
if [ "${1:-}" = "--upgrade-rootfs" ]; then
    UPGRADE_ONLY=1
    shift
fi

ROOTFS_TAR=${1:?usage: init-sysimg.sh [--upgrade-rootfs] <rootfs.tar.gz> [size_mb]}
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

mkdir -p "$MP" "$VD/logs" "$VD/apps" "$VD/fonts" "$VD/screensaver" "$VD/state" "$VD/update"

FRESH_IMG=0
if [ ! -f "$IMG" ]; then
    if [ "$UPGRADE_ONLY" = 1 ]; then
        echo "init-sysimg: --upgrade-rootfs requested but $IMG does not exist" >&2
        exit 2
    fi
    # Require SIZE_MB + 256 MB free on /mnt/onboard before allocating
    free_mb=$(df -kP /mnt/onboard 2>/dev/null | awk 'NR==2 { printf "%d", $4 / 1024 }')
    need_mb=$((SIZE_MB + 256))
    if [ -n "$free_mb" ] && [ "$free_mb" -lt "$need_mb" ] 2>/dev/null; then
        echo "init-sysimg: insufficient space on /mnt/onboard (${free_mb}MB free, need ${need_mb}MB)" >&2
        exit 21
    fi
    FRESH_IMG=1
    echo "[init-sysimg] allocating ${SIZE_MB}MB ext4 image at $IMG ..."
    dd if=/dev/zero of="$IMG.tmp" bs=1048576 count=0 seek="$SIZE_MB" 2>/dev/null || \
        dd if=/dev/zero of="$IMG.tmp" bs=1048576 count="$SIZE_MB"
    echo "[init-sysimg] formatting ext4 ..."
    "$VD/bin/mke2fs" -t ext4 -F -q -L veradroid -O ^metadata_csum,^64bit "$IMG.tmp"
    mv -f "$IMG.tmp" "$IMG"
fi

echo "[init-sysimg] mounting $IMG -> $MP ..."
mount -t ext4 -o loop,rw,noatime "$IMG" "$MP"
trap 'sync; umount "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null || true' EXIT

echo "[init-sysimg] extracting $ROOTFS_TAR ..."
rm -rf "$MP/rootfs.new"
mkdir -p "$MP/rootfs.new"
tar -xzf "$ROOTFS_TAR" -C "$MP/rootfs.new"
[ -e "$MP/rootfs.new/init" ] || { echo "init-sysimg: invalid rootfs (missing /init)" >&2; rm -rf "$MP/rootfs.new"; exit 3; }
rm -rf "$MP/rootfs"
mv "$MP/rootfs.new" "$MP/rootfs"

# Prepare /data skeleton and seed user0 ONLY if fresh (never clobber existing user data)
mkdir -p "$MP/data/system/users/0" "$MP/data/media/0/Books" "$MP/data/local/tmp" "$MP/data/cache"
chmod 777 "$MP/data/media" "$MP/data/media/0" "$MP/data/media/0/Books" "$MP/data/local/tmp" 2>/dev/null || true

if [ -d "$VD/seed/user0" ] && [ ! -f "$MP/data/system/users/0/settings_global.xml" ]; then
    echo "[init-sysimg] seeding clean Android user 0 settings ..."
    cp -a "$VD/seed/user0"/* "$MP/data/system/users/0/"
    # Generate a unique random 16-hex android_id per device instead of reusing a static seed ID
    if [ -f "$MP/data/system/users/0/settings_secure.xml" ] && [ -r /dev/urandom ]; then
        new_aid=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | od -An -v -tx1 | tr -d ' \n' | cut -c1-16)
        if [ "${#new_aid}" = 16 ]; then
            sed -i "s/\(name=\"android_id\" value=\"\)[0-9a-fA-F]*\"/\1${new_aid}\"/" \
                "$MP/data/system/users/0/settings_secure.xml" 2>/dev/null || true
        fi
    fi
    chown -R 1000:1000 "$MP/data/system/users/0" 2>/dev/null || true
fi
if [ -f "$VD/seed/user0.xml" ] && [ ! -f "$MP/data/system/users/0.xml" ]; then
    cp -a "$VD/seed/user0.xml" "$MP/data/system/users/0.xml"
    chown 1000:1000 "$MP/data/system/users/0.xml" 2>/dev/null || true
fi

# On rootfs upgrade, clear stale dalvik-cache so ART cleanly re-dexopts against the new system image
if [ "$UPGRADE_ONLY" = 1 ] || [ "$FRESH_IMG" = 0 ]; then
    rm -rf "$MP/data/dalvik-cache/arm/"* "$MP/data/dalvik-cache/profiles/"* 2>/dev/null || true
    echo "[init-sysimg] cleared stale dalvik-cache for rootfs upgrade"
fi

# Disable `mount rootfs rootfs / ro remount` so Android init does not flip the shared ext4 loop superblock read-only
if [ -f "$MP/rootfs/init.rc" ]; then
    sed -i 's|^[[:space:]]*mount rootfs rootfs / ro remount|# disabled for kobo shared loop: &|' "$MP/rootfs/init.rc"
fi

# Install hwcomposer.kindle.so into rootfs
if [ -f "$VD/bin/hwcomposer.kindle.so" ] && [ -d "$MP/rootfs/system/lib/hw" ]; then
    cp "$VD/bin/hwcomposer.kindle.so" "$MP/rootfs/system/lib/hw/hwcomposer.kindle.so"
    chmod 644 "$MP/rootfs/system/lib/hw/hwcomposer.kindle.so"
fi

# Record rootfs SHA-256 so future boots know whether rootfs.tar.gz is already installed
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$ROOTFS_TAR" | awk '{print $1}' > "$MP/rootfs.sha256" 2>/dev/null || true
fi

echo "libra2" > "$MP/model"
[ -f "$VD/VERSION" ] && cp "$VD/VERSION" "$MP/version" 2>/dev/null || true
echo "[init-sysimg] done! $(df -h "$MP" | tail -1)"
sync
