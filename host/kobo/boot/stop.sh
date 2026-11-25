#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Cleanly stop VeraDroid on Kobo Libra 2, unmount system image, and resume KOReader/Nickel.

VD=${VD:-$(cd "$(dirname "$0")/.." && pwd)}
export VD
. "$VD/boot/lib/common.sh"
for m in settings memory freeze framework container input network; do
    [ -f "$VD/boot/lib/$m.sh" ] && . "$VD/boot/lib/$m.sh"
done

STALE=; [ "$1" = "--stale" ] && STALE=1
RS=; [ -f "$W/restarting" ] && RS=1
[ -n "$STALE" ] || echo "[$(date +%H:%M:%S)] stop.sh called (parent $PPID)" >> "$LOG"

# Collect full ancestor PID chain up to PID 1 so stop.sh never kills its own caller/grandparent mid-stop.
ANCESTORS=" $$ $PPID "
_ap=$PPID
_d=0
while [ -n "$_ap" ] && [ "$_ap" -gt 1 ] && [ $_d -lt 16 ]; do
    _stat=$(cat "/proc/$_ap/stat" 2>/dev/null) || break
    _pp=$(printf '%s\n' "${_stat##*) }" | awk '{print $2}')
    case "$_pp" in ''|*[!0-9]*) break ;; esac
    [ "$_pp" -le 1 ] && break
    case "$ANCESTORS" in *" $_pp "*) break ;; esac
    ANCESTORS="$ANCESTORS$_pp "
    _ap=$_pp
    _d=$((_d + 1))
done
is_ancestor() { case "$ANCESTORS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

if [ -z "$STALE" ]; then
    echo $$ > /tmp/veradroid-stop.pid
    trap 'rm -f /tmp/veradroid-stop.pid' EXIT
    sp=$(cat "$W/starting/pid" 2>/dev/null)
    if [ -n "$sp" ] && ! is_ancestor "$sp" && kill -0 "$sp" 2>/dev/null; then
        kill "$sp" 2>/dev/null || true
        usleep 300000
        kill -9 "$sp" 2>/dev/null || true
        rm -f "$W/starting/pid"; rmdir "$W/starting" 2>/dev/null || true
    fi
fi

android_thaw 2>/dev/null || true

ps=
for f in watchdog guard sleep cmd boot afterboot compile diagboot; do
    p=$(cat "$W/$f.pid" 2>/dev/null)
    [ -n "$p" ] || continue
    is_ancestor "$p" && continue
    for c in $(pgrep -P "$p" 2>/dev/null); do
        is_ancestor "$c" && continue
        kill "$c" 2>/dev/null && ps="$ps $c"
    done
    kill "$p" 2>/dev/null && ps="$ps $p"
done
: > "$W/compile.quit" 2>/dev/null || true
p=$(cat "$W/compile.guard" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null && ps="$ps $p"
i=0
while [ -n "$ps" ] && [ $i -lt 10 ]; do
    a=; for p in $ps; do kill -0 "$p" 2>/dev/null && a=1; done
    [ -n "$a" ] || break
    usleep 100000; i=$((i + 1))
done
for p in $ps; do kill -9 "$p" 2>/dev/null || true; done
for f in watchdog guard sleep cmd boot afterboot compile diagboot; do rm -f "$W/$f.pid"; done
rm -rf "$W/compile.quit" "$W/compile.guard" "$W/compile.lock" "$W/compile.queue" "$W/booted" "$W/pkglist.stamp" "$W/wifi.rx" "$W/wifi.busy"

croot=$(chroot_root)
input_stop
display_stop

# Restore frontlight if stopped while sleeping
if [ -f "$W/sleep.fl" ]; then
    kobo_light_set "$(cat "$W/sleep.fl" 2>/dev/null)" || true
    rm -f "$W/sleep.fl"
fi

rm -f "$W/fwd.id" "$W/epd.log" "$W/pid" "$W/frozen" "$W/saver_frozen" "$W/saver_nofreeze" "$W/sleeping" "$W/fl.dimmed" "$W/resolv.conf" "$W/input.log" "$W/input.err" "$W/power.fifo"

# Kill all Android container processes sharing the rootfs mount
i=0
while [ $i -lt 20 ]; do
    cp=$(chroot_pids "$croot"); [ -n "$cp" ] || break
    kill -CONT $cp 2>/dev/null || true
    kill -9 $cp 2>/dev/null || true
    usleep 200000; i=$((i + 1))
done
[ -n "$(chroot_pids "$croot")" ] && t "stop: remaining container pids: $(chroot_pids "$croot" | tr '\n' ' ')"

awk -v r="$R/" 'index($2, r) == 1 { print length($2), $2 }' /proc/mounts | sort -rn | while read -r _ m; do
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
done
awk -v d="$SYS" 'index($2, d "/") == 1 {print length($2), $2}' /proc/mounts | sort -rn | while read _ m; do
    umount -l "$m" 2>/dev/null || true
done
while grep -q " $R " /proc/mounts; do umount -l "$R" || break; done
rm -f "$W/mode"

freezer_cleanup
[ -f "$VD/boot/lib/appprof.sh" ] && . "$VD/boot/lib/appprof.sh" && appprof_density_scrub >> "$LOG" 2>&1 || true

if [ -n "$STALE" ]; then
    rm -rf "$W/kfb"
    storage_umount
    exit 0
fi

readahead_restore 2>/dev/null || true
dedup_stop 2>/dev/null || true
zram_restore 2>/dev/null || true
wifi_ps_restore 2>/dev/null || true
rm -f "$W/cmdline"

if [ -n "$RS" ]; then
    rm -f "$W/restarting"
else
    framework_start
fi

rm -rf "$W/kfb"
sys_holders_kill
storage_umount
[ -z "$RS" ] && userstore_check stop || true
echo stopped
