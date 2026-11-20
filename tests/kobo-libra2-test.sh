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
hits=$(grep -rnE '^[[:space:]]*[^#]*\b(lipc-get-prop|lipc-set-prop|lipc-wait-event|lipc-hash-prop|initctl|powerd_test)\b' "$TOP/host/kobo/boot" || true)
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
grep -q 'kobo_wipe_y8' "$TOP/display/legacy/epd.c" && ok "epd.c has Kobo strip-wipe page-turn animation" || fail "epd.c missing kobo_wipe_y8"
grep -q -- '--swap-xy' "$TOP/input/legacy/vinput.c" && ok "vinput.c has --swap-xy support" || fail "vinput.c missing --swap-xy"
grep -q -- '--keydev' "$TOP/input/legacy/vinput.c" && ok "vinput.c has --keydev support" || fail "vinput.c missing --keydev"
grep -q 'input_event_sec' "$TOP/input/legacy/vinput.c" && ok "vinput.c handles musl 64-bit time_t input_event_sec" || fail "vinput.c missing input_event_sec"
grep -q 'sl\[cur_slot\].tid != e->value' "$TOP/input/legacy/vinput.c" \
    && grep -q 'G_EDGE_THIRDS' "$TOP/input/legacy/vinput.c" \
    && grep -q 'G_EDGE_THIRDS' "$TOP/host/kobo/boot/lib/settings.sh" \
    && grep -q 'appopt' "$TOP/host/kobo/boot/action.sh" \
    && grep -qE '^[[:space:]]*eb\)' "$TOP/host/kobo/boot/action.sh" \
    && ok "vinput.c + Kobo host handle Elan repeated tracking-id and bottom-edge thirds" \
    || fail "missing Elan repeated tracking-id fix or G_EDGE_THIRDS wiring"
grep -q 'MSC_RAW_PORTRAIT_DOWN' "$TOP/input/legacy/vinput.c" \
    && grep -q 'G_AUTO_ROTATE' "$TOP/input/legacy/vinput.c" \
    && grep -q 'KFB_AUTO_ROTATE' "$TOP/host/kobo/boot/lib/settings.sh" \
    && grep -q 'PAGE_KEYS_SWAP' "$TOP/host/kobo/boot/lib/settings.sh" \
    && grep -qE '^[[:space:]]*autorot\)' "$TOP/host/kobo/boot/lib/cmd.sh" \
    && grep -q 'KFB_AUTO_ROTATE' "$TOP/android/packages/VeraHome/src/com/veradroid/home/BlocksSettings.java" \
    && grep -q 'PAGE_KEYS_SWAP' "$TOP/android/packages/VeraHome/src/com/veradroid/home/BlocksSettings.java" \
    && ok "gyro auto-rotate (with page-key follow) & page-key swap toggles wired end-to-end" \
    || fail "missing gyro auto-rotate or page-key swap wiring"

# 5. Kobo Libra 2 model profile, slimming/memory optimizations & launcher files
[ -f "$TOP/host/kobo/models/libra2.conf" ] \
    && grep -q 'TOUCH_SWAP_XY=1' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q 'KFB_DIM=off' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q 'KFB_HZ=20' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q 'PROC_LIMIT=2' "$TOP/host/kobo/models/libra2.conf" \
    && ok "libra2.conf model & memory profile present" || fail "libra2.conf invalid"
grep -q 'libkobo_madvise.so' "$TOP/host/kobo/boot/lib/afterboot.sh" \
    && grep -q 'libkobo_madvise.so' "$TOP/host/kobo/boot/ashell.sh" \
    && ok "adb_sh and ashell.sh export libkobo_madvise.so LD_PRELOAD" || fail "missing LD_PRELOAD in adb_sh/ashell.sh"
grep -q 'state/kobo-screen.raw' "$TOP/host/kobo/boot/lib/framework.sh" \
    && ok "framework.sh stores kobo-screen.raw on disk" || fail "framework.sh still uses tmpfs for screen backup"
[ -f "$TOP/host/kobo/koplugin/veradroid_libra2.koplugin/_meta.lua" ] \
    && [ -f "$TOP/host/kobo/koplugin/veradroid_libra2.koplugin/main.lua" ] \
    && ok "KOReader plugin files present" || fail "KOReader plugin missing"

# 6. UI Kobo rebranding checks (no user-facing Kindle strings in host/kobo or VeraHome)
kh_host=$(grep -rn 'Kindle' "$TOP/host/kobo/boot" | grep -vE 'KindleLibrary|KindleFonts|appprofiles\.conf|:[0-9]+:[[:space:]]*#' || true)
if [ -z "$kh_host" ]; then ok "zero user-facing Kindle strings in host/kobo/boot"
else fail "user-facing Kindle strings in host/kobo/boot: $kh_host"; fi

kh_home=$(grep -rn 'Kindle' "$TOP/android/packages/VeraHome/src" "$TOP/android/packages/VeraHome/assets" \
          | grep -vE 'KindleLibrary|KindleFonts|isKindleRoot|:[0-9]+:[[:space:]]*(//|\*)' || true)
if [ -z "$kh_home" ]; then ok "zero user-facing Kindle strings in VeraHome APK/web UI"
else fail "user-facing Kindle strings in VeraHome: $kh_home"; fi

grep -q 'static boolean isKobo()' "$TOP/android/packages/VeraHome/src/com/veradroid/home/HostLink.java" \
    && ok "VeraHome HostLink.isKobo() present" || fail "HostLink.isKobo() missing"

# 7. Settings/commands wiring checks (saver, lock, storage, webadmin, wifiscan, SYSTEM_FONT)
for mod in saver lock storage webadmin progress; do
    grep -q "\b$mod\b" "$TOP/host/kobo/boot/veradroid.sh" \
        || fail "veradroid.sh missing module $mod"
done
for verb in wifiscan storage netdiag wa saver; do
    grep -qE "^[[:space:]]*$verb\)" "$TOP/host/kobo/boot/lib/cmd.sh" \
        || fail "cmd.sh missing command $verb"
done
grep -q 'SYSTEM_FONT=' "$TOP/host/kobo/boot/lib/settings.sh" \
    && grep -q 'time_format_apply' "$TOP/host/kobo/boot/lib/settings.sh" \
    && ok "Kobo host settings & commands fully wired (saver/lock/storage/webadmin/wifiscan/font/time)" \
    || fail "settings.sh missing SYSTEM_FONT or time_format_apply"

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL KOBO LIBRA 2 STATIC CHECKS PASSED"
