# 屏保挑选（VeraHome 的 ScreensaverActivity，docs/host-settings.md 第 10 节）。
# 选择存在 Android 存储里的一个小文件（桌面写，宿主在每次进屏保时读）：
#   $SYS/data/media/0/Screensaver/.vd-saver   （Android 里 /sdcard/Screensaver/.vd-saver）
#     mode=kindle   用 Kindle 自带的屏保图（默认）
#     mode=rotate   轮换用户的全部图片（veradroid/screensaver/ 和 Android 的 Screensaver/）
#     mode=one      只用一张：file=sd/<文件名>（Android 的 Screensaver/）或 file=vd/<文件名>（Kindle 的 veradroid/screensaver/）
# 没有这个文件 = 以前的做法（有用户图就轮换，没有就用 Kindle 自带的），老用户行为不变。
SAVER_SEL=$SYS/data/media/0/Screensaver/.vd-saver
# 读选择：设 smode（kindle / rotate / one / 空=旧做法）和 sone（一张图的宿主路径）
saver_choice() {
    smode=; sone=
    [ -f "$SAVER_SEL" ] && [ ! -L "$SAVER_SEL" ] || return 0
    smode=$(sed -n 's/^mode=\([a-z]*\)$/\1/p' "$SAVER_SEL" | tail -1)
    case "$smode" in kindle|rotate|one) ;; *) smode= ; return 0 ;; esac
    [ "$smode" = one ] || return 0
    sf=$(sed -n 's/^file=\(.*\)$/\1/p' "$SAVER_SEL" | tail -1)
    sname=${sf#*/}
    case "$sname" in ''|*/*|.*) smode=rotate; return 0 ;; esac          # 只认文件名，不认路径（.. 之类一律不要）
    case "$sf" in
        sd/*) sone="$SYS/data/media/0/Screensaver/$sname" ;;
        vd/*) sone="$VD/screensaver/$sname" ;;
    esac
    [ -n "$sone" ] && [ -f "$sone" ] && [ ! -L "$sone" ] || { sone=; smode=rotate; }   # 那张图被删了：退回轮换
    return 0
}
# 给桌面看 veradroid/screensaver/ 里的图（Android 看不到 Kindle 的 veradroid 文件夹）：临时拷到 $X/saver/（tmpfs，Android 里 /dev/kfb/saver/），
# 另拷一张 Kindle 自带的屏保图当“Kindle 自带”的预览。页面关掉时 saver done 删掉。每张不超过 8 MB，最多 60 张。
saver_cmd() {
    case "$1" in
    list)
        rm -rf $X/saver; mkdir -p $X/saver.tmp || return 0
        n=0
        for f in "$VD"/screensaver/*.[pP][nN][gG] "$VD"/screensaver/*.[jJ][pP][gG] "$VD"/screensaver/*.[jJ][pP][eE][gG]; do
            [ -f "$f" ] && [ ! -L "$f" ] || continue
            case "$f" in */default.png|*/default.PNG) continue ;; esac
            [ "$(wc -c < "$f")" -le 8388608 ] || continue
            cp "$f" $X/saver.tmp/ 2>/dev/null && n=$((n + 1))
            [ $n -ge 60 ] && break
        done
        for f in /usr/share/blanket/screensaver/bg_ss*.png; do [ -f "$f" ] && { cp "$f" $X/saver.tmp/.kindle-preview.png; break; }; done
        chmod 755 $X/saver.tmp; chmod 644 $X/saver.tmp/* $X/saver.tmp/.kindle-preview.png 2>/dev/null
        mv $X/saver.tmp $X/saver; : > $X/ctl/saver.listed
        t "screensaver: exported $n image(s) from veradroid/screensaver for the picker" ;;
    done) rm -rf $X/saver $X/saver.tmp $X/ctl/saver.listed ;;
    esac
}
