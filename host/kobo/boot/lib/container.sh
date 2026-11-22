# SPDX-License-Identifier: GPL-3.0-or-later
# Container lifecycle for VeraDroid on Kobo Libra 2:
#   - Private mount namespace via `busybox unshare -m` + `pivot_init` into $R
#   - Shared host network (HOSTNS=1 / androidboot.vdhostnet=1)
#   - Out-of-tree /dev/binder bound into container /dev/binder

input_find() { # $1 = regex matching N: Name=...
    awk -v pat="$1" '/^N: Name=/ { m = ($0 ~ pat) }
        m && /^H: Handlers=/ { for (i = 1; i <= NF; i++) if (match($i, /event[0-9]+$/)) { print "/dev/input/" substr($i, RSTART); exit } }' /proc/bus/input/devices
}

touch_setup() {
    # Physical keys on Kobo Libra 2 (gpio-keys) are grabbed & mapped by veradroid-input (--keydev).
    KFB_KEYS=
    export KFB_KEYS
}

display_prepare() {
    rm -rf "$X"; mkdir -p "$X/ctl"
    # Kobo Libra 2 native portrait panel is 1264x1680 (stride 1280).
    # FBInk -e reports viewWidth/viewHeight = 1264/1680.
    viewWidth=; viewHeight=; viewVisWidth=; deviceName="Kobo Libra 2"
    if [ -x "$FBINK" ]; then
        eval "$("$FBINK" -e 2>/dev/null)" || true
    fi
    if [ -z "$viewWidth" ] || [ -z "$viewHeight" ]; then
        m=$(sed -n 's/.*U:\([0-9][0-9]*\)x\([0-9][0-9]*\)p.*/\1 \2/p' $FB/modes 2>/dev/null | awk '$2 >= $1 { print; exit }')
        if [ -n "$m" ]; then
            set -- $m; viewWidth=$1; viewHeight=$2
        fi
    fi
    viewWidth=${viewWidth:-1264}
    viewHeight=${viewHeight:-1680}
    viewVisWidth=${viewWidth}
    case "$(rot_deg)" in
        90|270) echo "${viewHeight} ${viewVisWidth} ${deviceName}" > "$X/info" ;;
        *)      echo "${viewWidth} ${viewHeight} ${deviceName}" > "$X/info" ;;
    esac
    echo "libra2" > "$X/model"
    hwc_prepare
    chmod -R 777 "$X"
    t "display: prepared ${viewWidth}x${viewHeight} (${deviceName}), rot=$(rot_deg)"
}

hwc_prepare() {
    if [ -f "$VD/bin/hwcomposer.kindle.so" ] && [ -d "$R/system/lib/hw" ]; then
        if ! cmp -s "$VD/bin/hwcomposer.kindle.so" "$R/system/lib/hw/hwcomposer.kindle.so"; then
            cp "$VD/bin/hwcomposer.kindle.so" "$R/system/lib/hw/hwcomposer.kindle.so.new" \
                && chmod 644 "$R/system/lib/hw/hwcomposer.kindle.so.new" \
                && mv -f "$R/system/lib/hw/hwcomposer.kindle.so.new" "$R/system/lib/hw/hwcomposer.kindle.so" \
                && t "display: hwcomposer.kindle.so installed"
        fi
    fi
    if [ "${KFB_HWC:-1}" = 1 ] && [ -f "$R/system/lib/hw/hwcomposer.kindle.so" ]; then
        rm -f "$X/hwc.off"
    else
        touch "$X/hwc.off"
    fi
    case "$KFB_HZ" in 60|20|15) echo "$KFB_HZ" > "$X/hz" ;; *) echo 30 > "$X/hz" ;; esac
    case "${KFB_DIM:-20}" in
        off) echo -1 > "$X/hwc.dim" ;;
        ''|*[!0-9]*) echo 51 > "$X/hwc.dim" ;;
        *) d=${KFB_DIM}; [ "$d" -gt 100 ] && d=100; echo $((d * 255 / 100)) > "$X/hwc.dim" ;;
    esac
}

rot_deg() { case "$KFB_ROTATE" in 90|180|270) echo "$KFB_ROTATE" ;; *) echo 0 ;; esac; }

rot_args() {
    r=$(rot_deg); ra=
    if [ "$r" != 0 ]; then
        ra="--rotate $r"
    fi
    echo "$ra"
}

display_start() {
    [ -x "$VD/bin/veradroid-epd" ] || { t "display: veradroid-epd missing"; return 1; }
    : > "$W/epd.log"
    "$VD/bin/veradroid-epd" run "$X/fb" "$X/epd.fifo" "$X/ctl" \
        --w "${viewWidth:-1264}" --h "${viewHeight:-1680}" \
        --contrast "${KFB_CONTRAST:-1.3}" --dither "${KFB_DITHER:-3}" \
        --flash "${KFB_FLASH:-8}" --invert "${KFB_INVERT:-0}" \
        --lightf "${KFB_LIGHTF:-0}" --darken "${KFB_DARKEN:-0}" \
        --mode "${KFB_MODE:-0}" --settle "${KFB_SETTLE:-50}" --hold "${KFB_HOLD:-70}" \
        --reagl-min "${KFB_REAGL_MIN:-35}" --pace "${KFB_PACE:-0}" --clean "${KFB_CLEAN:-0}" \
        --scroll-du "${KFB_SCROLLDU:-0}" --img-gray "${KFB_IMG:-0}" \
        --anim-mode "${KFB_ANIM_MODE:-1}" --anim-dir "${KFB_ANIM_DIR:-2}" \
        --anim-steps "${KFB_ANIM_STEPS:-8}" --anim-min "${KFB_ANIM_MIN:-45}" \
        --scroll-delay "${KFB_SCROLLDELAY:-500}" \
        --scroll-style "${KFB_SCROLLSTYLE:-1}" --scroll-wfm "${KFB_SCROLLWFM:-a2}" \
        --gcn "${KFB_GCN:-0}" \
        --eclipse "${KFB_ECLIPSE:-1}" --dark-crush "${KFB_DARKCRUSH:-36}" --heavy-flash "${KFB_HEAVY_FLASH:-1}" \
        --nice "${KFB_EPD_NICE:--8}" $(rot_args) >>"$W/epd.log" 2>&1 &
    echo $! > "$W/epd.pid"
    rot_deg > "$W/rotate"
    touch "$W/rotate.live"
    usleep 500000
    t "display: bridge pid $(cat "$W/epd.pid")"
}

display_stop() {
    alive "$W/epd.pid" && kill "$(cat "$W/epd.pid")" 2>/dev/null || true
    rm -f "$W/epd.pid" "$W/rotate" "$W/rotate.live"
}

# Kobo 4.1.15 has no PID/net namespaces; always runs in mount-ns chroot + hostnet mode.
hostns() { return 0; }

root_id() { stat -L -c %d:%i "$1/." 2>/dev/null; }
chroot_root() { ip=$(cat "$W/pid" 2>/dev/null); [ -n "$ip" ] && root_id "/proc/$ip/root"; }
chroot_pids() {
    r=${1:-$(chroot_root)}
    [ "$r" = "$(root_id /)" ] && r=
    cp_devs=" "
    for cp_l in $(img_loops); do
        cp_d=$(cat "/sys/block/$cp_l/dev" 2>/dev/null)
        [ -n "$cp_d" ] && cp_devs="$cp_devs$(( ${cp_d%%:*} * 256 + ${cp_d##*:} )) "
    done
    [ -n "$r" ] || [ "$cp_devs" != " " ] || return 0
    stat -L -c '%d %i %n' /proc/[0-9]*/root 2>/dev/null | awk -v devs="$cp_devs" -v r="$r" '
        { split($3, a, "/"); if (index(devs, " " $1 " ") > 0 || (r != "" && ($1 ":" $2) == r)) print a[3] }' | sort -un
}

fstrim_defuse() {
    [ -d "$SYS/data/system" ] || return 0
    touch "$SYS/data/system/last-fstrim" 2>/dev/null && chown 1000:1000 "$SYS/data/system/last-fstrim" 2>/dev/null || true
    return 0
}

SYSFONT_REF=../../dev/vdfont/system.ttf
sysfont_host() {
    sf_n=${1##*/}
    case "$sf_n" in ''|.*|*..*) return 1 ;; esac
    case "${1%/*}" in
        /data/media/0/Fonts|/sdcard/Fonts|/storage/emulated/0/Fonts) echo "$VD/fonts/$sf_n" ;;
        /data/media/0/KindleFonts|/sdcard/KindleFonts|/storage/emulated/0/KindleFonts) echo "/usr/local/Trolltech/QtEmbedded-4.6.2-arm/lib/fonts/$sf_n" ;;
        /system/fonts) echo "$R/system/fonts/$sf_n" ;;
        *) return 1 ;;
    esac
}
sysfont_ok() {
    [ -f "$1" ] && [ -r "$1" ] || return 1
    [ "$(wc -c < "$1" 2>/dev/null || echo 0)" -ge 16384 ] || return 1
    case "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" in 00010000|4f54544f|74727565|74746366) return 0 ;; esac
    return 1
}
sysfont_prepare() {
    rm -rf "$W/sysfont"
    case "${SYSTEM_FONT:-}" in ''|default|none) rm -f "$SYS/sysfont.try"; return 0 ;; esac
    sf_src=$(sysfont_host "$SYSTEM_FONT") || return 0
    sysfont_ok "$sf_src" || return 0
    sf_xml=$R/system/etc/fonts.xml
    [ -f "$sf_xml" ] || return 0
    mkdir -p "$W/sysfont" || return 0
    awk -v ref="$SYSFONT_REF" '
        function fam(attr) { return "    <family" attr ">\n        <font weight=\"400\" style=\"normal\">" ref "</font>\n    </family>" }
        st == 0 && /<family[^>]*name="sans-serif"[ >\/]/ && !/<\/family>/ {
            st = 1; print "    <family name=\"sans-serif\">"; print "        <font weight=\"400\" style=\"normal\">" ref "</font>"; print "    </family>"
            print "    <family>"; next
        }
        st == 1 { print; if (/<\/family>/) { st = 2; print fam(" lang=\"zh-Hans\""); print fam(" lang=\"zh-Hant\""); print fam(" lang=\"ja\"") } next }
        { print }
        END { if (st != 2) exit 1 }' "$sf_xml" > "$W/sysfont/fonts.xml" 2>/dev/null || { rm -rf "$W/sysfont"; return 0; }
    chmod 644 "$W/sysfont/fonts.xml"
    printf '%s\n' "$sf_src" > "$W/sysfont/src"
    printf '%s\n' "$SYSTEM_FONT" > "$W/sysfont/android"
}
sysfont_mount() {
    [ -s "$W/sysfont/fonts.xml" ] && [ -s "$W/sysfont/src" ] || return 0
    sf_src=$(cat "$W/sysfont/src")
    mkdir -p "$R/dev/vdfont" && touch "$R/dev/vdfont/system.ttf" || return 0
    if mount --bind "$sf_src" "$R/dev/vdfont/system.ttf"; then
        mount --bind "$W/sysfont/fonts.xml" "$R/system/etc/fonts.xml" && return 0
        umount "$R/dev/vdfont/system.ttf" 2>/dev/null || true
    fi
    return 0
}

container_start() {
    # Prevent Android init.rc `mount rootfs rootfs / ro remount` from flipping the
    # shared ext4 loop superblock (/dev/loop0 holding both rootfs and /data) read-only!
    if [ -w "$R/init.rc" ] && grep -q '^[[:space:]]*mount rootfs rootfs / ro remount' "$R/init.rc" 2>/dev/null; then
        sed -i 's|^[[:space:]]*mount rootfs rootfs / ro remount|# disabled for kobo shared loop: &|' "$R/init.rc" \
            && t "container: patched init.rc (disabled ro remount of shared loop superblock)"
    fi
    # Install Bionic madvise shim and wire into init.kindle.rc LD_PRELOAD alongside libvdshim.so
    if [ -f "$VD/bin/libkobo_madvise.so" ] && [ -d "$R/system/lib" ]; then
        if ! cmp -s "$VD/bin/libkobo_madvise.so" "$R/system/lib/libkobo_madvise.so"; then
            cp "$VD/bin/libkobo_madvise.so" "$R/system/lib/libkobo_madvise.so.new" \
                && chmod 644 "$R/system/lib/libkobo_madvise.so.new" \
                && mv -f "$R/system/lib/libkobo_madvise.so.new" "$R/system/lib/libkobo_madvise.so" \
                && t "container: installed libkobo_madvise.so"
        fi
        if [ -w "$R/init.kindle.rc" ] && ! grep -q 'libkobo_madvise.so' "$R/init.kindle.rc" 2>/dev/null; then
            sed -i 's|export LD_PRELOAD /system/lib/libvdshim.so|export LD_PRELOAD /system/lib/libvdshim.so:/system/lib/libkobo_madvise.so|' "$R/init.kindle.rc" \
                && t "container: enabled libkobo_madvise.so in init.kindle.rc LD_PRELOAD"
        fi
    fi
    # Install Kobo-rebranded VeraHome.apk when staged in $VD/bin/VeraHome.apk
    if [ -f "$VD/bin/VeraHome.apk" ] && [ -d "$R/system/priv-app/VeraHome" ]; then
        if ! cmp -s "$VD/bin/VeraHome.apk" "$R/system/priv-app/VeraHome/VeraHome.apk"; then
            cp "$VD/bin/VeraHome.apk" "$R/system/priv-app/VeraHome/VeraHome.apk.new" \
                && chmod 644 "$R/system/priv-app/VeraHome/VeraHome.apk.new" \
                && mv -f "$R/system/priv-app/VeraHome/VeraHome.apk.new" "$R/system/priv-app/VeraHome/VeraHome.apk" \
                && rm -rf "$R/system/priv-app/VeraHome/oat" \
                && rm -f "$SYS/data/dalvik-cache/arm/system@priv-app@VeraHome@VeraHome.apk@classes.dex" \
                && t "container: installed Kobo VeraHome.apk (cleared stale odex)"
        fi
    fi
    # Install Wi-Fi-transport-enabled ethernet-service.jar so apps (WeRead offline book
    # download, etc.) see TYPE_WIFI + TRANSPORT_WIFI on shared hostnet wlan0
    if [ -f "$VD/bin/ethernet-service-wifi.jar" ] && [ -d "$R/system/framework" ]; then
        if ! cmp -s "$VD/bin/ethernet-service-wifi.jar" "$R/system/framework/ethernet-service.jar"; then
            cp "$VD/bin/ethernet-service-wifi.jar" "$R/system/framework/ethernet-service.jar.new" \
                && chmod 644 "$R/system/framework/ethernet-service.jar.new" \
                && mv -f "$R/system/framework/ethernet-service.jar.new" "$R/system/framework/ethernet-service.jar" \
                && rm -f "$R/system/framework/oat/arm/ethernet-service.odex" \
                && rm -f "$SYS/data/dalvik-cache/arm/system@framework@ethernet-service.jar@classes.dex" \
                && t "container: installed Wi-Fi-transport ethernet-service.jar"
        fi
    fi
    # Install WeRead-only runtime optimizer DEX (FontSizeCache + ReaderPageRelease + SegDictRelease)
    if [ -f "$VD/bin/kobo-weread-opt.jar" ] && [ -d "$R/system/framework" ]; then
        if ! cmp -s "$VD/bin/kobo-weread-opt.jar" "$R/system/framework/kobo-weread-opt.jar"; then
            cp "$VD/bin/kobo-weread-opt.jar" "$R/system/framework/kobo-weread-opt.jar.new" \
                && chmod 644 "$R/system/framework/kobo-weread-opt.jar.new" \
                && mv -f "$R/system/framework/kobo-weread-opt.jar.new" "$R/system/framework/kobo-weread-opt.jar" \
                && t "container: installed kobo-weread-opt.jar"
        fi
    fi
    sysfont_prepare
    type skia_opt_sync >/dev/null 2>&1 && skia_opt_sync
    fstrim_defuse
    # Purge any cached WeRead self-update metadata (KVAppUpdate/KVAppUpdateFile), downloaded update APKs,
    # and queued telemetry/crash upload spools (BusReport / Bugly uploads / oversized bugly_db_).
    rm -rf "$SYS"/data/data/com.tencent.weread.eink/databases/*/kv/KVAppUpdate* \
           "$SYS"/data/data/com.tencent.weread.eink/databases/kv/KVAppUpdate* \
           "$SYS"/data/data/com.tencent.weread.eink/cache/downloader/*.apk \
           "$SYS"/data/data/com.tencent.weread.eink/files/BusReport/* \
           "$SYS"/data/data/com.tencent.weread.eink/files/bugly_upload_file/* \
           "$SYS"/data/data/com.tencent.weread.eink/files/bugly_upload_zip/* 2>/dev/null || true
    bdb="$SYS/data/data/com.tencent.weread.eink/databases/bugly_db_"
    if [ -f "$bdb" ] && [ "$(wc -c < "$bdb" 2>/dev/null || echo 0)" -gt 524288 ]; then
        rm -f "$bdb" "${bdb}-journal" "${bdb}-wal" "${bdb}-shm" 2>/dev/null || true
    fi
    # Koboweread: extract WeRead's bundled 11.3 MB SourceHanSerifCN-Medium OTF once for mmap Typeface caching
    # (avoids inflating 11 MB into un-reclaimable anonymous RAM on first book open).
    wr_font="$SYS/data/local/tmp/kobo-fonts/SourceHanSerifCN-Medium_FDK_motify_strip.otf"
    if [ ! -f "$wr_font" ] || [ "$(wc -c < "$wr_font" 2>/dev/null || echo 0)" != 11373656 ]; then
        for wr_apk in "$SYS"/data/app/com.tencent.weread.eink-*/base.apk; do
            [ -f "$wr_apk" ] || continue
            mkdir -p "$SYS/data/local/tmp/kobo-fonts" 2>/dev/null || true
            chmod 755 "$SYS/data/local/tmp" "$SYS/data/local/tmp/kobo-fonts" 2>/dev/null || true
            if unzip -p "$wr_apk" assets/fonts/SourceHanSerifCN-Medium_FDK_motify_strip.otf > "$wr_font.tmp" 2>/dev/null \
                && [ "$(wc -c < "$wr_font.tmp" 2>/dev/null || echo 0)" = 11373656 ]; then
                chmod 644 "$wr_font.tmp" && mv -f "$wr_font.tmp" "$wr_font" \
                    && t "container: extracted WeRead bundled font for mmap (11.3 MB)"
            else
                rm -f "$wr_font.tmp" 2>/dev/null || true
            fi
            break
        done
    fi
    # Koboweread: switch WeRead WRBook & WRReader SQLite databases to WAL mode offline (before Android starts)
    # so concurrent reads/writes never block main-thread queries behind rollback journal locks.
    if [ -x /mnt/onboard/.adds/koreader/luajit ] && [ -f /mnt/onboard/.adds/koreader/libs/libsqlite3.so.0 ]; then
        for wr_db in "$SYS"/data/data/com.tencent.weread.eink/databases/[0-9]*/WRBook \
                     "$SYS"/data/data/com.tencent.weread.eink/databases/[0-9]*/WRReader; do
            [ -f "$wr_db" ] || continue
            # SQLite header byte 18: 1 = legacy journal, 2 = WAL
            wr_jm=$(dd if="$wr_db" bs=1 skip=18 count=1 2>/dev/null | od -An -tu1 | tr -d ' \n')
            if [ "$wr_jm" = 2 ]; then
                # Periodic offline WAL checkpoint(TRUNCATE) + PRAGMA optimize when -wal >= 2MB or >= 7 days
                wr_name=$(basename "$wr_db")
                wr_wal_sz=$(wc -c < "${wr_db}-wal" 2>/dev/null || echo 0)
                wr_stamp="$SYS/data/local/tmp/kobo-db-maint.$wr_name.stamp"
                wr_now=$(date +%s 2>/dev/null || echo 0)
                wr_last=$(stat -c %Y "$wr_stamp" 2>/dev/null || echo 0)
                if [ "${wr_wal_sz:-0}" -ge 2097152 ] 2>/dev/null || [ $((wr_now - wr_last)) -ge 604800 ] 2>/dev/null; then
                    wr_own=$(stat -c '%u:%g' "$wr_db" 2>/dev/null || echo "10010:10010")
                    wr_mod=$(stat -c '%a' "$wr_db" 2>/dev/null || echo "600")
                    WR_DB="$wr_db" LD_LIBRARY_PATH=/mnt/onboard/.adds/koreader/libs /mnt/onboard/.adds/koreader/luajit -e '
local ffi = require("ffi")
ffi.cdef[[
typedef struct sqlite3 sqlite3;
int sqlite3_open_v2(const char *, sqlite3 **, int, const char *);
int sqlite3_exec(sqlite3 *, const char *, void *, void *, char **);
int sqlite3_busy_timeout(sqlite3 *, int); int sqlite3_close(sqlite3 *);
]]
local lib = ffi.load("/mnt/onboard/.adds/koreader/libs/libsqlite3.so.0")
local pdb = ffi.new("sqlite3 *[1]")
if lib.sqlite3_open_v2(os.getenv("WR_DB"), pdb, 2, nil) ~= 0 then os.exit(1) end
local db = pdb[0]; lib.sqlite3_busy_timeout(db, 5000)
lib.sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize;", nil, nil, nil)
lib.sqlite3_close(db)
' 2>/dev/null && {
                        chown "$wr_own" "$wr_db" "${wr_db}-wal" "${wr_db}-shm" 2>/dev/null || true
                        chmod "$wr_mod" "$wr_db" 2>/dev/null || true
                        mkdir -p "$SYS/data/local/tmp" 2>/dev/null || true
                        touch "$wr_stamp" 2>/dev/null || true
                        t "container: SQLite maint $wr_name (wal=${wr_wal_sz}B -> truncated + optimize)"
                    } || true
                fi
                continue
            fi
            wr_own=$(stat -c '%u:%g' "$wr_db" 2>/dev/null || echo "10010:10010")
            wr_mod=$(stat -c '%a' "$wr_db" 2>/dev/null || echo "600")
            wr_bk="$SYS/data/local/tmp/wal-backup/$(basename "$wr_db")"
            if [ ! -f "$wr_bk" ]; then
                mkdir -p "$SYS/data/local/tmp/wal-backup" 2>/dev/null || true
                cp "$wr_db" "$wr_bk.tmp" 2>/dev/null && mv -f "$wr_bk.tmp" "$wr_bk" || true
            fi
            wr_res=$(WR_DB="$wr_db" LD_LIBRARY_PATH=/mnt/onboard/.adds/koreader/libs /mnt/onboard/.adds/koreader/luajit -e '
local ffi = require("ffi")
ffi.cdef[[
typedef struct sqlite3 sqlite3; typedef struct sqlite3_stmt sqlite3_stmt;
int sqlite3_open_v2(const char *, sqlite3 **, int, const char *);
int sqlite3_prepare_v2(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
int sqlite3_step(sqlite3_stmt *); const unsigned char *sqlite3_column_text(sqlite3_stmt *, int);
int sqlite3_finalize(sqlite3_stmt *); int sqlite3_close(sqlite3 *);
int sqlite3_busy_timeout(sqlite3 *, int);
]]
local lib = ffi.load("/mnt/onboard/.adds/koreader/libs/libsqlite3.so.0")
local pdb = ffi.new("sqlite3 *[1]")
if lib.sqlite3_open_v2(os.getenv("WR_DB"), pdb, 2, nil) ~= 0 then os.exit(1) end
local db = pdb[0]; lib.sqlite3_busy_timeout(db, 5000)
local function one(sql)
  local st = ffi.new("sqlite3_stmt *[1]")
  if lib.sqlite3_prepare_v2(db, sql, -1, st, nil) ~= 0 then os.exit(2) end
  local rc, v = lib.sqlite3_step(st[0]), ""
  if rc == 100 then local t = lib.sqlite3_column_text(st[0], 0); v = t ~= nil and ffi.string(t) or "" end
  lib.sqlite3_finalize(st[0]); return v
end
if one("PRAGMA quick_check") ~= "ok" then lib.sqlite3_close(db); os.exit(3) end
one("PRAGMA journal_mode=wal")
local m = one("PRAGMA journal_mode")
lib.sqlite3_close(db)
io.write(m)
' 2>/dev/null || true)
            chown "$wr_own" "$wr_db" 2>/dev/null || true
            chmod "$wr_mod" "$wr_db" 2>/dev/null || true
            rm -f "${wr_db}-wal" "${wr_db}-shm" 2>/dev/null || true
            t "container: SQLite WAL $(basename "$wr_db") -> ${wr_res:-failed}"
        done
    fi
    docs_snapshot
    if [ -f "$SYS/data/system/uiderrors.txt" ]; then
        wc -l < "$SYS/data/system/uiderrors.txt" 2>/dev/null | tr -d ' ' > "$W/uiderr.lines"
    else
        echo 0 > "$W/uiderr.lines"
    fi
    freezer_setup
    setsid busybox unshare -m sh "$VD/boot/veradroid.sh" --in-chroot "$KFB_TOUCH" "$KFB_KEYS_VIRT" "$KFB_KEYS" </dev/null >>"$LOG" 2>&1 &
    P=$!
    echo "$P" > "$W/pid"
    echo chroot > "$W/mode"
    t "container started (mount-ns + hostnet): init=$P"
    return 0
}

binder_repair() {
    [ -c /dev/binder ] && chmod 666 /dev/binder 2>/dev/null
    return 0
}

run_in_ns() {
    TOUCH=$1 KEYS=$2 PTKEYS=$3
    mount --make-rprivate / 2>/dev/null || true
    mkdir -p "$R$KLIB_MP" 2>/dev/null || true
    mount --bind "$R" "$R" || exit 1
    # NOTE: Do NOT call `mount -o remount,ro,bind "$R"` with Kobo BusyBox mount:
    # BusyBox drops MS_BIND on remount and turns the entire veradroid-sys.img ext4 superblock read-only!

    mount -t tmpfs -o nosuid,mode=755 tmpfs "$R/dev" || exit 1
    for n in null zero full tty random urandom kmsg fuse; do
        [ -e "/dev/$n" ] && touch "$R/dev/$n" && mount --bind "/dev/$n" "$R/dev/$n"
    done

    # Bind Kobo's out-of-tree /dev/binder and /dev/kobo_madvise into container /dev
    if [ -c /dev/binder ]; then
        chmod 666 /dev/binder 2>/dev/null || true
        touch "$R/dev/binder"
        mount --bind /dev/binder "$R/dev/binder" || { echo "veradroid: failed to bind /dev/binder" >&2; exit 1; }
        chmod 666 "$R/dev/binder" 2>/dev/null || true
    else
        echo "veradroid: /dev/binder missing (binder_linux.ko not loaded)" >&2
        exit 1
    fi
    if [ -c /dev/kobo_madvise ]; then
        chmod 666 /dev/kobo_madvise 2>/dev/null || true
        touch "$R/dev/kobo_madvise"
        mount --bind /dev/kobo_madvise "$R/dev/kobo_madvise" || true
        chmod 666 "$R/dev/kobo_madvise" 2>/dev/null || true
    fi

    touch "$R/dev/vdchroot"
    mkdir -p "$R/dev/socket" "$R/dev/input" "$R/dev/kfb" "$R/dev/pts" "$R/dev/__properties__"
    mkdir -p "$R/dev/vdshm" && chmod 1777 "$R/dev/vdshm"

    for d in "$TOUCH" "$KEYS" "$PTKEYS"; do [ -c "$d" ] && chmod 666 "$d" 2>/dev/null || true; done
    [ -n "$TOUCH" ]  && { touch "$R/dev/input/event0"; mount --bind "$TOUCH"  "$R/dev/input/event0"; }
    [ -n "$KEYS" ]   && { touch "$R/dev/input/event1"; mount --bind "$KEYS"   "$R/dev/input/event1"; }
    [ -n "$PTKEYS" ] && { touch "$R/dev/input/event2"; mount --bind "$PTKEYS" "$R/dev/input/event2"; }

    mount --bind "$X" "$R/dev/kfb"
    [ -e /dev/fb0 ] && { touch "$R/dev/epd" "$R/dev/fb0"; mount --bind /dev/fb0 "$R/dev/epd"; mount --bind /dev/fb0 "$R/dev/fb0"; }
    mount -t devpts -o mode=620,ptmxmode=666,newinstance devpts "$R/dev/pts" && ln -s pts/ptmx "$R/dev/ptmx"

    mount -t proc proc "$R/proc" || exit 1
    [ -f "$W/cmdline" ] && mount --bind "$W/cmdline" "$R/proc/cmdline"

    mount -t sysfs -o ro sysfs "$R/sys" || exit 1
    for d in sys/fs/selinux sys/fs/bpf sys/fs/pstore sys/kernel/tracing sys/kernel/debug; do
        [ -d "$R/$d" ] && mount -t tmpfs -o ro,size=4k tmpfs "$R/$d" 2>/dev/null || true
    done

    mkdir -p "$SYS/data" && mount --bind "$SYS/data" "$R/data" && mount -o remount,bind,nosuid,nodev,noatime "$R/data" 2>/dev/null || true
    mkdir -p "$R/data/cache" "$R/data/media/0/Books" "$R/data/local/tmp"
    chmod 777 "$R/data/media" "$R/data/media/0" "$R/data/media/0/Books" "$R/data/local/tmp" 2>/dev/null || true
    upload_dir_fix 2>/dev/null || true

    # Bind Kobo Documents safely outside /data/media/0 (symlinked from KindleLibrary)
    if [ -d "$DOCS_DIR" ] && [ -d "$R$KLIB_MP" ]; then
        if klib_link "$R/data"; then
            mount --bind "$DOCS_DIR" "$R$KLIB_MP" 2>/dev/null || true
        fi
    fi

    # Bind Kobo fonts & user fonts into Android
    mkdir -p "$R/data/media/0/KindleFonts" "$R/data/media/0/Fonts"
    if [ -d /usr/local/Trolltech/QtEmbedded-4.6.2-arm/lib/fonts ]; then
        mount --bind /usr/local/Trolltech/QtEmbedded-4.6.2-arm/lib/fonts "$R/data/media/0/KindleFonts" 2>/dev/null || true
    fi
    if [ -d "$VD/fonts" ]; then
        mount --bind "$VD/fonts" "$R/data/media/0/Fonts" 2>/dev/null || true
    elif [ -d /mnt/onboard/fonts ]; then
        mount --bind /mnt/onboard/fonts "$R/data/media/0/Fonts" 2>/dev/null || true
    fi
    chmod 777 "$R/data/media/0/Fonts" 2>/dev/null || true

    sysfont_mount

    # Optional rebuilt non-debuggable boot image (tools/kobo/compile-boot-nodebug.sh):
    # bind-mount over /system/framework/arm/boot*.{art,oat} unless disabled.
    if [ -s "$SYS/data/local/tmp/boot-nodebug/boot.oat" ] && [ -s "$SYS/data/local/tmp/boot-nodebug/boot.art" ] \
        && [ ! -e "$SYS/data/local/tmp/kobo-bootnodebug-disabled" ]; then
        for bf in "$SYS"/data/local/tmp/boot-nodebug/boot*.art "$SYS"/data/local/tmp/boot-nodebug/boot*.oat; do
            [ -f "$bf" ] || continue
            bt="$R/system/framework/arm/${bf##*/}"
            [ -f "$bt" ] && mount --bind "$bf" "$bt" 2>/dev/null || true
        done
        for of in "$SYS"/data/local/tmp/boot-nodebug/*.odex; do
            [ -s "$of" ] || continue
            ot="$R/system/framework/oat/arm/${of##*/}"
            [ -f "$ot" ] && mount --bind "$of" "$ot" 2>/dev/null || true
        done
    fi

    # Kobo 4.1.15 kernel lacks CONFIG_FUSE_FS (/dev/fuse); bind-mount zero-FUSE kobo-sdcard
    # over /system/bin/sdcard so vold completes EmulatedVolume::doMount() cleanly without
    # spinning forever on FUSE or stalling apps' getExternalFilesDir() for 60s timeouts.
    if [ ! -c /dev/fuse ] && [ -x "$VD/bin/kobo-sdcard" ] && [ -f "$R/system/bin/sdcard" ]; then
        mount --bind "$VD/bin/kobo-sdcard" "$R/system/bin/sdcard" 2>/dev/null || true
    fi

    umount -l "$R/storage/emulated" 2>/dev/null || true
    mkdir -p "$R/storage/emulated/0"
    mount --bind "$R/data/media/0" "$R/storage/emulated/0"

    vd_art_stack "$R/system/build.prop"
    exec "$VD/bin/pivot_init" "$R" mnt /init --second-stage
}
