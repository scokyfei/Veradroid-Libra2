# SPDX-License-Identifier: GPL-3.0-or-later
# Load Kobo Libra 2 4.1.15 out-of-tree kernel modules (binder, zsmalloc, zram, madvise).
# Compatible with Koboweread's verified modules for firmware 4.34.20097 and 4.38.23852.

kmod_dir() {
    rel=$(uname -r)
    for d in "$VD/kmod/$rel" "/mnt/onboard/.adds/kobo-android-lab/kernels/$rel"; do
        [ -f "$d/binder_linux.ko" ] && { echo "$d"; return 0; }
    done
    return 1
}

kmod_load_one() { # mod_name ko_path [args...]
    m=$1; ko=$2; shift 2
    [ -f "$ko" ] || return 0
    grep -q "^$m " /proc/modules && return 0
    if insmod "$ko" "$@" 2>>"$LOG"; then
        t "kmod: loaded $m (${ko##*/})"
    else
        t "kmod: insmod ${ko##*/} failed"
        return 1
    fi
}

kmod_load() {
    d=$(kmod_dir) || { t "kmod: no modules found for kernel $(uname -r)"; return 1; }
    t "kmod: using $d"
    # 1. Binder IPC (/dev/binder)
    if ! grep -qw binder /proc/misc 2>/dev/null; then
        kmod_load_one binder_linux "$d/binder_linux.ko" || return 1
    fi
    if [ ! -c /dev/binder ]; then
        minor=$(awk '$2=="binder"{print $1}' /proc/misc 2>/dev/null)
        [ -n "$minor" ] && mknod /dev/binder c 10 "$minor" && t "kmod: mknod /dev/binder (10:$minor)"
    fi
    chmod 666 /dev/binder 2>/dev/null || true
    [ -c /dev/binder ] || { t "kmod: /dev/binder missing after insmod"; return 1; }

    # 2. Compressed swap (kobo_zsmalloc + kobo_zram)
    if [ ! -e /sys/block/zram0 ]; then
        kmod_load_one kobo_zsmalloc "$d/kobo_zsmalloc.ko" || true
        kmod_load_one kobo_zram "$d/kobo_zram.ko" || true
    fi

    # 3. Optional memory tuning module
    [ -f "$d/kobo_madvise.ko" ] && kmod_load_one kobo_madvise "$d/kobo_madvise.ko" || true

    # 4. Built-in uinput device check
    if [ ! -c /dev/uinput ]; then
        minor=$(awk '$2=="uinput"{print $1}' /proc/misc 2>/dev/null)
        [ -n "$minor" ] && mknod /dev/uinput c 10 "$minor" && t "kmod: mknod /dev/uinput (10:$minor)"
    fi
    chmod 666 /dev/uinput 2>/dev/null || true
    return 0
}
