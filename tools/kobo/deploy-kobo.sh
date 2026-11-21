#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Package and deploy VeraDroid for Kobo Libra 2 over SSH.
#
# Usage:
#   KOBO_HOST=192.168.0.60 KOBO_PORT=2222 \
#   BIN_DIR=/path/to/kobo-bin \
#   LEGACY_DIR=/path/to/veradroid-pw6 \
#   KMOD_DIR=/path/to/Koboweread/kernels \
#   sh tools/kobo/deploy-kobo.sh [--init-img]
set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HOST=${KOBO_HOST:-192.168.0.60}
PORT=${KOBO_PORT:-2222}
USER=${KOBO_USER:-root}
REMOTE_VD=${KOBO_VD:-/mnt/onboard/.adds/veradroid-libra2}
BIN_DIR=${BIN_DIR:-$TOP/build/kobo-bin}
LEGACY_DIR=${LEGACY_DIR:-}
KMOD_DIR=${KMOD_DIR:-}
SSH_HELPER=${SSH_HELPER:-}
INIT_IMG=0
for arg in "$@"; do
    case "$arg" in --init-img) INIT_IMG=1 ;; esac
done

STAGE=$TOP/build/kobo-stage
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/kmod" "$STAGE/seed" "$STAGE/fonts" "$STAGE/apps" "$STAGE/logs"

echo "[1/4] Staging host/kobo scripts and models ..."
cp -a "$TOP/host/kobo/VERSION" "$STAGE/"
cp -a "$TOP/host/kobo/boot" "$STAGE/"
cp -a "$TOP/host/kobo/models" "$STAGE/"
cp -a "$TOP/host/kobo/koplugin" "$STAGE/"
cp -a "$TOP/host/kobo/nm" "$STAGE/"
chmod 755 "$STAGE/boot/veradroid.sh" "$STAGE/boot/stop.sh" "$STAGE/boot/action.sh" "$STAGE/boot/ashell.sh" "$STAGE/boot/init-sysimg.sh" "$STAGE/boot/resize.sh"

echo "[2/4] Staging compiled Kobo ARMv7 binaries ..."
for b in veradroid-epd veradroid-input pivot_init vdlmk vdloopdio vdmkswap e2fsck mke2fs; do
    [ -x "$BIN_DIR/$b" ] || { echo "deploy-kobo: missing $BIN_DIR/$b (run tools/kobo/build-kobo-bin.sh first)" >&2; exit 2; }
    cp "$BIN_DIR/$b" "$STAGE/bin/$b"
done
[ -x "$BIN_DIR/resize2fs" ] && cp "$BIN_DIR/resize2fs" "$STAGE/bin/resize2fs"
[ -x "$BIN_DIR/kobo-sdcard" ] && cp "$BIN_DIR/kobo-sdcard" "$STAGE/bin/kobo-sdcard"
[ -x "$BIN_DIR/fbink-img" ] && cp "$BIN_DIR/fbink-img" "$STAGE/bin/fbink-img"
[ -f "$BIN_DIR/libkobo_madvise.so" ] && cp "$BIN_DIR/libkobo_madvise.so" "$STAGE/bin/libkobo_madvise.so"
[ -f "$BIN_DIR/kobo-weread-opt.jar" ] && cp "$BIN_DIR/kobo-weread-opt.jar" "$STAGE/bin/kobo-weread-opt.jar"
[ -f "$BIN_DIR/ethernet-service-wifi.jar" ] && cp "$BIN_DIR/ethernet-service-wifi.jar" "$STAGE/bin/ethernet-service-wifi.jar"
[ -f "$BIN_DIR/VeraHome.apk" ] && cp "$BIN_DIR/VeraHome.apk" "$STAGE/bin/VeraHome.apk"

if [ -n "$LEGACY_DIR" ] && [ -d "$LEGACY_DIR" ]; then
    [ -f "$LEGACY_DIR/bin/hwcomposer.kindle.so" ] && cp "$LEGACY_DIR/bin/hwcomposer.kindle.so" "$STAGE/bin/"
    [ -d "$LEGACY_DIR/user0" ] && cp -a "$LEGACY_DIR/user0" "$STAGE/seed/"
    [ -f "$LEGACY_DIR/user0.xml" ] && cp -a "$LEGACY_DIR/user0.xml" "$STAGE/seed/"
    [ -f "$LEGACY_DIR/fonts/LXGWWenKai-Regular.ttf" ] && cp "$LEGACY_DIR/fonts/LXGWWenKai-Regular.ttf" "$STAGE/fonts/"
fi

if [ -n "$KMOD_DIR" ] && [ -d "$KMOD_DIR" ]; then
    echo "[3/4] Staging Kobo 4.1.15 kernel modules ..."
    for kver in 4.1.15-00868-g58a2758be07 4.1.15-00838-g349fbf5767c; do
        if [ -d "$KMOD_DIR/$kver" ]; then
            mkdir -p "$STAGE/kmod/$kver"
            cp -a "$KMOD_DIR/$kver"/*.ko "$STAGE/kmod/$kver/" 2>/dev/null || true
        fi
    done
fi

TAR=$TOP/build/veradroid-kobo-libra2-host.tar.gz
tar -czf "$TAR" -C "$STAGE" .
echo "[4/4] Packaged host payload: $TAR ($(du -h "$TAR" | awk '{print $1}'))"

run_remote() {
    if [ -n "$SSH_HELPER" ]; then
        python3 "$SSH_HELPER" "$1"
    else
        ssh -p "$PORT" -o StrictHostKeyChecking=no "$USER@$HOST" "$1"
    fi
}

put_file() {
    if [ -n "$SSH_HELPER" ]; then
        python3 "$SSH_HELPER" --put "$1" "$2"
    else
        scp -O -P "$PORT" -o StrictHostKeyChecking=no "$1" "$USER@$HOST:$2"
    fi
}

echo "[deploy] Uploading host payload to $HOST:$PORT -> $REMOTE_VD ..."
run_remote "mkdir -p $REMOTE_VD /mnt/onboard/.adds/koreader/plugins"
put_file "$TAR" "/tmp/veradroid-kobo-host.tar.gz"
run_remote "tar -xzf /tmp/veradroid-kobo-host.tar.gz -C $REMOTE_VD && rm -f /tmp/veradroid-kobo-host.tar.gz && cp -a $REMOTE_VD/koplugin/veradroid_libra2.koplugin /mnt/onboard/.adds/koreader/plugins/ && chmod 755 $REMOTE_VD/bin/* $REMOTE_VD/boot/*.sh"

if [ "$INIT_IMG" = 1 ]; then
    [ -n "$LEGACY_DIR" ] && [ -f "$LEGACY_DIR/rootfs.tar.gz" ] || { echo "deploy-kobo: --init-img needs LEGACY_DIR with rootfs.tar.gz" >&2; exit 2; }
    echo "[deploy] Uploading rootfs.tar.gz and initializing ext4 system image ..."
    put_file "$LEGACY_DIR/rootfs.tar.gz" "$REMOTE_VD/rootfs.tar.gz"
    run_remote "sh $REMOTE_VD/boot/init-sysimg.sh $REMOTE_VD/rootfs.tar.gz 2048 && rm -f $REMOTE_VD/rootfs.tar.gz"
fi

echo "[deploy] Complete! Start on Kobo via KOReader -> Tools -> VeraDroid (Libra 2), or SSH:"
echo "  sh $REMOTE_VD/boot/veradroid.sh home"
