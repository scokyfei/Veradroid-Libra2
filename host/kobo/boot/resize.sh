#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline system image resize helper for Kobo Libra 2.
# Usage: sh resize.sh <MB>
{
VD=${VD:-$(cd "$(dirname "$0")/.." && pwd)}
cd /
. "$VD/boot/lib/common.sh"
. "$VD/boot/lib/storage.sh"
[ -f "$VD/boot/lib/splash.sh" ] && . "$VD/boot/lib/splash.sh"
mkdir -p "$VD/logs" "$VD/state" 2>/dev/null || true
exec >> "$ST_LOG" 2>&1 </dev/null

TO=$1
[ -f "$SYSTEM_IMG" ] || { echo "no system image"; exit 2; }
st_num "$TO" || { echo "usage: resize.sh <MB>"; exit 2; }
tail -n 400 "$ST_LOG" > "$ST_LOG.tmp" 2>/dev/null && cat "$ST_LOG.tmp" > "$ST_LOG"; rm -f "$ST_LOG.tmp"
st_lock $$ || { st_log "another resize is running"; exit 3; }
ST_OWNER=$$; export ST_OWNER
trap 'st_unlock' EXIT

st_calc
FROM=$ST_IMG
e=$(st_check "$TO")
[ -z "$e" ] || { st_last refused resize "$FROM" "$TO" "$e"; exit 4; }
[ "$TO" -gt "$FROM" ] && OP=grow || OP=shrink
RES=$(st_tool resize2fs) || { st_last failed $OP "$FROM" "$TO" notool; exit 5; }
WAS=; P=$(cat "$W/pid" 2>/dev/null); [ -n "$P" ] && kill -0 "$P" 2>/dev/null && WAS=1
st_log "offline $OP $FROM -> $TO MB (android ${WAS:+running}${WAS:-stopped})"
show() { [ -n "$WAS" ] && splash "$1" 36; st_log "step: $1"; }
st_state $OP "$FROM" "$TO" check

RDONE=$W/resize.$$.done
rm -f $W/resize.*.done 2>/dev/null

restart_after() {
    rm -f "$W/restarting"
    sh "$VD/boot/veradroid.sh" home </dev/null >/dev/null 2>&1
    i=0; while [ $i -lt 60 ]; do
        sleep 2; i=$((i + 1))
        P=$(cat "$W/pid" 2>/dev/null); [ -n "$P" ] && kill -0 "$P" 2>/dev/null && return 0
        [ $i -lt 10 ] || break
    done
    st_log "android did not start after resize: restoring Kobo UI"
    sh "$VD/boot/stop.sh" >/dev/null 2>&1
}

if [ -n "$WAS" ]; then
    me=$$
    ( trap '' HUP INT TERM
      while kill -0 $me 2>/dev/null; do sleep 2; done
      [ -f "$RDONE" ] && { rm -f "$RDONE"; exit 0; }
      st_log "resize.sh ended unexpectedly: recovering"
      i=0; while pgrep -f "$SYSTEM_IMG" >/dev/null 2>&1 && [ $i -lt 900 ]; do sleep 2; i=$((i + 1)); done
      st_unlock
      restart_after ) </dev/null >/dev/null 2>&1 &
    [ -f "$W/frozen" ] || touch "$X/ctl/sleep" 2>/dev/null
    splash "正在调整存储空间（1/4）：关闭 Android…" 36
    touch "$W/restarting"
    sh "$VD/boot/stop.sh" >/dev/null 2>&1
else
    storage_umount
fi
sync

i=0
while st_mounted || [ -n "$(img_loops)" ]; do
    storage_umount
    for l in $(img_loops); do losetup -d "$(loop_dev "$l")" 2>/dev/null; done
    i=$((i + 1)); [ $i -ge 25 ] && break
    usleep 200000
done

finish() {
    rm -f "$ST_STATE"
    st_last "$1" $OP "$FROM" "$(st_img_mb)" "$2"
    st_notify_last
    st_unlock; trap - EXIT; unset ST_OWNER
    touch "$RDONE"
    if [ -n "$WAS" ]; then
        case "$1" in ok) splash "存储空间已调整为 $(st_img_mb) MB，正在启动…" 36 ;; *) splash "存储空间未变更，正在启动…" 36 ;; esac
        restart_after
    fi
    exit 0
}

if st_mounted || [ -n "$(img_loops)" ]; then st_log "image still busy"; finish failed busy; fi
show "正在调整存储空间（2/4）：检查文件系统… 请勿关机"
st_fsck || finish failed fsck
if [ $OP = grow ]; then
    st_state grow "$FROM" "$TO" extend
    show "正在调整存储空间（3/4）：扩大到 $TO MB… 请勿关机"
    if ! st_extend "$TO"; then st_cut "$FROM"; finish failed extend; fi
    sync
    st_state grow "$FROM" "$TO" resize
    if ! "$RES" "$SYSTEM_IMG"; then st_fsck; finish failed resize2fs; fi
else
    pm=$("$RES" -P "$SYSTEM_IMG" 2>/dev/null | sed -n 's/.*: *\([0-9][0-9]*\) *$/\1/p' | tail -1)
    l=$(st_sb 24)
    if st_num "$pm"; then
        pmb=$(awk -v b="$pm" -v l="${l:-2}" 'BEGIN { printf "%d", b * (2 ^ l) / 1024 + 1 }')
        st_log "resize2fs -P: minimum $pmb MB"
        [ $((pmb + 64)) -le "$TO" ] || finish refused small
    fi
    st_state shrink "$FROM" "$TO" resize
    show "正在调整存储空间（3/4）：缩小到 $TO MB… 请勿关机"
    if ! "$RES" "$SYSTEM_IMG" "${TO}M"; then st_fsck; finish failed resize2fs; fi
    sync
    st_state shrink "$FROM" "$TO" truncate
    st_cut "$TO" || finish failed truncate
fi
sync
show "正在调整存储空间（4/4）：再次检查… 请勿关机"
st_fsck || finish failed fsck-after
sync
finish ok offline
}
