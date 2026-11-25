# SPDX-License-Identifier: GPL-3.0-or-later
# Common definitions for VeraDroid on Kobo Libra 2.
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH; export PATH

VD=${VD:-/mnt/onboard/.adds/Veradroid-Libra2}
SYS=${SYS:-$VD/sys}
SYSTEM_IMG=${SYSTEM_IMG:-$VD/veradroid-sys.img}
W=/tmp/veradroid
R=$SYS/rootfs
X=$W/kfb
FZ=$W/freezer/vd
LOG=$VD/logs/veradroid.log
FB=/sys/class/graphics/fb0
DOCS_DIR=/mnt/onboard/Documents
KLIB_MP=/kindle_library

[ -f "$VD/boot/lib/kobo.sh" ] && . "$VD/boot/lib/kobo.sh"

# ART virtual address layout: legacy 0.8.7+ images set ro.vd.artbase=0x30000000.
vd_art_stack() {
    case "$(uname -r)" in 3.*|4.1.*) ;; *) return 0 ;; esac
    if grep -q '^ro.vd.artbase=' "${1:-$R/system/build.prop}" 2>/dev/null; then
        ulimit -s 8192 2>/dev/null
    else
        ulimit -s unlimited 2>/dev/null
    fi
}
vd_art_stack

LOOPOPT=rw,noatime
loop_mount() { # img dir
    mount -t ext4 -o loop,$LOOPOPT "$1" "$2" 2>/dev/null && return 0
    for d in /dev/loop[0-9]* /dev/loop/[0-9]*; do
        [ -b "$d" ] || continue
        losetup "$d" >/dev/null 2>&1 && continue
        losetup "$d" "$1" 2>/dev/null || continue
        { mount -t ext4 -o $LOOPOPT "$d" "$2" 2>/dev/null || mount -t ext2 -o $LOOPOPT "$d" "$2" 2>/dev/null; } && return 0
        losetup -d "$d" 2>/dev/null
    done
    return 1
}

img_loops() {
    base=${SYSTEM_IMG##*/}
    for b in /sys/block/loop*/loop/backing_file; do
        case "$(cat "$b" 2>/dev/null)" in *"$base") d=${b%/loop/backing_file}; echo "${d##*/}" ;; esac
    done
}

loop_dev() {
    n=${1#loop}
    [ -b /dev/loop$n ] && echo /dev/loop$n || echo /dev/loop/$n
}

e2fsck_bin() {
    for b in "$VD/bin/e2fsck" /sbin/e2fsck /usr/sbin/e2fsck; do
        [ -x "$b" ] && { echo "$b"; return 0; }
    done
    return 1
}

storage_mount() {
    [ -f "$SYSTEM_IMG" ] || return 0
    if grep -q " $SYS " /proc/mounts; then return 0; fi
    mkdir -p "$SYS" "$VD/logs" 2>/dev/null || true
    i=0
    while [ -n "$(img_loops)" ]; do
        for l in $(img_loops); do losetup -d "$(loop_dev $l)" 2>/dev/null; done
        [ -z "$(img_loops)" ] && break
        i=$((i + 1))
        [ $i -ge 25 ] && { t "storage: system image still attached to $(img_loops | tr '\n' ' ')"; return 1; }
        usleep 200000
    done
    ef=$(e2fsck_bin 2>/dev/null || true)
    if type st_recover >/dev/null 2>&1; then
        st_recover || return 1
    fi
    if [ -n "$ef" ]; then
        "$ef" -p "$SYSTEM_IMG" >"$VD/logs/fsck.log" 2>&1; rc=$?
        if [ $rc -ge 4 ]; then
            echo "-- e2fsck -p rc=$rc, retry with -y" >>"$VD/logs/fsck.log"
            "$ef" -y "$SYSTEM_IMG" >>"$VD/logs/fsck.log" 2>&1; rc=$?
        fi
        echo "-- $(date) e2fsck rc=$rc" >>"$VD/logs/fsck.log"
    fi
    loop_mount "$SYSTEM_IMG" "$SYS" || return 1
}

sys_holders_kill() {
    sk_anc=" $$ "; sk_p=$$
    while [ -n "$sk_p" ] && [ "$sk_p" -gt 1 ] 2>/dev/null; do
        read -r sk_l < /proc/$sk_p/stat 2>/dev/null || break
        sk_l=${sk_l##*) }; set -- $sk_l; sk_p=$2; sk_anc="$sk_anc$sk_p "
    done
    sk_k=
    for sk_d in /proc/[0-9]*; do
        sk_p=${sk_d#/proc/}
        case "$sk_anc" in *" $sk_p "*) continue ;; esac
        sk_c=$(tr '\000' ' ' < $sk_d/cmdline 2>/dev/null) || continue
        case "$sk_c" in *"$VD/boot/"*|sleep\ *|usleep\ *|/bin/sleep\ *) ;; *) continue ;; esac
        ls -l $sk_d/cwd $sk_d/root $sk_d/fd 2>/dev/null | grep -q -- "-> $SYS\(/\|\$\)" || continue
        kill -9 "$sk_p" 2>/dev/null && sk_k="$sk_k $sk_p:$(echo "$sk_c" | cut -c1-60)"
    done
    [ -n "$sk_k" ] && t "stop: killed leftover processes holding $SYS:$sk_k"
    return 0
}

storage_umount() {
    awk -v d="$SYS" 'index($2, d "/") == 1 {print length($2), $2}' /proc/mounts | sort -rn | while read _ m; do
        umount -l "$m" 2>/dev/null || true
    done
    dev=$(awk -v m="$SYS" '$2==m {print $1}' /proc/mounts | tail -1)
    [ -n "$dev" ] || {
        for l in $(img_loops); do losetup -d "$(loop_dev $l)" 2>/dev/null || true; done
        return 0
    }
    i=0
    while ! umount "$SYS" 2>/dev/null; do
        awk -v d="$SYS" 'index($2, d "/") == 1 {print length($2), $2}' /proc/mounts | sort -rn | while read _ m; do
            umount -l "$m" 2>/dev/null || true
        done
        i=$((i + 1)); [ $i -ge 25 ] && { t "storage: $SYS still busy, left mounted"; break; }
        usleep 200000
    done
    case "$dev" in /dev/loop*) losetup -d "$dev" 2>/dev/null || true ;; esac
    for l in $(img_loops); do losetup -d "$(loop_dev $l)" 2>/dev/null || true; done
}

# FBInk discovery (prefer bundled Kobo fbink or KOReader's fbink)
FBINK=
fbink_probe() {
    if [ -n "$FBINK" ] && [ -x "$FBINK" ]; then
        "$FBINK" -e >/dev/null 2>&1 && return 0
        FBINK=
    fi
    for f in "$VD/bin/fbink" /mnt/onboard/.adds/koreader/fbink /usr/bin/fbink; do
        [ -x "$f" ] || continue
        if "$f" -e >/dev/null 2>&1; then
            FBINK=$f
            return 0
        fi
    done
    return 1
}
fbink_probe || true

KFONT=
for f in "$VD/fonts/LXGWWenKai-Regular.ttf" /mnt/onboard/fonts/LXGWWenKai-Regular.ttf /usr/local/Trolltech/QtEmbedded-4.6.2-arm/lib/fonts/KoboNickel.ttf; do
    [ -f "$f" ] && KFONT=$f && break
done

[ -f "$VD/boot/lib/progress.sh" ] && . "$VD/boot/lib/progress.sh"
[ -f "$VD/boot/lib/lock.sh" ] && . "$VD/boot/lib/lock.sh"
[ -f "$VD/boot/lib/saver.sh" ] && . "$VD/boot/lib/saver.sh"

t() { echo "[$(date +%H:%M:%S) up=$(cut -d' ' -f1 /proc/uptime)] $*"; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
log_release() { :; }

vd_timeout() {
    vt_s=$1; shift
    if [ -z "${VD_TMO_STYLE:-}" ]; then
        if timeout 5 true 2>/dev/null; then VD_TMO_STYLE=new
        elif timeout -t 5 true 2>/dev/null; then VD_TMO_STYLE=old
        else VD_TMO_STYLE=none; fi
    fi
    case $VD_TMO_STYLE in new) timeout "$vt_s" "$@" ;; old) timeout -t "$vt_s" "$@" ;; *) "$@" ;; esac
}

epd_send() {
    [ -p $X/epd.fifo ] && alive $W/epd.pid || return 1
    vd_timeout 3 sh -c 'echo "$1" > "$2"' sh "$*" $X/epd.fifo
}

vd_in() {
    p=$(cat $W/pid 2>/dev/null)
    if ! { [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }; then
        p=$P
        if ! { [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }; then return 1; fi
    fi
    P=$p
    echo "chroot /proc/$p/root"
}

splash() {
    [ -x "$FBINK" ] && [ -f "$KFONT" ] && "$FBINK" -q -c -m -M -t "regular=$KFONT,px=${2:-44}" "$1" 2>/dev/null
}

upload_dir_fix() {
    ud=$SYS/data/media/0/.upload
    [ -d "$SYS/data" ] || return 0
    if [ -L "$ud" ] || { [ -e "$ud" ] && [ ! -d "$ud" ]; }; then rm -f "$ud"; fi
    mkdir -p "$ud" 2>/dev/null
    chmod 777 "$SYS/data/media" "$SYS/data/media/0" "$ud" 2>/dev/null
    [ -d "$ud" ]
}

mounts_under() {
    awk -v d="${1%/}" -v self="${2:-0}" '($2 == d && self == 1) || index($2, d "/") == 1 { f = 1 } END { exit !f }' /proc/mounts && return 0
    mounts_under_ns "$1" "${2:-0}"
}

mounts_under_ns() {
    for mu_p in $(cat $W/pid 2>/dev/null); do
        [ -r /proc/$mu_p/mounts ] || continue
        awk -v d="${1%/}" -v self="${2:-0}" -v r="$R" -v sd="$SYS/data" '
            function hit(h) { return (h == d && self == 1) || index(h, d "/") == 1 }
            { m = $2; if (m == "/") m = ""
              if (hit(r m)) f = 1
              if (m == "/data" || index(m, "/data/") == 1) { if (hit(sd substr(m, 6))) f = 1 } }
            END { exit !f }' /proc/$mu_p/mounts && return 0
    done
    return 1
}

klib_link() {
    kl_m=$1/media/0; kl=$kl_m/KindleLibrary
    mkdir -p "$kl_m" 2>/dev/null || return 1
    if [ -L "$kl" ]; then
        [ "$(readlink "$kl")" = "$KLIB_MP" ] && return 0
        rm -f "$kl"
    elif [ -d "$kl" ]; then
        if mounts_under "$kl" 1; then t "klib: $kl is still a mount point"; return 1; fi
        rmdir "$kl" 2>/dev/null || mv "$kl" "$kl.stray-$(date +%Y%m%d-%H%M%S)" || return 1
    elif [ -e "$kl" ]; then
        mv "$kl" "$kl.stray-$(date +%Y%m%d-%H%M%S)" || return 1
    fi
    ln -s "$KLIB_MP" "$kl"
}

docs_list() {
    [ -d "$DOCS_DIR" ] || return 0
    ( cd "$DOCS_DIR/.." 2>/dev/null && find Documents -type f 2>/dev/null ) | sort
}
docs_snapshot() { docs_list > $W/docs.before 2>/dev/null; }
docs_verify() {
    [ -s "$1" ] || return 0
    dv_m=$W/docs.missing; : > $dv_m
    while IFS= read -r f; do [ -e "$DOCS_DIR/../$f" ] || printf '%s\n' "$f" >> $dv_m; done < "$1"
    [ -s $dv_m ] || return 0
    t "!!! DOCUMENTS LOSS: $(wc -l < $dv_m | tr -d ' ') files missing ($2)"
    return 1
}

userstore_check() {
    uc_mode=${1:-stop}; uc_bad=
    if [ "$uc_mode" = stop ]; then
        uc_m=$(awk -v d="$SYS" '$2 == d || index($2, d "/") == 1 { n++ } END { print n + 0 }' /proc/mounts)
        [ "$uc_m" -gt 0 ] && uc_bad="$uc_bad mounts-under-sys=$uc_m"
        uc_l=$(img_loops | tr '\n' ' '); [ -n "$uc_l" ] && uc_bad="$uc_bad loop-still-attached=$uc_l"
    fi
    uc_line="[$(date '+%F %T') up=$(cut -d' ' -f1 /proc/uptime)] after $uc_mode: ${uc_bad:-clean}"
    t "$uc_line"
    mkdir -p "$VD/logs" 2>/dev/null
    echo "$uc_line" >> "$VD/logs/last-stop.log" 2>/dev/null
    [ -z "$uc_bad" ]
}

storage_mount || true
