#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compile static ARMv7 (Cortex-A9 + NEON) host binaries for Kobo Libra 2 using Zig.
# Usage:
#   ZIG=/path/to/zig FBINK_DIR=/path/to/fbink sh tools/kobo/build-kobo-bin.sh [OUT_DIR]
set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT=${1:-$TOP/build/kobo-bin}
ZIG=${ZIG:-$(command -v zig 2>/dev/null || true)}
FBINK_DIR=${FBINK_DIR:-$TOP/third_party/fbink}

[ -n "$ZIG" ] && [ -x "$ZIG" ] || { echo "build-kobo-bin: set ZIG=/path/to/zig (0.13.x)" >&2; exit 2; }
[ -f "$FBINK_DIR/fbink.c" ] || { echo "build-kobo-bin: FBInk sources not found at $FBINK_DIR (set FBINK_DIR)" >&2; exit 2; }

mkdir -p "$OUT"
CACHE=${ZIG_CACHE_DIR:-$TOP/build/zig-cache}
mkdir -p "$CACHE"
export ZIG_GLOBAL_CACHE_DIR="$CACHE"
export ZIG_LOCAL_CACHE_DIR="$CACHE"

TARGET="-target arm-linux-musleabihf -mcpu=cortex_a9 -mfpu=neon -static -O2"
CC="$ZIG cc $TARGET"

echo "[1/5] veradroid-epd (FBINK_FOR_KOBO + NEON)"
$CC -pthread \
    -DFBINK_FOR_KOBO -DFBINK_MINIMAL -DFBINK_WITH_IMAGE -DFBINK_WITH_DRAW \
    -I"$TOP/display" -I"$FBINK_DIR" -I"$FBINK_DIR/i2c-tools/include" \
    "$TOP/display/legacy/epd.c" \
    "$FBINK_DIR/fbink.c" \
    "$FBINK_DIR/qimagescale/qimagescale.c" \
    "$FBINK_DIR/i2c-tools/lib/smbus.c" \
    -lm -o "$OUT/veradroid-epd"

echo "[2/5] veradroid-input"
$CC "$TOP/input/legacy/vinput.c" -lm -o "$OUT/veradroid-input"

echo "[3/5] pivot_init, vdlmk, vdloopdio, vdmkswap"
for p in pivot_init vdlmk vdloopdio vdmkswap; do
    $CC "$TOP/tools/src/$p.c" -o "$OUT/$p"
done

if [ -n "${BIONIC_LIBC:-}" ] && [ -f "$BIONIC_LIBC" ]; then
    echo "[3b/5] libkobo_madvise.so (Bionic LD_PRELOAD shim)"
    "$ZIG" cc -target arm-linux-gnueabi -mcpu=cortex_a9 -mfloat-abi=softfp -O2 \
        -shared -fPIC -nostdlib -fno-stack-protector -fno-unwind-tables \
        -fno-asynchronous-unwind-tables -Wl,-soname,libkobo_madvise.so \
        "$TOP/tools/kobo/libkobo_madvise.c" "$BIONIC_LIBC" \
        -o "$OUT/libkobo_madvise.so"
fi

if [ -n "${E2FSPROGS_TAR:-}" ] && [ -f "$E2FSPROGS_TAR" ]; then
    echo "[4/5] static mke2fs, e2fsck & resize2fs (e2fsprogs)"
    EW=$TOP/build/e2fs-kobo
    if [ ! -x "$OUT/mke2fs" ] || [ ! -x "$OUT/e2fsck" ] || [ ! -x "$OUT/resize2fs" ]; then
        rm -rf "$EW" && mkdir -p "$EW"
        tar -xJf "$E2FSPROGS_TAR" -C "$EW"
        ED=$(find "$EW" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        WRAP=$EW/zig-arm-cc
        printf '#!/bin/sh\nexec "%s" cc %s "$@"\n' "$ZIG" "$TARGET" > "$WRAP"
        chmod 755 "$WRAP"
        ARW=$EW/zig-ar
        printf '#!/bin/sh\nexec "%s" ar "$@"\n' "$ZIG" > "$ARW"
        chmod 755 "$ARW"
        RANW=$EW/zig-ranlib
        printf '#!/bin/sh\nexec "%s" ranlib "$@"\n' "$ZIG" > "$RANW"
        chmod 755 "$RANW"
        ( cd "$ED" && \
          ac_cv_func_lseek64=yes CC="$WRAP" AR="$ARW" RANLIB="$RANW" \
          CFLAGS="-O2 -D_LARGEFILE64_SOURCE" LDFLAGS="-static" PKG_CONFIG="" \
          ./configure --host=arm-linux-musleabihf --disable-nls --disable-fuse2fs \
            --disable-defrag --disable-imager --disable-debugfs --disable-uuidd \
            --disable-tdb --disable-fsck --disable-e2initrd-helper --disable-elf-shlibs \
            --without-libarchive >"$EW/configure.log" 2>&1 && \
          make -j4 libs >"$EW/make.log" 2>&1 && \
          make -j4 -C misc mke2fs.static >>"$EW/make.log" 2>&1 && \
          make -j4 -C e2fsck e2fsck.static >>"$EW/make.log" 2>&1 && \
          make -j4 -C resize resize2fs >>"$EW/make.log" 2>&1 )
        "$ZIG" objcopy --strip-all "$ED/misc/mke2fs.static" "$OUT/mke2fs"
        "$ZIG" objcopy --strip-all "$ED/e2fsck/e2fsck.static" "$OUT/e2fsck"
        "$ZIG" objcopy --strip-all "$ED/resize/resize2fs" "$OUT/resize2fs"
    fi
else
    echo "[4/5] skipping e2fsprogs (set E2FSPROGS_TAR to build static mke2fs/e2fsck/resize2fs)"
fi

echo "[5/5] done"
chmod 755 "$OUT"/*
ls -lh "$OUT"
