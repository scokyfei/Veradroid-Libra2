#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Offline incremental updater for VeraDroid on Kobo Libra 2 (N418).
#
# Drop Veradroid-Libra2-<ver>-upgrade.zip (or -full.zip) into:
#   /mnt/onboard/.adds/Veradroid-Libra2/update/
# It will be applied automatically on next launch (NickelMenu or KOReader),
# or manually via:
#   sh /mnt/onboard/.adds/Veradroid-Libra2/boot/lib/localupdate.sh check
#   sh /mnt/onboard/.adds/Veradroid-Libra2/boot/lib/localupdate.sh install [--force] [--quiet]
#
# Preserves 100% of user data: veradroid-sys.img (/data), settings.conf,
# apps/, fonts/, screensaver/, logs/. Updates boot/, bin/, models/, kmod/,
# VERSION, NickelMenu entry (if .adds/nm exists), and KOReader plugin (if .adds/koreader exists).

PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH; export PATH
VD=${VD:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}
W=/tmp/veradroid
UPD=$VD/update
STAGE=$VD/state/update.stage
BAK=$VD/state/upgrade.bak
LOG=$VD/logs/localupdate.log
NM_DIR=/mnt/onboard/.adds/nm
KO_PLUGINS=/mnt/onboard/.adds/koreader/plugins

MODE=${1:-check}
shift 2>/dev/null || true
FORCE=0
QUIET=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        --quiet) QUIET=1 ;;
    esac
done

mkdir -p "$VD/logs" "$VD/state" "$UPD" "$W" 2>/dev/null || true
lg() { echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null || true; }
say() { [ "$QUIET" = 1 ] || echo "$*"; lg "$*"; }

cur_ver() {
    head -1 "$VD/VERSION" 2>/dev/null | sed 's/-.*//' | tr -cd '0-9.'
}

ver_gt() { # returns 0 if $1 > $2
    [ "$1" = "$2" ] && return 1
    printf '%s\n%s\n' "$1" "$2" | awk -F. '
        NR == 1 { n1 = split($0, a, ".") }
        NR == 2 { n2 = split($0, b, ".") }
        END {
            n = n1 > n2 ? n1 : n2
            for (i = 1; i <= n; i++) {
                x = a[i] + 0; y = b[i] + 0
                if (x > y) exit 0
                if (x < y) exit 1
            }
            exit 1
        }'
}

write_result() {
    {
        echo "time=$(date '+%F %T')"
        for kv in "$@"; do printf '%s\n' "$kv"; done
    } > "$UPD/result.txt.tmp" 2>/dev/null && mv -f "$UPD/result.txt.tmp" "$UPD/result.txt" 2>/dev/null || true
}

find_best_zip() {
    best=
    bestver=
    for f in "$UPD"/Veradroid-Libra2-*.zip "$UPD"/VeraDroid-Kobo-Libra2-*.zip "$UPD"/veradroid-kobo-libra2-*.zip; do
        [ -f "$f" ] || continue
        bn=${f##*/}
        v=$(printf '%s' "$bn" | sed -n 's/.*-\([0-9][0-9.]*\)\(-[a-zA-Z0-9_]*\)\{0,1\}\.zip$/\1/p')
        [ -n "$v" ] || continue
        if [ -z "$best" ] || ver_gt "$v" "$bestver"; then
            best=$f
            bestver=$v
        fi
    done
    [ -n "$best" ] && printf '%s\t%s\n' "$best" "$bestver"
}

if [ "$MODE" = check ]; then
    cv=$(cur_ver)
    echo "installed=${cv:-unknown}"
    found=$(find_best_zip || true)
    if [ -n "$found" ]; then
        f=${found%%	*}; v=${found#*	}
        st=ready
        if [ "$FORCE" = 0 ] && [ -n "$cv" ] && ! ver_gt "$v" "$cv"; then
            st=not-newer
        fi
        echo "candidate=${f##*/} $v $st"
    else
        echo "candidate=none"
    fi
    [ -f "$UPD/result.txt" ] && sed 's/^/last./' "$UPD/result.txt"
    exit 0
fi

[ "$MODE" = install ] || { echo "usage: localupdate.sh check | install [--force] [--quiet]"; exit 2; }

# Refuse live overwrite while Android container is running
pid=$(cat "$W/pid" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    say "VeraDroid 正在运行，请先停止后再应用升级包。"
    exit 1
fi

found=$(find_best_zip || true)
if [ -z "$found" ]; then
    say "未在 update/ 目录发现升级包（Veradroid-Libra2-*.zip）。"
    exit 3
fi

ZIP=${found%%	*}
NEWVER=${found#*	}
CURVER=$(cur_ver)
BN=${ZIP##*/}

if [ "$FORCE" = 0 ] && [ -n "$CURVER" ] && ! ver_gt "$NEWVER" "$CURVER"; then
    if [ "$NEWVER" = "$CURVER" ]; then
        say "已是当前版本 $CURVER，跳过 $BN（如需覆盖请使用 --force）。"
    else
        say "升级包版本 $NEWVER 不高于当前版本 $CURVER，已跳过 $BN。"
    fi
    mv -f "$ZIP" "$ZIP.skipped" 2>/dev/null || true
    write_result "result=skipped" "file=$BN" "from=$CURVER" "to=$NEWVER" "reason=not-newer"
    exit 3
fi

# Prevent concurrent updater runs
if ! mkdir "$W/localupdate.lock" 2>/dev/null; then
    op=$(cat "$W/localupdate.lock/pid" 2>/dev/null || true)
    if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then
        say "另一个更新任务正在进行中。"
        exit 1
    fi
    rm -rf "$W/localupdate.lock"
    mkdir "$W/localupdate.lock" || exit 1
fi
echo $$ > "$W/localupdate.lock/pid"
trap 'rm -rf "$W/localupdate.lock" "$STAGE"' EXIT

fail() {
    say "升级失败：$1"
    write_result "result=failed" "file=$BN" "from=$CURVER" "to=$NEWVER" "reason=$1"
    mv -f "$ZIP" "$ZIP.failed" 2>/dev/null || true
    exit 1
}

lg "starting offline update: $BN ($CURVER -> $NEWVER)"
command -v unzip >/dev/null 2>&1 || fail "系统缺少 unzip 命令"
# Kobo BusyBox unzip does not support -t; verify central directory via -lq (extraction checks CRC32 + SHA256SUMS below)
unzip -lq "$ZIP" >/dev/null 2>&1 || fail "压缩包损坏或下载不完整"

rm -rf "$STAGE"
mkdir -p "$STAGE" || fail "无法创建临时解压目录"
unzip -o -q "$ZIP" -d "$STAGE" 2>/dev/null || fail "解压升级包失败（存储空间不足？）"

SRC=
for cand in "$STAGE/.adds/Veradroid-Libra2" "$STAGE/.adds/veradroid-libra2"; do
    [ -d "$cand" ] && { SRC=$cand; break; }
done
[ -n "$SRC" ] || fail "升级包目录结构无效（缺少 .adds/Veradroid-Libra2）"
[ -f "$SRC/manifest.json" ] || fail "升级包缺少 manifest.json"
grep -q '"product"[[:space:]]*:[[:space:]]*"veradroid-kobo-libra2"' "$SRC/manifest.json" || fail "非 Kobo Libra 2 专用安装包"
[ -f "$SRC/boot/veradroid.sh" ] && sh -n "$SRC/boot/veradroid.sh" 2>/dev/null || fail "升级包启动脚本校验失败"

# Verify SHA256SUMS when present and sha256sum is available
if [ -f "$SRC/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
    bad=
    while read -r want rel; do
        [ -n "$want" ] && [ -n "$rel" ] || continue
        case "$rel" in /*|*..*) bad="非法路径 $rel"; break ;; esac
        if [ ! -f "$SRC/$rel" ]; then
            bad="缺少文件 $rel"; break
        fi
        got=$(sha256sum "$SRC/$rel" | awk '{print $1}')
        if [ "$got" != "$want" ]; then
            bad="SHA-256 校验失败: $rel"; break
        fi
    done < "$SRC/SHA256SUMS"
    [ -z "$bad" ] || fail "$bad"
    lg "SHA256SUMS verified ok"
fi

# Backup current runtime code for rollback (never touches veradroid-sys.img or user data)
rm -rf "$BAK"
mkdir -p "$BAK" || fail "无法创建回滚备份目录"
for item in VERSION boot bin models; do
    [ -e "$VD/$item" ] && cp -a "$VD/$item" "$BAK/" 2>/dev/null || true
done

rollback() {
    lg "rolling back from $BAK ($1)"
    for item in VERSION boot bin models; do
        if [ -e "$BAK/$item" ]; then
            rm -rf "$VD/$item"
            cp -a "$BAK/$item" "$VD/" 2>/dev/null || true
        fi
    done
    fail "$1"
}

# Apply payload selectively — NEVER overwrite veradroid-sys.img, settings.conf, logs/, apps/, screensaver/, state/
for d in boot bin models kmod koplugin nm seed; do
    if [ -d "$SRC/$d" ]; then
        mkdir -p "$VD/$d"
        cp -a "$SRC/$d/." "$VD/$d/" || rollback "复制 $d 目录失败"
    fi
done
# Only copy bundled font if not already present (preserves user's fonts/ folder)
if [ -d "$SRC/fonts" ]; then
    mkdir -p "$VD/fonts"
    for ff in "$SRC/fonts"/*; do
        [ -f "$ff" ] || continue
        [ -f "$VD/fonts/${ff##*/}" ] || cp "$ff" "$VD/fonts/" || true
    done
fi
for f in VERSION manifest.json install.sh; do
    [ -f "$SRC/$f" ] && { cp -f "$SRC/$f" "$VD/$f" || rollback "复制 $f 失败"; }
done
# Stage rootfs.tar.gz if included in a full bundle (veradroid.sh will compare SHA-256 and upgrade only if changed)
if [ -f "$SRC/rootfs.tar.gz" ]; then
    mv -f "$SRC/rootfs.tar.gz" "$VD/rootfs.tar.gz" || rollback "暂存 rootfs.tar.gz 失败"
fi

chmod 755 "$VD/bin/"* "$VD/boot/"*.sh 2>/dev/null || true
[ -f "$VD/install.sh" ] && chmod 755 "$VD/install.sh" 2>/dev/null || true

# Sync both NickelMenu and KOReader entry points when present
updated_entries=
if [ -d "$NM_DIR" ] && [ -f "$VD/nm/Veradroid-Libra2" ]; then
    cp -f "$VD/nm/Veradroid-Libra2" "$NM_DIR/Veradroid-Libra2" 2>/dev/null && updated_entries="${updated_entries}NickelMenu "
fi
if [ -d "/mnt/onboard/.adds/koreader" ] && [ -d "$VD/koplugin/Veradroid-Libra2.koplugin" ]; then
    mkdir -p "$KO_PLUGINS" 2>/dev/null || true
    rm -rf "$KO_PLUGINS/Veradroid-Libra2.koplugin" 2>/dev/null || true
    cp -a "$VD/koplugin/Veradroid-Libra2.koplugin" "$KO_PLUGINS/" 2>/dev/null && updated_entries="${updated_entries}KOReader "
fi

sync
rm -rf "$BAK" "$STAGE"
rm -f "$ZIP" "$ZIP.sha256" 2>/dev/null || true
write_result "result=ok" "file=$BN" "from=${CURVER:-0}" "to=$NEWVER" "entries=${updated_entries:-none}"
say "升级成功：${CURVER:-旧版} -> $NEWVER（已保留全部应用与数据，入口同步：${updated_entries:-保持原样}）。"
exit 0
