#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Compile com.tencent.weread.eink with ART speed-profile using its recorded
# hot-method profile (/data/misc/profiles/cur/0/com.tencent.weread.eink/primary.prof).
# Keeps hot reading/rendering methods AOT-compiled while shrinking base.odex from
# ~70 MB (full speed) to ~15-30 MB to save page cache on 512 MB RAM.
# Zero modification to base.apk.
set -eu

VD=${VD:-/mnt/onboard/.adds/veradroid-libra2}
SYS=$VD/sys
PKG=com.tencent.weread.eink
PROF=$SYS/data/misc/profiles/cur/0/$PKG/primary.prof

[ -s "$PROF" ] || { echo "weread-speed-profile: no non-empty profile at $PROF" >&2; exit 2; }

ODEX=
for o in "$SYS"/data/app/"$PKG"-*/oat/arm/base.odex; do
    [ -f "$o" ] && { ODEX=$o; break; }
done
[ -n "$ODEX" ] || { echo "weread-speed-profile: base.odex not found" >&2; exit 3; }

echo "Profile: $(ls -lh "$PROF" | awk '{print $5, $NF}')"
echo "Before:  $(ls -lh "$ODEX" | awk '{print $5}') filter=$(dd if="$ODEX" bs=4096 count=4 2>/dev/null | tr '\0' '\n' | sed -n '/^compiler-filter$/{n;p;q;}')"

# Stop WeRead before recompiling so it never maps a half-written odex
sh "$VD/boot/ashell.sh" "am force-stop $PKG" >/dev/null 2>&1 || true
sleep 1

# Single-threaded dex2oat to keep peak RSS low on 512 MB RAM
sh "$VD/boot/ashell.sh" "setprop dalvik.vm.dex2oat-threads 1; setprop dalvik.vm.dex2oat-flags --no-watch-dog; cmd package compile -m speed-profile -f $PKG"

echo "After:   $(ls -lh "$ODEX" | awk '{print $5}') filter=$(dd if="$ODEX" bs=4096 count=4 2>/dev/null | tr '\0' '\n' | sed -n '/^compiler-filter$/{n;p;q;}')"
