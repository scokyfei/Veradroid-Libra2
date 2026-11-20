#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Static checks for the Kobo Libra 2 port (host/kobo, display/legacy/epd.c, input/legacy/vinput.c).
set -eu

TOP=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FAIL=0
ok()   { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# 1. Shell syntax check on all Kobo host & build scripts
bad_sh=
for f in $(find "$TOP/host/kobo" "$TOP/tools/kobo" -name '*.sh' | sort); do
    sh -n "$f" 2>/dev/null || bad_sh="$bad_sh $f"
done
if [ -z "$bad_sh" ]; then ok "all Kobo shell scripts pass sh -n"
else fail "sh -n failed:$bad_sh"; fi

# 2. No active Kindle-only runtime calls in host/kobo/boot (ignore comment lines)
hits=$(grep -rnE '^[[:space:]]*[^#]*\b(lipc-get-prop|lipc-set-prop|lipc-wait-event|lipc-hash-prop|initctl|powerd_test)\b' "$TOP/host/kobo/boot" \
       | grep -v 'progress\.sh:.*lipc-get-prop' || true)
if [ -z "$hits" ]; then ok "no active Kindle lipc/initctl calls in host/kobo/boot"
else fail "unexpected Kindle calls in host/kobo/boot: $hits"; fi

# 3. No /dev/shm or /mnt/base-us active runtime paths in Kobo core scripts
hits2=$(grep -rnE '^[[:space:]]*[^#]*(/dev/shm/|/mnt/base-us/)' \
        "$TOP/host/kobo/boot/veradroid.sh" \
        "$TOP/host/kobo/boot/stop.sh" \
        "$TOP/host/kobo/boot/action.sh" \
        "$TOP/host/kobo/boot/ashell.sh" \
        "$TOP/host/kobo/boot/lib/common.sh" \
        "$TOP/host/kobo/boot/lib/kobo.sh" \
        "$TOP/host/kobo/boot/lib/kmod.sh" \
        "$TOP/host/kobo/boot/lib/framework.sh" \
        "$TOP/host/kobo/boot/lib/container.sh" \
        "$TOP/host/kobo/boot/lib/input.sh" \
        "$TOP/host/kobo/boot/lib/network.sh" \
        "$TOP/host/kobo/boot/lib/memory.sh" \
        "$TOP/host/kobo/boot/lib/settings.sh" \
        "$TOP/host/kobo/boot/lib/status.sh" \
        "$TOP/host/kobo/boot/lib/sleep.sh" \
        "$TOP/host/kobo/boot/lib/cmd.sh" || true)
if [ -z "$hits2" ]; then ok "no /dev/shm or /mnt/base-us paths in Kobo core scripts"
else fail "unexpected Kindle paths in Kobo core scripts: $hits2"; fi

# 4. C source adaptations present
grep -q 'FBINK_FOR_KOBO' "$TOP/display/legacy/epd.c" && ok "epd.c has FBINK_FOR_KOBO support" || fail "epd.c missing FBINK_FOR_KOBO"
grep -q -- '--swap-xy' "$TOP/input/legacy/vinput.c" && ok "vinput.c has --swap-xy support" || fail "vinput.c missing --swap-xy"
grep -q -- '--keydev' "$TOP/input/legacy/vinput.c" && ok "vinput.c has --keydev support" || fail "vinput.c missing --keydev"
grep -q 'input_event_sec' "$TOP/input/legacy/vinput.c" && ok "vinput.c handles musl 64-bit time_t input_event_sec" || fail "vinput.c missing input_event_sec"

# 5. Kobo Libra 2 model profile & launcher files
[ -f "$TOP/host/kobo/models/libra2.conf" ] && grep -q 'TOUCH_SWAP_XY=1' "$TOP/host/kobo/models/libra2.conf" \
    && ok "libra2.conf model profile present" || fail "libra2.conf invalid"
[ -f "$TOP/host/kobo/koplugin/veradroid_libra2.koplugin/_meta.lua" ] \
    && [ -f "$TOP/host/kobo/koplugin/veradroid_libra2.koplugin/main.lua" ] \
    && ok "KOReader plugin files present" || fail "KOReader plugin missing"

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL KOBO LIBRA 2 STATIC CHECKS PASSED"
