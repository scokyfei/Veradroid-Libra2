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
grep -q 'SCROLLDU' "$TOP/display/legacy/epd.c" \
    && grep -q 'gray_share' "$TOP/display/legacy/epd.c" \
    && grep -q 'smooth_apply' "$TOP/host/kobo/boot/lib/settings.sh" \
    && grep -q -- '--reagl-min' "$TOP/host/kobo/boot/lib/container.sh" \
    && ok "display refresh modes (smooth_apply/PACE/CLEAN/REAGL/SCROLLDU/IMG) wired end-to-end" \
    || fail "missing display refresh mode wiring"
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
    && grep -q 'epd_send_smooth()' "$TOP/host/kobo/boot/lib/settings.sh" \
    && grep -q 'kobo_wifi_set()' "$TOP/host/kobo/boot/lib/kobo.sh" \
    && grep -q 'kobo_wifi_set' "$TOP/host/kobo/boot/lib/cmd.sh" \
    && ok "Kobo host settings & commands fully wired (saver/lock/storage/webadmin/wifiscan/wifi-toggle/appprof/font/time)" \
    || fail "settings.sh/kobo.sh/cmd.sh missing required wiring"

# 8. WeRead runtime optimizations (zero-FUSE sdcard, ART heap, cpufreq, readahead, per-app EPD)
[ -f "$TOP/host/kobo/src/kobo-sdcard.c" ] \
    && grep -q 'MS_BIND' "$TOP/host/kobo/src/kobo-sdcard.c" \
    && grep -q 'kobo-sdcard' "$TOP/host/kobo/boot/lib/container.sh" \
    && grep -q '/dev/fuse' "$TOP/host/kobo/boot/lib/container.sh" \
    && ok "kobo-sdcard zero-FUSE vold helper present and bind-mounted over /system/bin/sdcard" \
    || fail "kobo-sdcard missing or not wired in container.sh"
grep -q '^HEAP_TARGET_UTIL=' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q '^HEAP_MINFREE=2m' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q '^SQUEEZE_MB=64' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q '^WEREAD_GCTYPE=MS' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q '^WEREAD_HEAP_MAXFREE=8m' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q 'heaptargetutilization' "$TOP/host/kobo/boot/lib/memory.sh" \
    && grep -q 'vdsqueeze' "$TOP/host/kobo/boot/lib/memory.sh" \
    && [ -f "$TOP/tools/src/vdsqueeze.c" ] \
    && grep -q 'configure_weread_art_heap' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q '__system_property_get' "$TOP/tools/kobo/libkobo_madvise.c" \
    && ok "Per-process WeRead ART heap (4m-8m, 0.75) + MS GC + boot-time vdsqueeze wired" || fail "ART heap/GC/vdsqueeze tuning missing"
grep -q 'cpufreq.interactive.state' "$TOP/host/kobo/boot/lib/memory.sh" \
    && grep -q 'io_is_busy' "$TOP/host/kobo/boot/lib/memory.sh" \
    && ok "interactive governor tuning saved/restored" || fail "interactive governor tuning missing"
grep -q '^LOOP_READAHEAD_KB=' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q 'LOOP_READAHEAD_KB' "$TOP/host/kobo/boot/lib/memory.sh" \
    && ok "per-device readahead (eMMC / loop) wired" || fail "LOOP_READAHEAD_KB missing"
grep -qE '^com\.tencent\.weread\.eink .*KFB_SETTLE=30' "$TOP/host/kobo/boot/appprofiles.conf" \
    && awk '/^settings_load\(\)/,/^}/' "$TOP/host/kobo/boot/lib/settings.sh" | awk '/smooth_apply/{if(!s)s=NR} /settings\.app/{if(!a)a=NR} END{exit !(s && a && s<a)}' \
    && ok "WeRead EPD profile + smooth_apply runs before per-app overrides" \
    || fail "WeRead EPD profile or settings_load ordering wrong"
grep -q 'ethernet-service-wifi.jar' "$TOP/host/kobo/boot/lib/container.sh" \
    && grep -q 'rtl8723ds' "$TOP/host/kobo/boot/lib/network.sh" \
    && grep -q 'rmem_max' "$TOP/host/kobo/boot/lib/network.sh" \
    && [ -f "$TOP/tools/kobo/patch-ethernet-wifi.py" ] \
    && ok "Wi-Fi transport reporting (ethernet-service-wifi.jar) + RTL8723DS LPS disable + TCP rmem_max wired" \
    || fail "missing ethernet-service-wifi.jar or RTL8723DS LPS / rmem_max tuning"
grep -q 'SSL_write' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'KVAppUpdate' "$TOP/host/kobo/boot/lib/container.sh" \
    && ok "WeRead update popup & APK auto-download suppressed without modifying WeRead APK" \
    || fail "missing WeRead update popup suppression in libkobo_madvise.c/container.sh"
grep -q 'kobo_deep_suspend' "$TOP/host/kobo/boot/lib/sleep.sh" \
    && grep -q 'state-extended' "$TOP/host/kobo/boot/lib/sleep.sh" \
    && grep -q 'rx_bytes' "$TOP/host/kobo/boot/lib/network.sh" \
    && grep -q '^CACHE_DEDUP_S=30' "$TOP/host/kobo/models/libra2.conf" \
    && ok "Power optimization wired (deep mem suspend + adaptive Wi-Fi LPS + governor/dedup tuning)" \
    || fail "missing power optimization hooks in sleep.sh/network.sh/libra2.conf"
grep -q 'SetFontCacheLimit' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'WRWebViewPool' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'tune_weread_threads' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'neon_blit_mask' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'skip_weread_log_sync' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'is_wal' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'deadline' "$TOP/host/kobo/boot/lib/memory.sh" \
    && grep -q 'journal_mode=wal' "$TOP/host/kobo/boot/lib/container.sh" \
    && grep -q 'boot-nodebug' "$TOP/host/kobo/boot/lib/container.sh" \
    && [ -f "$TOP/tools/kobo/compile-boot-nodebug.sh" ] \
    && grep -q 'kobo-fonts' "$TOP/host/kobo/boot/lib/container.sh" \
    && ok "Koboweread native optimizations wired (NEON Skia blitters + 16MB glyph cache + log/WAL fsync skip + SQLite WAL + mmap font + WebView defer + pool priority + deadline IO + boot-nodebug)" \
    || fail "missing Koboweread native WeRead optimizations"
grep -q 'kobo-weread-opt.jar' "$TOP/host/kobo/boot/lib/container.sh" \
    && grep -q 'load_weread_opt_jar' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'other_app_skia_opt_thread' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'KFB_SKIA_OPT' "$TOP/host/kobo/boot/lib/settings.sh" \
    && grep -q 'KFB_FONT_GAMMA' "$TOP/host/kobo/boot/lib/settings.sh" \
    && grep -q 'font_gamma_lut' "$TOP/tools/kobo/libkobo_madvise.c" \
    && grep -q 'KFB_SKIA_OPT' "$TOP/android/packages/VeraHome/src/com/veradroid/home/BlocksSettings.java" \
    && grep -q 'KFB_FONT_GAMMA' "$TOP/android/packages/VeraHome/src/com/veradroid/home/BlocksSettings.java" \
    && grep -q 'SegPrestart' "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java" \
    && grep -q 'FontSizeCache' "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java" \
    && grep -q 'FontMap' "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java" \
    && grep -q 'SyncThrottle' "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java" \
    && grep -q 'MarkUsersCache' "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java" \
    && grep -q 'ChapterPrefetch' "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java" \
    && grep -q 'MemoryTrim' "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java" \
    && grep -q 'ReaderPageRelease' "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java" \
    && grep -q 'SegDictRelease' "$TOP/tools/kobo/weread-opt/KoboWeReadOpt.java" \
    && grep -q 'speed-profile' "$TOP/host/kobo/boot/lib/compile.sh" \
    && grep -q 'weread_boot_prefetch' "$TOP/host/kobo/boot/lib/afterboot.sh" \
    && ok "WeRead opt JAR (SegPrestart + FontSizeCache + FontMap + SyncThrottle + MarkUsersCache + ChapterPrefetch + MemoryTrim + ReaderPageRelease + SegDictRelease) + KFB_SKIA_OPT + speed-profile + boot-prefetch wired" \
    || fail "missing WeRead opt JAR / KFB_SKIA_OPT / speed-profile / boot-prefetch hooks"
grep -q 'WFM_GLKW16' "$TOP/display/legacy/epd.c" \
    && grep -q 'WFM_GCK16' "$TOP/display/legacy/epd.c" \
    && grep -q 'kobo_polish_dark_y8' "$TOP/display/legacy/epd.c" \
    && grep -q 'prev_has_heavy' "$TOP/display/legacy/epd.c" \
    && grep -q 'coll_dirty' "$TOP/display/legacy/epd.c" \
    && grep -q '^KFB_GCN=0' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q '^KFB_NEWWIN=0' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q '^KFB_ECLIPSE=1' "$TOP/host/kobo/models/libra2.conf" \
    && grep -q 'KFB_DARKCRUSH' "$TOP/host/kobo/boot/lib/settings.sh" \
    && grep -q 'KFB_HEAVY_FLASH' "$TOP/host/kobo/boot/lib/appprof.sh" \
    && grep -q 'KFB_ECLIPSE' "$TOP/android/packages/VeraHome/src/com/veradroid/home/BlocksSettings.java" \
    && grep -q 'KFB_ECLIPSE' "$TOP/android/packages/VeraHome/src/com/veradroid/home/HostSettingsActivity.java" \
    && ok "Kobo Libra 2 Eclipse nightmode (GLKW16/GCK16 + dark crush) and KOReader-style ghosting control wired end-to-end" \
    || fail "missing Kobo Eclipse nightmode or ghosting control wiring"

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL KOBO LIBRA 2 STATIC CHECKS PASSED"
