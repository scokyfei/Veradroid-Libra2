#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# VeraDroid main launcher for Kobo Libra 2.
# Usage: sh veradroid.sh [home | <pkg> | stop | status]
{
case "$1" in --in-ns|--in-chroot) ;; *)
for n in $(ls /proc/$$/fd 2>/dev/null); do
    case "$n" in 0|1|2|*[!0-9]*) ;; *) eval "exec $n>&-" ;; esac
done ;;
esac

umask 022
VD=${VD:-$(cd "$(dirname "$0")/.." && pwd)}
export VD
. "$VD/boot/lib/common.sh"

case "$1" in
    stop)   exec sh "$VD/boot/stop.sh" ;;
    status)
        p=$(cat "$W/pid" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            echo "running pid=$p"
            exit 0
        else
            echo "stopped"
            exit 1
        fi ;;
esac

for m in settings memory slim freeze kmod framework container input network sleep status cmd watchdog afterboot splash bootwatch diagboot compile energy tz bgnice saver lock storage webadmin progress; do
    [ -f "$VD/boot/lib/$m.sh" ] && . "$VD/boot/lib/$m.sh"
done

mkdir -p "$SYS" "$W" "$VD/logs"
if ! { [ -f "$W/frozen" ] && kill -0 "$(cat "$W/pid" 2>/dev/null)" 2>/dev/null; }; then
    rm -f "$SYS/settings.app" "$W/appprof.pkg"
fi
settings_load

if [ "$1" = "--in-chroot" ]; then HOSTNS=1 run_in_ns "$2" "$3" "$4"; exit 1; fi

[ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && {
    tail -c 524288 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
}
exec >>"$LOG" 2>&1

if [ -z "${VERADROID_DETACHED:-}" ]; then
    echo 0 > /proc/$$/oom_score_adj 2>/dev/null || true
    exec env -i VERADROID_DETACHED=1 VD="$VD" PATH="$PATH" setsid sh "$0" "$@" </dev/null
fi

echo "== $(date) start (Kobo Libra 2) app=${1:-$SYSTEM_APP}"
APP=${1:-$SYSTEM_APP}
open_app() { echo "$APP" > "$X/ctl/app.tmp" && mv -f "$X/ctl/app.tmp" "$X/ctl/app"; t "open: $APP"; }

start_helpers() {
    kill "$(cat "$W/cmd.pid" 2>/dev/null)" "$(cat "$W/guard.pid" 2>/dev/null)" 2>/dev/null || true
    watchdog &
    echo $! > "$W/watchdog.pid"
    wd_guard &
    echo $! > "$W/guard.pid"
    sleep_watch &
    echo $! > "$W/sleep.pid"
    cmd_listen &
    echo $! > "$W/cmd.pid"
    host_oom_protect
}

P=$(cat "$W/pid" 2>/dev/null)
if [ -n "$P" ] && kill -0 "$P" 2>/dev/null; then
    if [ ! -f "$W/frozen" ] && ! framework_paused && [ ! -d "$W/starting" ]; then
        t "inconsistent state (android running without paused kobo ui), restarting cleanly"
        sh "$VD/boot/stop.sh" >/dev/null 2>&1
        storage_mount
    else
        open_app
        exit 0
    fi
fi

if ! mkdir "$W/starting" 2>/dev/null; then
    op=$(cat "$W/starting/pid" 2>/dev/null)
    if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then
        t "already starting (pid $op), ignored"
        exit 0
    fi
    t "stale start lock (pid ${op:-?}), taking over"
fi
echo $$ > "$W/starting/pid"
trap 'rm -f "$W/starting/pid"; rmdir "$W/starting" 2>/dev/null' EXIT

sp=$(cat /tmp/veradroid-stop.pid 2>/dev/null); i=0
while [ -n "$sp" ] && [ "$sp" != "$$" ] && [ "$sp" != "$PPID" ] && kill -0 "$sp" 2>/dev/null; do
    i=$((i + 1)); [ $i -gt 60 ] && break
    sleep 1
done

sh "$VD/boot/stop.sh" --stale >/dev/null 2>&1 || true
rm -f "$SYS/settings.app" "$W/appprof.pkg"

storage_mount || { t "storage_mount failed"; splash "VeraDroid：系统镜像挂载失败" 36; sleep 4; exit 1; }
kmod_load     || { t "kmod_load failed"; splash "VeraDroid：内核模块加载失败" 36; sleep 4; exit 1; }
[ -d "$R" ] && [ -e "$R/init" ] || { t "no Android rootfs at $R"; splash "VeraDroid：未找到 Android 系统镜像" 36; sleep 4; exit 1; }

FRAMEWORK_AFTER_SAVE='splash_begin 正在准备 3'
framework_stop || { t "cannot pause kobo ui"; exit 1; }
splash_update 12

display_prepare
touch "$X/ctl/sleep"
rm -f "$W/epd.restarts" "$W/input.restarts"
display_start || { t "display_start failed"; sh "$VD/boot/stop.sh" >/dev/null 2>&1; exit 1; }
settings_publish
type appprof_publish >/dev/null 2>&1 && appprof_publish
type appprof_density_boot >/dev/null 2>&1 && appprof_density_boot

touch_setup
input_start || { t "no usable touch screen: stopping"; sh "$VD/boot/stop.sh" >/dev/null 2>&1; exit 1; }

echo "androidboot.hardware=kindle androidboot.zygote=zygote32 androidboot.vdhostnet=1" > "$W/cmdline"

# Sync Kobo timezone into Android persist.sys.timezone (init requires 0600 on persist.* files)
tz_k=$(kobo_tz)
if [ -n "$tz_k" ] && [ -d "$SYS/data" ]; then
    mkdir -p "$SYS/data/property"
    chmod 700 "$SYS/data/property" 2>/dev/null || true
    printf '%s' "$tz_k" > "$SYS/data/property/persist.sys.timezone"
    chmod 600 "$SYS/data/property/persist.sys.timezone" 2>/dev/null || true
    echo "$tz_k" > "$W/tz.android"
    t "tz: synced Kobo timezone -> $tz_k"
fi

zram_on
slim_apply
readahead_on
net_setup
container_start || { sh "$VD/boot/stop.sh" >/dev/null 2>&1; exit 1; }
bat_baseline
net_start
echo "$APP" > "$X/ctl/app"
splash_update 20
dedup_start

boot_watch &
echo $! > "$W/boot.pid"
start_helpers
[ -f "$VD/debugboot" ] && { diagboot & echo $! > "$W/diagboot.pid"; }
after_boot &
echo $! > "$W/afterboot.pid"

t "started (Kobo Libra 2)"
exit 0
}
