# SPDX-License-Identifier: GPL-3.0-or-later
# System image storage inspection & resize manager for Kobo Libra 2 (/mnt/onboard/.adds/veradroid-libra2/veradroid-sys.img).
# Always uses offline resize on Kobo Linux 4.1.15 (online resize2fs on 4.1.15 ext4 loops can hang).

ST_STATE=$VD/state/resize.state
ST_PENDING=$VD/state/resize.pending
ST_LAST=$VD/state/resize.last
ST_NOTIFY=$VD/state/resize.notify
ST_LOG=$VD/logs/resize.log
ST_LOCK=$W/resize.lock
ST_KEEP=256
ST_LOW=200
ST_STEP=512
ST_FATCAP=4095
ST_HARDMAX=32768
ST_MINIMUM=768

st_log() { mkdir -p "$VD/logs" 2>/dev/null || true; echo "[$(date '+%F %T')] $*" >> "$ST_LOG" 2>/dev/null; type t >/dev/null 2>&1 && t "storage: $*" >&2; return 0; }

st_tool() {
    command -v "$1" 2>/dev/null && return 0
    [ -x "$VD/bin/$1" ] && { echo "$VD/bin/$1"; return 0; }
    return 1
}

st_num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ ${#1} -le 6 ]; }
st_img_mb() { stat -c %s "$SYSTEM_IMG" 2>/dev/null | awk '{ printf "%d", $1 / 1048576 }'; }
st_img_kb() { stat -c %s "$SYSTEM_IMG" 2>/dev/null | awk '{ printf "%d", $1 / 1024 }'; }
st_alloc_mb() { du -k "$SYSTEM_IMG" 2>/dev/null | awk '{ printf "%d", $1 / 1024 }'; }
st_kfs() { awk '$2 == "/mnt/onboard" { print $3; exit }' /proc/mounts 2>/dev/null; }
st_isfat() { case "$(st_kfs)" in vfat|msdos|fat) return 0 ;; esac; return 1; }
st_mounted() { grep -q " $SYS " /proc/mounts; }

st_sb() { dd if="$SYSTEM_IMG" bs=1 skip=$((1024 + $1)) count=4 2>/dev/null | od -An -tu4 2>/dev/null | tr -d ' \n'; }
st_fs_kb() {
    magic=$(dd if="$SYSTEM_IMG" bs=1 skip=1080 count=2 2>/dev/null | od -An -tu2 2>/dev/null | tr -d ' \n')
    [ "$magic" = 61267 ] || return 1
    b=$(st_sb 4); l=$(st_sb 24)
    st_num "$b" || [ ${#b} -le 10 ] || return 1
    case "$l" in 0|1|2|3|4|5|6) ;; *) return 1 ;; esac
    awk -v b="$b" -v l="$l" 'BEGIN { printf "%d", b * (2 ^ l) }'
}
st_fstype() { awk -v m="$SYS" '$2 == m { print $3 }' /proc/mounts | tail -1; }

st_battery_ok() {
    kobo_is_charging && return 0
    b=$(kobo_battery 2>/dev/null)
    st_num "$b" || return 0
    [ "$b" -ge 15 ]
}

st_auto_on() { ! grep -q '^STORAGE_AUTO=0' "$SYS/settings.conf" 2>/dev/null; }

# On Kobo Linux 4.1.15 always use safe offline resize (unmounted e2fsck + resize2fs).
st_online_ok() { return 1; }

st_calc() {
    ST_IMG=$(st_img_mb); ST_ALLOC=$(st_alloc_mb)
    set -- $(df -kP /mnt/onboard 2>/dev/null | awk 'NR == 2 { printf "%d %d", $2 / 1024, $4 / 1024 }')
    ST_KTOTAL=${1:-0}; ST_KFREE=${2:-0}
    if st_mounted; then
        set -- $(df -kP "$SYS" 2>/dev/null | awk 'NR == 2 { printf "%d %d %d", $2 / 1024, $3 / 1024, $4 / 1024 }')
        ST_FS_TOTAL=${1:-0}; ST_FS_USED=${2:-0}; ST_FS_FREE=${3:-0}
    else
        ST_FS_TOTAL=$(( $(st_fs_kb || echo 0) / 1024 ))
        fb=$(st_sb 12); l=$(st_sb 24)
        ST_FS_FREE=$(awk -v b="${fb:-0}" -v l="${l:-2}" 'BEGIN { printf "%d", b * (2 ^ l) / 1024 }')
        ST_FS_USED=$((ST_FS_TOTAL - ST_FS_FREE)); [ $ST_FS_USED -ge 0 ] || ST_FS_USED=0
    fi
    ST_MIN=$(( (ST_FS_USED * 103 / 100 + 128 + 200 + 63) / 64 * 64 ))
    [ $ST_MIN -ge $ST_MINIMUM ] || ST_MIN=$ST_MINIMUM
    [ $ST_MIN -le $ST_IMG ] || ST_MIN=$ST_IMG
    ST_MAX=$((ST_ALLOC + ST_KFREE - ST_KEEP)); ST_CAP=space
    if st_isfat && [ $ST_MAX -ge $ST_FATCAP ]; then ST_MAX=$ST_FATCAP; ST_CAP=fat; fi
    [ $ST_MAX -le $ST_HARDMAX ] || { ST_MAX=$ST_HARDMAX; ST_CAP=hard; }
    [ $ST_MAX -ge $ST_IMG ] || ST_MAX=$ST_IMG
}

# Note: keep st.kindle_total / st.kindle_free keys for VeraHome StorageActivity & web.html compatibility.
st_info() {
    if [ ! -f "$SYSTEM_IMG" ]; then
        echo "st.mode=shared"
        df -kP /mnt/onboard 2>/dev/null | awk 'NR == 2 { printf "st.kindle_total=%d\nst.kindle_used=%d\nst.kindle_free=%d\n", $2 / 1024, $3 / 1024, $4 / 1024 }'
        echo "st.kfs=$(st_kfs | tr -cd 'a-z0-9/')"
        return 0
    fi
    st_calc
    echo "st.mode=image"
    echo "st.image=$ST_IMG"; echo "st.alloc=$ST_ALLOC"
    echo "st.total=$ST_FS_TOTAL"; echo "st.used=$ST_FS_USED"; echo "st.free=$ST_FS_FREE"
    echo "st.kindle_total=$ST_KTOTAL"; echo "st.kindle_free=$ST_KFREE"
    echo "st.min=$ST_MIN"; echo "st.max=$ST_MAX"; echo "st.cap=$ST_CAP"; echo "st.keep=$ST_KEEP"
    echo "st.kfs=$(st_kfs | tr -cd 'a-z0-9/')"; echo "st.fs=$(st_fstype | tr -cd 'a-z0-9')"
    st_online_ok && echo "st.online=1" || echo "st.online=0"
    st_auto_on && echo "st.auto=1" || echo "st.auto=0"
    [ -d "$ST_LOCK" ] && echo "st.busy=1" || echo "st.busy=0"
    [ -f "$ST_PENDING" ] && echo "st.pending=$(head -c 8 "$ST_PENDING" | tr -cd '0-9')"
    [ -f "$ST_LAST" ] && sed -n 's/^\(time\|op\|from\|to\|result\|reason\)=\([A-Za-z0-9 :._-]*\)$/st.last.\1=\2/p' "$ST_LAST"
    return 0
}

st_last() {
    mkdir -p "$VD/state" 2>/dev/null || true
    { echo "time=$(date '+%F %T')"; echo "result=$1"; echo "op=$2"; echo "from=$3"; echo "to=$4"; echo "reason=$5"; } > "$ST_LAST.tmp" 2>/dev/null && mv -f "$ST_LAST.tmp" "$ST_LAST"
    st_log "result: $1 $2 $3 -> $4 $5"
}

st_notify() { mkdir -p "$VD/state" 2>/dev/null || true; echo "$*" > "$ST_NOTIFY.tmp" 2>/dev/null && mv -f "$ST_NOTIFY.tmp" "$ST_NOTIFY"; st_notify_flush; }
st_notify_last() { st_notify "result $(sed -n 's/^result=//p' "$ST_LAST" | tr -cd 'a-z') $(sed -n 's/^op=//p' "$ST_LAST" | tr -cd 'a-z') $(sed -n 's/^from=//p' "$ST_LAST" | tr -cd '0-9') $(sed -n 's/^to=//p' "$ST_LAST" | tr -cd '0-9')"; }

st_notify_flush() {
    [ -f "$ST_NOTIFY" ] && [ -d "$X/ctl" ] && [ -f "$W/booted" ] || return 0
    cp "$ST_NOTIFY" "$X/ctl/storage.notice.tmp" 2>/dev/null && chmod 644 "$X/ctl/storage.notice.tmp" && mv -f "$X/ctl/storage.notice.tmp" "$X/ctl/storage.notice" && rm -f "$ST_NOTIFY"
}

st_check() {
    st_num "$1" || { echo nan; return 1; }
    d=$(($1 - ST_IMG)); [ $d -lt 0 ] && d=$((-d))
    [ $d -ge 16 ] || { echo same; return 1; }
    if [ "$1" -lt "$ST_IMG" ]; then
        [ "$1" -ge "$ST_MIN" ] || { echo small; return 1; }
        return 0
    fi
    if st_isfat && [ "$1" -gt $ST_FATCAP ]; then echo fatlimit; return 1; fi
    [ "$1" -le $ST_HARDMAX ] || { echo toobig; return 1; }
    [ "$1" -le "$ST_MAX" ] || { echo nospace; return 1; }
    return 0
}

st_extend() {
    cur=$(st_img_mb); [ "$1" -gt "$cur" ] || return 0
    dd if=/dev/zero of="$SYSTEM_IMG" bs=1M seek=$cur count=$(($1 - cur)) conv=notrunc 2>/dev/null
    [ "$(st_img_mb)" = "$1" ]
}

st_cut() {
    fk=$(st_fs_kb) || return 1
    [ -n "$fk" ] && [ "$fk" -le $(($1 * 1024)) ] || { st_log "cut to $1 MB refused: filesystem is $fk KB"; return 1; }
    [ "$(st_img_mb)" -gt "$1" ] || return 0
    truncate -s "${1}M" "$SYSTEM_IMG" 2>/dev/null || dd if=/dev/null of="$SYSTEM_IMG" bs=1M seek=$1 2>/dev/null
    [ "$(st_img_mb)" = "$1" ]
}

st_fsck() {
    f=$(st_tool e2fsck) || { st_log "no e2fsck"; return 9; }
    "$f" -f -y "$SYSTEM_IMG" >> "$ST_LOG" 2>&1; rc=$?
    if [ $rc -ge 4 ]; then echo "-- e2fsck -f -y rc=$rc, once more" >> "$ST_LOG"; "$f" -f -y "$SYSTEM_IMG" >> "$ST_LOG" 2>&1; rc=$?; fi
    echo "-- $(date '+%F %T') e2fsck -f -y rc=$rc" >> "$ST_LOG"
    [ $rc -lt 4 ]
}

st_state() { mkdir -p "$VD/state" 2>/dev/null || true; printf 'op=%s\nfrom=%s\nto=%s\nphase=%s\n' "$1" "$2" "$3" "$4" > "$ST_STATE.tmp" && mv -f "$ST_STATE.tmp" "$ST_STATE" && sync; }
st_lock() {
    mkdir -p "${ST_LOCK%/*}" 2>/dev/null
    if ! mkdir "$ST_LOCK" 2>/dev/null; then
        op=$(cat "$ST_LOCK/pid" 2>/dev/null)
        [ -n "$op" ] && kill -0 "$op" 2>/dev/null && return 1
    fi
    _spid=
    [ -r /proc/self/stat ] && read -r _spid _ < /proc/self/stat 2>/dev/null || true
    echo "${1:-${_spid:-$$}}" > "$ST_LOCK/pid"
}
st_unlock() { rm -f "$ST_LOCK/pid"; rmdir "$ST_LOCK" 2>/dev/null; return 0; }
st_locked_by_other() {
    [ -d "$ST_LOCK" ] || return 1
    op=$(cat "$ST_LOCK/pid" 2>/dev/null)
    [ "$op" = "${ST_OWNER:-}" ] && return 1
    [ -n "$op" ] && kill -0 "$op" 2>/dev/null && return 0
    st_unlock; return 1
}

st_needs_fill() {
    fk=$(st_fs_kb) || return 1
    ik=$(st_img_kb); [ -n "$ik" ] && [ $((ik - fk)) -gt 8192 ]
}
st_fill() {
    r=$(st_tool resize2fs) || return 1
    "$r" "$SYSTEM_IMG" >> "$ST_LOG" 2>&1
}

st_recover() {
    [ -f "$SYSTEM_IMG" ] || return 0
    st_locked_by_other && return 1
    mkdir -p "$VD/state" "$VD/logs" 2>/dev/null
    [ -f "$ST_STATE" ] || [ -f "$ST_PENDING" ] || return 0
    [ -n "${ST_OWNER:-}" ] && return 0
    if [ -f "$ST_STATE" ]; then
        op=$(sed -n 's/^op=//p' "$ST_STATE" | tr -cd 'a-z'); from=$(sed -n 's/^from=//p' "$ST_STATE" | tr -cd '0-9')
        to=$(sed -n 's/^to=//p' "$ST_STATE" | tr -cd '0-9'); ph=$(sed -n 's/^phase=//p' "$ST_STATE" | tr -cd 'a-z')
        st_log "interrupted $op $from -> $to MB (phase ${ph:-?}): recovering"
        type splash >/dev/null 2>&1 && splash "VeraDroid：正在检查存储空间，请稍候…" 36
        if ! st_num "$to" || ! st_num "$from"; then
            st_fsck; rm -f "$ST_STATE"; st_last failed "${op:-resize}" "$from" "$to" badstate
        elif [ "$ph" = check ]; then
            rm -f "$ST_STATE"; st_last rolledback "$op" "$from" "$to" interrupted
        elif ! st_fsck; then
            rm -f "$ST_STATE"; st_last failed "$op" "$from" "$to" fsck
        elif [ "$op" = shrink ]; then
            fk=$(st_fs_kb)
            if [ -n "$fk" ] && [ "$fk" -le $((to * 1024)) ] && st_cut "$to" && st_fsck; then
                rm -f "$ST_STATE"; st_last ok shrink "$from" "$to" finished-after-interruption
            else
                st_needs_fill && st_fill
                rm -f "$ST_STATE"; st_last rolledback shrink "$from" "$(st_img_mb)" interrupted
            fi
        else
            if [ "$(st_img_mb)" -lt "$to" ]; then
                kf=$(df -kP /mnt/onboard 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }')
                if st_isfat && [ $((to - $(st_img_mb) + ST_KEEP)) -gt "${kf:-0}" ]; then :; else st_extend "$to"; fi
            fi
            if st_needs_fill; then st_fill; st_fsck; fi
            rm -f "$ST_STATE"; st_last ok grow "$from" "$(( $(st_fs_kb || echo 0) / 1024 ))" finished-after-interruption
        fi
        st_notify_last
    fi
    if [ -f "$ST_PENDING" ] && [ -n "${ST_START:-}" ]; then
        to=$(head -c 8 "$ST_PENDING" | tr -cd '0-9'); rm -f "$ST_PENDING"
        st_calc
        if st_num "$to" && [ "$to" -gt "$ST_IMG" ] && [ -z "$(st_check "$to")" ] && st_tool resize2fs >/dev/null; then
            from=$ST_IMG
            st_log "pending grow $from -> $to MB"
            type splash >/dev/null 2>&1 && splash "VeraDroid：正在扩大存储空间，请稍候…" 36
            st_state grow "$from" "$to" extend
            if st_fsck && st_extend "$to" && st_fill && st_fsck; then
                st_last ok grow "$from" "$to" auto; st_notify "grown $from $to"
            else
                st_cut "$from"; st_last failed grow "$from" "$to" offline
            fi
            rm -f "$ST_STATE"
        fi
    fi
    return 0
}

st_request() {
    [ -f "$SYSTEM_IMG" ] || { echo "ok=0"; echo "error=shared"; return 0; }
    st_num "$1" || { echo "ok=0"; echo "error=nan"; return 0; }
    [ -d "$ST_LOCK" ] && st_locked_by_other && { echo "ok=0"; echo "error=busy"; return 0; }
    st_tool resize2fs >/dev/null && st_tool e2fsck >/dev/null || { echo "ok=0"; echo "error=notool"; return 0; }
    st_calc
    e=$(st_check "$1")
    if [ -n "$e" ]; then
        echo "ok=0"; echo "error=$e"; echo "min=$ST_MIN"; echo "max=$ST_MAX"; echo "image=$ST_IMG"
        st_log "resize $ST_IMG -> $1 MB refused: $e"
        return 0
    fi
    from=$ST_IMG
    st_battery_ok || { echo "ok=0"; echo "error=battery"; st_log "offline resize refused: battery low"; return 0; }
    [ -f "$VD/boot/resize.sh" ] || { echo "ok=0"; echo "error=notool"; return 0; }
    ( cd / && setsid sh "$VD/boot/resize.sh" "$1" ) </dev/null >/dev/null 2>&1 &
    echo "ok=1"; echo "mode=offline"; echo "from=$from"; echo "to=$1"
}

st_auto_tick() {
    [ -f "$SYSTEM_IMG" ] || return 0
    st_notify_flush
    st_auto_on || return 0
    [ -d "$ST_LOCK" ] && return 0
    [ -f "$ST_PENDING" ] && return 0
    f=$(df -kP "$SYS" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }')
    st_num "$f" || return 0
    [ "$f" -lt $ST_LOW ] || { rm -f "$W/st.full"; return 0; }
    if [ -f "$W/st.wait" ]; then
        now=$(cut -d. -f1 /proc/uptime); [ $((now - $(cat "$W/st.wait" 2>/dev/null || echo 0))) -lt 600 ] && return 0
        rm -f "$W/st.wait"
    fi
    st_tool resize2fs >/dev/null || return 0
    st_calc
    to=$((ST_IMG + ST_STEP)); [ $to -le $ST_MAX ] || to=$ST_MAX
    if [ $((to - ST_IMG)) -lt 64 ]; then
        [ -f "$W/st.full" ] || { touch "$W/st.full"; st_log "auto: image low ($f MB free) but cannot grow"; st_notify "full $ST_CAP"; }
        return 0
    fi
    echo "$to" > "$ST_PENDING"; st_notify "pending $to"
}

st_cmd() {
    case "$1" in
    info)   st_info > "$X/ctl/storage.tmp" 2>/dev/null && chmod 644 "$X/ctl/storage.tmp" && mv -f "$X/ctl/storage.tmp" "$X/ctl/storage" ;;
    resize) rm -f "$X/ctl/storage.result"
            st_request "$2" > "$X/ctl/storage.result.tmp" 2>/dev/null; chmod 644 "$X/ctl/storage.result.tmp" 2>/dev/null
            mv -f "$X/ctl/storage.result.tmp" "$X/ctl/storage.result" 2>/dev/null
            st_cmd info ;;
    auto)   case "$2" in on|1) v=1 ;; off|0) v=0 ;; *) return 0 ;; esac
            touch "$SYS/settings.conf"
            grep -v "^STORAGE_AUTO=" "$SYS/settings.conf" > "$SYS/settings.conf.tmp" 2>/dev/null
            echo "STORAGE_AUTO=$v" >> "$SYS/settings.conf.tmp"; mv -f "$SYS/settings.conf.tmp" "$SYS/settings.conf"
            [ "$v" = 0 ] && rm -f "$ST_PENDING"
            st_log "auto grow $v"; st_cmd info ;;
    esac
}
