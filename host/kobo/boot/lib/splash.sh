# SPDX-License-Identifier: GPL-3.0-or-later
# 开机画面：标题 + 随机一句与读书有关的诗文（中文和英文都有）+ 底部进度条。直接用 fbink 画（显示桥在开机期间被 ctl/sleep 挡住，不会盖掉它）。
# 进度来自 Android 自己的开机事件（logcat -b events 里的 boot_progress_*），不是假的计时条。
POEMS=$VD/boot/poems.txt

splash_pick() {
    [ -f "$POEMS" ] || return 1
    n=$(grep -c . "$POEMS")
    [ "$n" -gt 0 ] || return 1
    r=$(( $(head -c 2 /dev/urandom | od -An -tu2 | tr -d ' \n') % n + 1 ))
    sed -n "${r}p" "$POEMS" > $W/poem
}

# 整屏画一次（带一次闪刷，把书库的画面彻底盖掉）
splash_begin() {
    # Kindle UI is paused and the framebuffer is free by now. Probe here too:
    # the early common.sh probe can fail while awesome is still holding fb0.
    fbink_probe || return 0
    [ -n "$SPLASH_KEEP" ] || splash_pick
    touch $X/ctl/sleep 2>/dev/null     # 显示桥：开机期间不要画 Android 的帧
    T="regular=$KFONT"
    # 位置和字号按 PW6（1696 高）定的：小屏（PW3 1448、PW2 1024）按高度等比缩，否则上下边距之和超过屏高，
    # FBInk 拒绝画字（"Opposing margins sum to greater than the viewport"），开机画面只剩进度条
    SH=$($FBINK -e 2>/dev/null | tr ';' '\n' | sed -n 's/^viewHeight=//p' | head -1)
    [ "${SH:-0}" -gt 0 ] 2>/dev/null || SH=$(sed -n 's/.*U:\([0-9][0-9]*\)x\([0-9][0-9]*\)p.*/\1 \2/p' /sys/class/graphics/fb0/modes 2>/dev/null | awk '$2 >= $1 { print $2; exit }')
    [ "${SH:-0}" -gt 0 ] 2>/dev/null || SH=1696
    sc() { echo $(( $1 * SH / 1696 )); }
    $FBINK -q -c -b -m -t $T,px=$(sc 96),top=$(sc 330),bottom=$(sc 1200) "VeraDroid"
    $FBINK -q -b -m -t $T,px=$(sc 32),top=$(sc 470),bottom=$(sc 1100) "墨水屏上的 Android 阅读环境"
    if [ -s $W/poem ]; then
        title=$(cut -d'|' -f1 $W/poem); poet=$(cut -d'|' -f2 $W/poem)
        tpx=36; case "$title" in *[A-Za-z]*) tpx=28 ;; esac
        $FBINK -q -b -m -t $T,px=$(sc $tpx),top=$(sc 700),bottom=$(sc 900) "$title · $poet"
        # 英文诗句更长：字小一点，行距也小一点，免得超出屏幕宽度
        px=52; step=96
        case "$(cut -d'|' -f3 $W/poem)" in *[A-Za-z]*) px=40; step=78 ;; esac
        # 诗句整段一次画出（每次调用 fbink 都要读一遍字体，分开画很慢）
        body=""; i=3
        while line=$(cut -d'|' -f$i $W/poem) && [ -n "$line" ]; do
            body="${body:+$body
}$line"
            i=$((i + 1)); [ $i -gt 8 ] && break
        done
        $FBINK -q -b -m -t $T,px=$(sc $px),top=$(sc 800),bottom=$(sc 500) "$body"
    fi
    # 底部：方块进度框（sp_box）；FBInk 太老 / 没有 progress.sh 时退回原来的整宽进度条
    if type vp_frame >/dev/null 2>&1 && sp_geom; then sp_box ${2:-3}; else $FBINK -q -b -P ${2:-3} -y -5; fi
    $FBINK -q -f -s
}

# 后台停 Kindle 服务（512 MB 机型连书库 KPPMainApp 一起停）时，X 会把桌面背景重画成白色，盖掉开机画面的字
# （PW3 模拟器实测：帧缓冲里只剩进度条）。等停完再画一遍（同一句诗），开机还没完成才画。
splash_after_stop() {
    fbink_probe || return 0
    i=0; while [ ! -f $FWD/stopdone ] && [ $i -lt 60 ]; do sleep 1; i=$((i + 1)); done
    sleep 2
    [ -f $X/ctl/sleep ] || return 0
    SPLASH_KEEP=1 splash_begin "" "${PCT:-20}"
}

# 只更新底部进度条（它自带百分比，不再重复写一遍；局部刷新，很快）
splash_update() {   # $1 = 百分比  $2 = 文字
    fbink_probe || return 0
    if type vp_frame >/dev/null 2>&1 && sp_geom; then
        # 框架本来就停着（重启 Android）时 framework_stop 不会调 splash_begin：第一次更新时补画整屏
        [ -f $W/splash.on ] || splash_begin "" "$1"
        sp_draw "$1" "${2:-正在启动 Android}"
        return 0
    fi
    $FBINK -q -P $1 -y -5
}

# 开机完成：放开显示桥，整屏闪刷把 Android 桌面画出来
splash_end() {
    rm -f $X/ctl/sleep $W/splash.on
    epd_send FULL
}

# ---- 开机画面底部的方块进度框（和安装器同一种样子：双线框 + 投影、英文小字、粗体、一排方格；progress.sh）----
# 状态放在 $W/splash.*（splash_update 在 veradroid.sh 和后台的 boot_watch 两个进程里都会调）。
# 刷新：方格只补新涂黑的格子，字变了才写；整个框一次局部刷新（GL16，不闪）。已用时间至少 5 秒走一次（splash_tick）。
sp_geom() {
    type vp_fb_find >/dev/null 2>&1 || return 1
    [ "${VP_W:-0}" -gt 0 ] 2>/dev/null || vp_fb_find "$FBINK" || return 1
    SPM=$(vp_sc 64); SPW=$((VP_W - 2 * SPM)); SPH=$(vp_sc 400); SPY=$((VP_H - SPH - $(vp_sc 60)))
    G_SH=$(vp_sc 9); G_PAD=$(vp_sc 34); G_BX=$((SPM + G_PAD)); G_BARW=$((SPW - G_SH - 2 * G_PAD))
    G_BARY=$((SPY + $(vp_sc 168))); G_BARH=$(vp_sc 56); G_GAP=$(vp_sc 8); G_CW=$(( (G_BARW - G_GAP * (VP_N - 1)) / VP_N ))
    SPTX=$G_BX; SPTW=$((G_BARW - $(vp_sc 230))); SPPX=$((G_BX + G_BARW - $(vp_sc 220))); SPPW=$(vp_sc 220)
    SPI1=$((SPY + $(vp_sc 244))); SPI2=$((SPY + $(vp_sc 296)))
    return 0
}
sp_box() { # pct：画整个框（splash_begin 里，不刷新，最后整屏刷一次）
    sp_geom || return 0
    vp_frame $SPM $SPY $SPW $SPH 1
    vp_t $G_BX $((SPY + $(vp_sc 36))) $(vp_sc 600) $(vp_sc 32) $(vp_sc 22) "$VP_FEN" BLACK WHITE 0 "STARTING ANDROID"
    vp_bar_all 0
    date +%s > $W/splash.t0; echo 0 > $W/splash.cells; : > $W/splash.txt; touch $W/splash.on
    sp_draw "${1:-3}" "正在准备" norefresh
}
sp_info() { # 第一行：已用时间 + 正在优化哪个应用；第二行：慢的时候告诉用户怎么办
    e=$(( $(date +%s) - $(cat $W/splash.t0 2>/dev/null || date +%s) ))
    i1="已用 $(vp_mmss $e)"
    if [ -f $X/ctl/compile.status ] && grep -q '^state=running' $X/ctl/compile.status 2>/dev/null; then
        cs_i=$(sed -n 's/^index=//p' $X/ctl/compile.status); cs_n=$(sed -n 's/^total=//p' $X/ctl/compile.status); cs_p=$(sed -n 's/^pkg=//p' $X/ctl/compile.status)
        i1="$i1 · 正在优化应用 ${cs_i:-?}/${cs_n:-?} · $cs_p"
    elif [ -s $W/splash.dexopt ]; then
        i1="$i1 · $(cat $W/splash.dexopt)"
    fi
    i2="第一次开机（刚装好 / 刚更新）要优化应用，会慢一些"
    # 包管理真的在逐个检查应用（装好 / 更新后的第一次开机，PW4 真机报告里这一段 100 多秒，被当成死机）：说清楚要多久
    [ -s $W/splash.dexopt ] && i2="更新后首次启动正在检查应用，约 2–3 分钟，不是死机"
    [ $e -ge 180 ] && i2="比平常慢：多半在优化应用，再等等；超过 10 分钟没动静就长按电源键重启 Kindle"
}
sp_draw() { # pct 文字 [norefresh]
    sp_geom || return 0
    [ -f $W/splash.on ] || return 0
    pct=$1; [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    old=$(cat $W/splash.cells 2>/dev/null || echo 0); cells=$((pct * VP_N / 100))
    if [ "$cells" -lt "$old" ] 2>/dev/null; then vp_bar_all $cells; else i=$old; while [ $i -lt $cells ]; do vp_cell $i 1; i=$((i + 1)); done; fi
    echo $cells > $W/splash.cells
    sp_info
    new="$pct|$2|$i1|$i2"
    if [ "$new" != "$(cat $W/splash.txt 2>/dev/null)" ]; then
        vp_t $SPTX $((SPY + $(vp_sc 72))) $SPTW $(vp_sc 80) $(vp_sc 54) "$VP_FZB" BLACK WHITE 0 "$2"
        vp_t $SPPX $((SPY + $(vp_sc 60))) $SPPW $(vp_sc 96) $(vp_sc 68) "$VP_FEN" BLACK WHITE 1 "$pct%"
        vp_t $SPTX $SPI1 $G_BARW $(vp_sc 48) $(vp_sc 30) "$VP_FZB" BLACK WHITE 0 "$i1"
        vp_t $SPTX $SPI2 $G_BARW $(vp_sc 70) $(vp_sc 26) "$VP_FZR" BLACK WHITE 0 "$i2"
        printf '%s' "$new" > $W/splash.txt
    fi
    date +%s > $W/splash.last
    [ "${3:-}" = norefresh ] || vp_ref $SPM $SPY $SPW $SPH GL16
    return 0
}
# 每轮 boot_watch 调：离上次画超过 5 秒就只重画“已用时间”那两行（很小的一块局部刷新）
splash_tick() {
    [ -f $W/splash.on ] && [ -n "$FBINK" ] || return 0
    [ $(( $(date +%s) - $(cat $W/splash.last 2>/dev/null || echo 0) )) -ge 5 ] || return 0
    sp_geom || return 0
    sp_info
    vp_t $SPTX $SPI1 $G_BARW $(vp_sc 48) $(vp_sc 30) "$VP_FZB" BLACK WHITE 0 "$i1"
    vp_t $SPTX $SPI2 $G_BARW $(vp_sc 70) $(vp_sc 26) "$VP_FZR" BLACK WHITE 0 "$i2"
    vp_ref $SPTX $SPI1 $G_BARW $((SPI2 + $(vp_sc 70) - SPI1)) GL16
    date +%s > $W/splash.last
    t_=$(cat $W/splash.txt 2>/dev/null); printf '%s' "${t_%|*|*}|$i1|$i2" > $W/splash.txt
}
