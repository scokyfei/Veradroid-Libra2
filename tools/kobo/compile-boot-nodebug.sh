#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline maintenance script (run when VeraDroid is stopped, or live into staging dir):
# Rebuilds /system/framework/arm/boot*.{art,oat} and /system/framework/oat/arm/services.odex
# without ART 7.0's forced debuggable flag (--non-debuggable, cortex-a9) into
# $SYS/data/local/tmp/boot-nodebug/ so framework methods can be inlined across calls.
# container.sh automatically bind-mounts the rebuilt files on the next VeraDroid start.
set -eu

VD=${VD:-/mnt/onboard/.adds/veradroid-libra2}
SYS=$VD/sys
OUT=$SYS/data/local/tmp/boot-nodebug
OUT_NEW=$SYS/data/local/tmp/boot-nodebug.new

JARS="core-oj core-libart conscrypt okhttp core-junit bouncycastle ext framework telephony-common voip-common ims-common apache-xml org.apache.http.legacy.boot"

# Locate container root (either running /proc/$ZPID/root or offline mount)
ZPID=$(ps | grep "zygote" | grep -v grep | awk '{print $1}' | head -n 1 || true)
if [ -n "$ZPID" ] && [ -d "/proc/$ZPID/root/system/framework" ]; then
    R=/proc/$ZPID/root
elif [ -d "/tmp/veradroid/mnt/system/framework" ]; then
    R=/tmp/veradroid/mnt
else
    echo "compile-boot-nodebug: container root not mounted" >&2
    exit 2
fi

for j in $JARS; do
    [ -f "$R/system/framework/$j.jar" ] || { echo "compile-boot-nodebug: missing $j.jar" >&2; exit 3; }
done

rm -rf "$OUT_NEW"
mkdir -p "$OUT_NEW"

# Extract dex2oat command-line base address from existing boot.oat (default 0x30000000 on VeraDroid)
BASE_ADDR=$(dd if="$R/system/framework/arm/boot.oat" bs=8192 count=1 2>/dev/null | tr '\0' '\n' | grep -a '^--base=' | head -n 1 || true)
[ -n "$BASE_ADDR" ] || BASE_ADDR="--base=0x30000000"

SRC_DIR=${SRC_DIR:-/system/framework}
if [ -d "$SYS/data/local/tmp/boot-src" ] && [ -s "$SYS/data/local/tmp/boot-src/framework.jar" ]; then
    SRC_DIR=/data/local/tmp/boot-src
fi

# Guard against dex-stripped ROMs (e.g. 304-byte framework.jar with no classes.dex):
# Android 7.1.1 OAT embeds quickened DEX which cannot be fed directly back to dex2oat.
FW_SIZE=$(wc -c < "$R$SRC_DIR/framework.jar" 2>/dev/null || echo 0)
if [ "$FW_SIZE" -lt 100000 ]; then
    echo "compile-boot-nodebug: $SRC_DIR/framework.jar is dex-stripped (${FW_SIZE} bytes)." >&2
    echo "compile-boot-nodebug: provide unstripped AOSP javalib.jar files in \$SYS/data/local/tmp/boot-src/ (or rebuild AOSP without --debuggable)." >&2
    exit 5
fi

DEX_ARGS=
LOC_ARGS=
for j in $JARS; do
    DEX_ARGS="$DEX_ARGS --dex-file=$SRC_DIR/$j.jar"
    LOC_ARGS="$LOC_ARGS --dex-location=/system/framework/$j.jar"
done

PRELOAD_ARG=
[ -f "$R/system/etc/preloaded-classes" ] && PRELOAD_ARG="--image-classes=/system/etc/preloaded-classes"
COMPILED_ARG=
[ -f "$R/system/etc/compiled-classes" ] && COMPILED_ARG="--compiled-classes=/system/etc/compiled-classes"

echo "compile-boot-nodebug: building non-debuggable boot image ($BASE_ADDR, cortex-a9, src=$SRC_DIR) ..."
sh "$VD/boot/ashell.sh" "nice -n 10 /system/bin/dex2oat \
    --runtime-arg -Xms64m --runtime-arg -Xmx64m \
    $PRELOAD_ARG $COMPILED_ARG \
    $DEX_ARGS $LOC_ARGS \
    --oat-file=/data/local/tmp/boot-nodebug.new/boot.oat \
    --oat-location=/system/framework/arm/boot.oat \
    --image=/data/local/tmp/boot-nodebug.new/boot.art \
    $BASE_ADDR --instruction-set=arm --instruction-set-variant=cortex-a9 \
    --android-root=/system --include-patch-information \
    --runtime-arg -Xnorelocate --no-generate-debug-info \
    --multi-image --no-inline-from=core-oj.jar --compile-pic \
    --compiler-filter=speed --swap-file=/data/local/tmp/boot-nodebug.new/dex2oat.swap -j1"

rm -f "$OUT_NEW/dex2oat.swap"
[ -s "$OUT_NEW/boot.oat" ] && [ -s "$OUT_NEW/boot.art" ] || { echo "compile-boot-nodebug: boot.oat build failed" >&2; exit 4; }

for sj in services wifi-service; do
    if [ -s "$SYS$SRC_DIR/$sj.jar" ]; then
        echo "compile-boot-nodebug: compiling $sj.odex against new boot.art ..."
        sh "$VD/boot/ashell.sh" "nice -n 10 /system/bin/dex2oat \
            --runtime-arg -Xms32m --runtime-arg -Xmx64m \
            --boot-image=/data/local/tmp/boot-nodebug.new/boot.art \
            --dex-file=$SRC_DIR/$sj.jar --dex-location=/system/framework/$sj.jar \
            --oat-file=/data/local/tmp/boot-nodebug.new/$sj.odex \
            --instruction-set=arm --instruction-set-variant=cortex-a9 \
            --android-root=/system --no-generate-debug-info \
            --compiler-filter=speed --swap-file=/data/local/tmp/boot-nodebug.new/dex2oat.swap -j1"
        rm -f "$OUT_NEW/dex2oat.swap"
    fi
done

chmod 644 "$OUT_NEW"/boot*.art "$OUT_NEW"/boot*.oat "$OUT_NEW"/*.odex 2>/dev/null || true
rm -rf "$OUT"
mv "$OUT_NEW" "$OUT"
echo "compile-boot-nodebug: ready in $OUT (will be bind-mounted on next VeraDroid restart)"
