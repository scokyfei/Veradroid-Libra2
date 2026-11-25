# SPDX-License-Identifier: GPL-3.0-or-later
# 应用预编译：新装的应用只做了很少的编译（interpret-only / verify），冷启动慢一倍多
# （微信读书 PW6 实测 10.6 s → speed 编译后 4.5 s）。装完以后在后台、低优先级、一次一个地用
#   cmd package compile -m speed -f <包>
# 把它编好。触发：宿主 install 命令、after_boot 装 APK、Android 里自己装 / 更新的应用（看门狗发现 packages.list 变了），
# 以及命令 `compile all|<包>`。电量低（< 20 % 且没充电）、内存紧张、Android 冻着时不编，等条件好了再继续。
#
# 进度写在 $X/ctl/compile.status（KEY=value，一行一个；桌面读它显示“正在优化 微信读书 (2/5)”，名字由桌面按包名查）：
#   state=idle|running|waiting|paused   pkg=<正在编的包>   index=<第几个>   total=<这一批共几个>
#   reason=battery|memory|frozen|off|foreground|busy（waiting / paused 时）；foreground / busy 时 reason 直接是中文（老桌面原样显示），机器读 code=   last=<包> ok|fail <秒>
#   msg=<给用户看的一句话>（有就直接显示；老桌面不认 foreground / busy，新桌面优先用它）
# 设置 APP_COMPILE=auto|speed|off（settings.sh）：auto = 957 MB 的机型 speed，512 MB 机型见 compile_mode。
#
# 什么时候编（0.89 用户诊断：系统更新后微信读书的 odex 失效，宿主在用户正读书时给微信读书本身重编 357 秒——dex2oat 173 MB
# + 微信读书 221 MB，MemAvailable 掉到 zram 换页、system_server lowmem、微信读书的 :seg 服务 ANR、WindowManager 锁等了 8.9 秒）：
# - 前台的应用（$X/fg，VeraHome 的 HostService 在任务栈一变时写）不编：跳过它先编别的，它离开前台再编。
#   编着的时候它到了前台：马上停掉 dex2oat（和给安装让路一样），重新排队。
# - 用户在用（COMPILE_IDLE_S 秒内摸过屏：action.sh 的 poke 每 20 秒最多 touch 一次 $W/lastinput）：dex2oat 单线程，
#   可用内存不到 COMPILE_ACTIVE_MB（1 GB 机型 400，512 MB 机型 200）不开始；编着时掉到 COMPILE_ACTIVE_ABORT_MB
#   （200 / 100）以下就停掉重排，之后等用户不用了（空闲）再开始。
# - 充电 + 空闲：dex2oat 用系统默认线程数（最快）；其余情况一律单线程。
# - 屏保时 Android 冻着，编不了（sleep.sh 冻结整个容器）；不为编译去解冻或推迟屏保，醒来后接着编。
# 过滤器仍用 speed（不是 speed-profile）：7.1 的 speed-profile 只编 JIT 记下的热点方法，odex 小、编得快，但更新后刚启动的应用
# 还没有档案（profile），编出来几乎等于 interpret-only；阅读类应用翻页 / 打开书的耗时 speed 实测更好。
# 代价（编得久、内存大）由上面的调度挡住，不在过滤器上省。
#
# 是否已经编好：直接在宿主上读 odex 的 OAT 头（key-value 区里的 compiler-filter），不用为一次查询起 JVM，冻结时也能读。
CQ=$W/compile.queue
CST=$X/ctl/compile.status
CLOG=$SYS/data/.vd-compile.log     # 结果记录（包 过滤器 秒数 结果），也用来避免对同一个安装反复失败重试

# 当前这个安装（/data/app/<包>-N）的 odex 用的编译过滤器；没有 odex 时输出空
odex_filter() { # pkg
    for d in $SYS/data/app/$(app_dir "$1"); do
        [ -d "$d" ] || continue
        for o in "$d"/oat/arm/base.odex "$d"/oat/arm64/base.odex; do
            [ -f "$o" ] || continue
            # OAT 头在 ELF 的 oatdata 段开头（7.1 镜像实测在 0x1000），key-value 区是 \0 分隔的字符串对
            dd if="$o" bs=4096 count=4 2>/dev/null | tr '\0' '\n' 2>/dev/null | sed -n '/^compiler-filter$/{n;p;q;}'
            return 0
        done
    done
}
# 当前安装的代码目录（/data/app/<包>-N 的 N），用来区分“同一个安装编译失败过”和“已经更新成新版本”
# 有两个目录时用 packages.xml 里的 codePath，避免对着残留旧目录编译或保护 odex
app_dir() {
    ad_n=0; ad_f=
    for d in $SYS/data/app/"$1"-*; do [ -d "$d" ] && { ad_n=$((ad_n + 1)); [ -n "$ad_f" ] || ad_f=${d##*/}; }; done
    [ -n "$ad_f" ] || return 1
    if [ "$ad_n" -gt 1 ]; then
        ad_c=$(sed -n "s#.*<package name=\"$1\" codePath=\"/data/app/\([^\"/]*\)\".*#\1#p" $SYS/data/system/packages.xml 2>/dev/null | head -n 1)
        [ -n "$ad_c" ] && [ -d "$SYS/data/app/$ad_c" ] && ad_f=$ad_c
    fi
    echo "$ad_f"
}
# 数据区里装的第三方应用（系统应用已经在镜像里预编译）
data_pkgs() {
    for d in $SYS/data/app/*-[0-9]*; do
        [ -d "$d" ] || continue
        p=${d##*/}; p=${p%-*}
        case "$p" in *[!A-Za-z0-9._]*|'') continue ;; esac
        echo "$p"
    done | sort -u
}

# APP_COMPILE 设置 → 实际用的过滤器（空 = 不编）。
# 512 MB 机型（KT5 / KT6 / PW5）：kt6-5192 模拟器实测 speed 编微信读书能完成、没有被杀，但 dex2oat 占 ~200 MB，
# 期间 zram 换出很多；所以只在内存够的时候开始（compile_mem_ok），并把 dex2oat 限成单线程（compile_one）。
compile_mode() {
    case "${APP_COMPILE:-auto}" in
        off) echo "" ;;
        speed) echo speed ;;
        # auto：机型文件可以给更省的过滤器（COMPILE_FILTER=space / interpret-only：单核 A9 + 512 MB 上 speed 编大应用
        # 要很久、dex2oat 占 150–250 MB）
        auto) case "$COMPILE_FILTER" in space|interpret-only|balanced|speed) echo "$COMPILE_FILTER" ;; *) echo speed ;; esac ;;
        *) echo speed ;;
    esac
}
compile_done_filter() {
    case "$1" in speed|speed-profile|everything) return 0 ;; esac
    [ -n "$1" ] && [ "$1" = "$(compile_mode)" ] && return 0
    return 1
}
# 512 MB 机型上的大应用（dex >= COMPILE_BIG_DEX_MB，默认 120 MB）只编 verify-at-runtime：
# 避免 dex2oat 在 512 MB 上把 swap 吃满后超时失败、留下空 odex。COMPILE_BIG_LOW=off 恢复原行为。
compile_dex_mb() { # pkg -> MB（读不出来返回 1）；按安装目录 + base.apk 时间缓存在 $W
    cdm_d=$(app_dir "$1") || return 1
    cdm_a=$SYS/data/app/$cdm_d/base.apk
    cdm_k="$cdm_d $(stat -c %Y "$cdm_a" 2>/dev/null)"; cdm_c=$W/compile.dexmb.$1
    if [ -f "$cdm_c" ] && [ "$(head -n 1 "$cdm_c")" = "$cdm_k" ]; then sed -n 2p "$cdm_c"; return 0; fi
    command -v unzip >/dev/null 2>&1 || return 1
    cdm_m=$(unzip -l "$cdm_a" 2>/dev/null | awk '$4 ~ /^classes[0-9]*\.dex$/ { s += $1 } END { print int(s / 1048576) }')
    case "$cdm_m" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n%s\n' "$cdm_k" "$cdm_m" > "$cdm_c" 2>/dev/null
    echo "$cdm_m"
}
compile_big() { cb_m=$(compile_dex_mb "$1") && [ "$cb_m" -ge ${COMPILE_BIG_DEX_MB:-120} ]; }
compile_low_big() { [ "${COMPILE_BIG_LOW:-on}" != off ] && lowmem_ram && compile_big "$1"; }
compile_pkg_mode() { if compile_low_big "$1"; then echo verify-at-runtime; else echo "$2"; fi; }   # pkg mode
# 这个包要不要编（$2=force 时只要装着就编）
compile_needed() { # pkg [force]
    app_dir "$1" >/dev/null || return 1
    [ "$2" = force ] && return 0
    compile_done_filter "$(odex_filter "$1")" && return 1
    # 512 MB 的大应用：有 odex（verify-at-runtime / interpret-only）就算编好，不再为 speed 占几百 MB
    compile_low_big "$1" && [ -n "$(odex_filter "$1")" ] && return 1
    # 同一个安装失败过两次就不再自动试（命令 compile <包> 仍然会强制编）
    nf=$(grep -c "^$1 $(app_dir "$1") fail" $CLOG 2>/dev/null); [ "${nf:-0}" -ge 2 ] && return 1
    grep -q "^$1 $(app_dir "$1") capped" $CLOG 2>/dev/null && return 1
    grep -q "^$1 $(app_dir "$1") timeout" $CLOG 2>/dev/null && return 1
    return 0
}

compile_status() { # KEY=value...
    [ -d $X/ctl ] || return 0
    printf '%s\n' "$@" > $CST.tmp 2>/dev/null && chmod 644 $CST.tmp 2>/dev/null && mv -f $CST.tmp $CST
}
# 排队（去重）。$2=force：强制重编
compile_enqueue() { # pkg [force]
    case "$1" in ''|*[!A-Za-z0-9._]*) return 1 ;; esac
    compile_needed "$1" "$2" || return 1
    grep -q "^$1\( \|\$\)" $CQ 2>/dev/null && return 0
    echo "$1${2:+ $2}" >> $CQ
    echo $(( $(cat $W/compile.total 2>/dev/null || echo 0) + 1 )) > $W/compile.total
    t "compile: queued $1${2:+ ($2)}"
}
# 编好的代码失效了的应用。odex 是对着“当时那份启动镜像（boot.art）”编的；系统更新（换了 rootfs、清了 dalvik-cache）以后
# 启动镜像重新生成、重定位到另一个随机地址，旧的 odex 变成 kOatNeedsRelocation：ART 只把它当数据映射（不可执行），
# 整个应用退回解释执行 + JIT，而 OAT 头里的过滤器仍然写着 speed，所以上面的 odex_filter 看不出来。
# PW6 真机（0.88 → 0.89 更新后）实测：5 个第三方应用全部如此，微信读书的 169 MB odex 没有一页是可执行映射；
# 重新编译后翻页 / 打开书 / 切换标签的耗时在真机上实测过。
# 这里问 Android 自己的判断（dumpsys package dexopt，一次约 0.3 s），每次开机每个包最多因此重编一次。
compile_stale_pkgs() {
    [ -f $W/frozen ] || [ -f $W/saver_frozen ] && return 0
    # dumpsys 按 120 列折行（长包名的 "status=kOatUpToDate]" 会断成 "kOatUpToD" + 下一行 "ate]"），odex 坏掉 / 半截时
    # 只有 "status: invalid[]"、没有 "status="（pw5-5182 模拟器：一次失败的 speed 编译留下 71 MB 开头全零的 odex，
    # 以前这里看不出来，微信读书一直从 apk 解释执行）。所以把一个 path 之后到下一个 path / 包头为止的文字去掉空白拼起来再判断。
    adb_sh "dumpsys package dexopt" 2>/dev/null | tr -d '\r' | awk '
        function flush() { if (p != "" && b != "" && b !~ /status=kOatUpToDate/) { st = b; sub(/.*status=/, "", st); sub(/[],].*/, "", st); if (b !~ /status=/) st = "invalid"; print p, st } p = ""; b = "" }
        /path: \/data\/app\// { flush(); p = $2; sub(/^\/data\/app\//, "", p); sub(/-[0-9]+\/.*$/, "", p); next }
        /path:/ || /^ *\[/ { flush(); next }
        p != "" { l = $0; gsub(/[ \t]/, "", l); b = b l }
        END { flush() }' | sort -u
}
# 完全没有可用 odex 的应用（dumpsys 里 "status: invalid[]"：以前 dex2oat 根本起不来时装的应用、编译被打断留下的半截 odex）：
# 不等充电，开机后马上在后台补一个 interpret-only（PW4 模拟器上微信读书 107 秒），每次开机最多一次。speed 照旧只在充电时编。
compile_invalid_pkgs() {
    adb_sh "dumpsys package dexopt" 2>/dev/null | tr -d '\r' | awk '
        function flush() { if (p != "" && b ~ /^status:invalid/) print p; p = ""; b = "" }
        /path: \/data\/app\// { flush(); p = $2; sub(/^\/data\/app\//, "", p); sub(/-[0-9]+\/.*$/, "", p); next }
        /path:/ || /^ *\[/ { flush(); next }
        p != "" { l = $0; gsub(/[ \t]/, "", l); b = b l }
        END { flush() }' | sort -u
}
compile_fix_invalid() {
    [ -f $W/compile.invalid_done ] && return 0
    : > $W/compile.invalid_done
    (
        for p in $(compile_invalid_pkgs); do
            compile_held && break
            [ -f $W/frozen ] || [ -f $W/saver_frozen ] && break
            ci_f=interpret-only; compile_low_big "$p" && ci_f=verify-at-runtime
            compile_pm_start "$p" $W/compile.inv.out -m $ci_f -f "$p"
            compile_babysit $cp_ "$p"; compile_pm_wait
            t "compile: $p had no usable odex, $ci_f -> $(odex_filter "$p") ($(tr '\n' ' ' < $W/compile.inv.out | cut -c1-60))"
        done
    ) </dev/null >>$LOG 2>&1 &
}
compile_scan() { # 所有还没编好的数据区应用排队
    # 换了版本：以前记的 fail 不再算（同一个安装失败两次就不再自动编；0.8.8 的 compile_held 把 $f 改坏、给安装让路的
    # 中断被记成 fail，KO3 用户诊断：微信读书因此一直没编，升级以后也不会再试）。timeout / capped 保留。
    csv=$(cat $VD/version 2>/dev/null || cat $SYS/version 2>/dev/null)
    if [ -n "$csv" ] && [ "$(cat $SYS/data/.vd-compile.ver 2>/dev/null)" != "$csv" ]; then
        [ -f $CLOG ] && sed -i '/^[^ ]* [^ ]* fail /d' $CLOG 2>/dev/null
        echo "$csv" > $SYS/data/.vd-compile.ver 2>/dev/null
    fi
    [ -n "$(compile_mode)" ] || return 0
    compile_fix_invalid
    for p in $(data_pkgs); do compile_enqueue "$p"; done
    compile_stale_pkgs | while read -r p st; do
        grep -q "^$p\$" $W/compile.stale 2>/dev/null && continue
        echo "$p" >> $W/compile.stale
        # 记下 Android 给的真实状态（kOatBootImageOutOfDate / kOatDexOutOfDate / kOatNeedsRelocation / invalid）：
        # KO3 用户诊断里 8 次启动有 3 次所有应用都被重编（约 10 分钟），原因要靠这个分清（编译被返回 Kindle 打断？启动镜像真的变了？）
        t "compile: $p compiled code not usable (${st:-?}, runs interpreted), recompiling"
        : > $W/compile.nocode.$p      # 现在就没有能用的编译代码：在用着也可以编（compile_nocode）
        compile_enqueue "$p" force
    done
    [ -s $CQ ] && compile_kick
    return 0
}
# packages.list 变了（装 / 卸 / 更新了应用）就扫一遍。看门狗每一轮调一次：只比较 mtime 和大小，几乎不花时间
compile_watch() {
    # 开机完成（after_boot 写 $W/booted）一分钟以后才开始：别和用户打开的第一个应用抢 CPU
    b=$(cat $W/booted 2>/dev/null); [ -n "$b" ] || return 0
    [ $(( $(cut -d. -f1 /proc/uptime) - b )) -ge 60 ] || return 0
    # 工作进程因为内存一直不够先停了（队列还在）：到了约定时间再起一次，保证队列最终能编完
    if [ -s $CQ ] && [ -f $W/compile.retry_at ] && ! alive $W/compile.pid &&
       [ "$(cut -d. -f1 /proc/uptime)" -ge "$(cat $W/compile.retry_at 2>/dev/null || echo 0)" ]; then
        rm -f $W/compile.retry_at; compile_kick
    fi
    # Charging + idle (>=120s): refresh WeRead speed-profile AOT when live JIT profile grew >=2KB (at most once/24h)
    if [ -x "$VD/boot/weread-speed-profile.sh" ] && ! alive $W/compile.pid && ! alive $W/weread.prof.pid \
        && type kobo_is_charging >/dev/null 2>&1 && kobo_is_charging \
        && [ "$(compile_idle_s)" -ge 120 ]; then
        wp_cur=$SYS/data/misc/profiles/cur/0/com.tencent.weread.eink/primary.prof
        wp_ref=$SYS/data/misc/profiles/ref/com.tencent.weread.eink/primary.prof
        wp_st=$SYS/data/local/tmp/kobo-weread-prof.stamp
        wp_now=$(date +%s 2>/dev/null || echo 0)
        wp_last=$(stat -c %Y "$wp_st" 2>/dev/null || echo 0)
        wp_csz=$(wc -c < "$wp_cur" 2>/dev/null || echo 0)
        wp_rsz=$(wc -c < "$wp_ref" 2>/dev/null || echo 0)
        if [ $((wp_now - wp_last)) -ge 86400 ] && [ "$wp_csz" -ge $((wp_rsz + 2048)) ]; then
            t "compile: charging+idle WeRead speed-profile refresh (cur=${wp_csz}B ref=${wp_rsz}B)"
            ( nice -n 19 sh "$VD/boot/weread-speed-profile.sh" >>"$LOG" 2>&1 && touch "$wp_st" || true; rm -f "$W/weread.prof.pid" ) </dev/null &
            echo $! > "$W/weread.prof.pid"
        fi
    fi
    f=$SYS/data/system/packages.list
    s=$(stat -c '%Y %s' $f 2>/dev/null) || return 0
    [ "$s" = "$(cat $W/pkglist.stamp 2>/dev/null)" ] && return 0
    echo "$s" > $W/pkglist.stamp
    compile_scan
}
compile_kick() { # 没有在跑就起一个工作进程（看门狗和 install 命令可能同时调：mkdir 当锁）
    [ -s $CQ ] || return 0
    if ! mkdir $W/compile.lock 2>/dev/null; then
        alive $W/compile.pid && return 0
        rm -rf $W/compile.lock; mkdir $W/compile.lock 2>/dev/null || return 0
    fi
    compile_worker </dev/null >>$LOG 2>&1 &
    echo $! > $W/compile.pid
}

# 安装 / 卸载应用让路：dex2oat 跑着的时候 PackageManager 一直拿着安装锁（mInstallLock），这期间的安装（传书网页、商店、apps 文件夹）
# 要等编译做完——微信读书 nice 19 下要编好几分钟，模拟器上安装等了 400 多秒，网页 10 分钟超时。
# 安装前 compile_hold：标记“有安装在等”，给已装应用编译的 dex2oat / patchoat 立刻停掉（记下包名）；工作进程看到标记就先不开始下一个。
# 安装完 compile_release：去掉标记，被打断的包强制重新排队，接着编。标记是 $W/compile.hold/<pid>，持有者死了自动失效。
# 拿着锁的不只是我们自己的 cmd package compile：Android 自己的 BackgroundDexOptService 开机 1 分钟后（应用的 odex 对不上新的
# 启动镜像时，正好是系统更新后的微信读书）和充电空闲时也会编，同样拿着安装锁，一个包接一个包。以前只在我们的工作进程在编时才动手，
# Android 自己的编译不管（PW6 5.19.5 真机：装一个小 APK 等了 99 秒）。现在按 dex2oat 编的是哪个文件判断：/data/app/<包>-N/ 下的
# （已装应用）都停掉，不管是谁发起的；安装自己的编译在 /data/app/vmdl*.tmp/ 下，不碰。持有期间有个看守进程每 0.5 秒再查一次
# （Android 的后台任务杀掉一个就接着编下一个）。被杀的 dex2oat 由 installd 自己删掉没写完的输出（Dex2oatFileWrapper 失败时 unlink），
# 包的 odex 因此没了，所以一律强制重编。
compile_preempt() { # 停掉给已安装应用编译的 dex2oat / patchoat；每个被停的包名输出一行
    for p in $(pgrep dex2oat 2>/dev/null) $(pgrep patchoat 2>/dev/null); do
        # 编的是哪个应用：命令行（--zip-location / --oat-location）加上打开的文件（patchoat 只有 fd）
        pk=$( { tr '\0' '\n' < /proc/$p/cmdline; for fd in /proc/$p/fd/*; do readlink "$fd"; done; } 2>/dev/null |
              sed -n 's#.*/data/app/\([A-Za-z0-9._]*\)-[0-9][0-9]*/.*#\1#p' | head -n 1)
        [ -n "$pk" ] || continue
        kill -9 "$p" 2>/dev/null && echo "$pk"
    done
}
compile_preempt_note() { # 把被停的包记进 compile.interrupted（compile_release 重新排队）
    for pk in "$@"; do grep -qx "$pk" $W/compile.interrupted 2>/dev/null || echo "$pk" >> $W/compile.interrupted; done
}
compile_hold() {
    mkdir -p $W/compile.hold 2>/dev/null
    read -r hp _ < /proc/self/stat; echo "$hp" > $W/compile.hold/$hp; CHOLD=$hp
    # 我们自己的工作进程在编：告诉 compile_one 这是给安装让路（记成 aborted，不是 fail，也不去补 interpret-only）
    pgrep -f "cmd package compile" >/dev/null 2>&1 && echo install > $W/compile.abort
    st=$(compile_preempt)
    if [ -n "$st" ]; then
        compile_preempt_note $st
        t "compile: stopped dexopt of $(echo $st) so an install can run (re-queued)"
    fi
    # 看守：持有期间 Android 的后台编译接着编下一个包时也停掉
    if ! alive $W/compile.guard; then
        (
            while compile_held; do
                g=$(compile_preempt)
                [ -n "$g" ] && { compile_preempt_note $g; t "compile: stopped dexopt of $(echo $g) during an install (re-queued)"; }
                usleep 500000 2>/dev/null || sleep 1
            done
            rm -f $W/compile.guard
        ) </dev/null >>$LOG 2>&1 &
        echo $! > $W/compile.guard
    fi
    [ -n "$st" ] || return 0
    # 等 PackageManager 把锁放开（cmd package compile 返回、dex2oat 都退了）：最多 10 秒
    i=0
    while [ $i -lt 50 ]; do
        pgrep -f "cmd package compile" >/dev/null 2>&1 || pgrep dex2oat >/dev/null 2>&1 || break
        usleep 200000 2>/dev/null || sleep 1; i=$((i + 1))
    done
    return 0
}
compile_held() {
    [ -d $W/compile.hold ] || return 1
    for ch_f in $W/compile.hold/*; do
        [ -f "$ch_f" ] || continue
        kill -0 "${ch_f##*/}" 2>/dev/null && return 0
        rm -f "$ch_f"
    done
    return 1
}
compile_release() {
    [ -n "$CHOLD" ] && rm -f $W/compile.hold/$CHOLD; CHOLD=
    compile_held && return 0                     # 还有别的安装在等：最后一个放开时再接着编
    if [ -s $W/compile.interrupted ]; then
        for cr_p in $(cat $W/compile.interrupted); do compile_enqueue "$cr_p" force; done
        rm -f $W/compile.interrupted
    fi
    compile_kick
}

# 电量：低于 20 % 且没在充电就暂停
compile_battery_ok() {
    b=$(kobo_battery 2>/dev/null)
    kobo_is_charging && return 0
    case "$b" in ''|*[!0-9]*) return 0 ;; esac
    # 机型文件 COMPILE_CHARGING_ONLY=1（单核老机型）：以前只在充电时编。用户报告（PW4，0.8.8）：一直用电池看书的人，应用永远
    # 不会被编（日志里每 5 分钟一条 "paused (… not charging)"，好几次开机都是），微信读书一直解释执行，“还是比较卡”。
    # 现在电池上电量够（COMPILE_BATT_MIN，默认 40 %）也编：dex2oat 仍是 nice 19 + IO 空闲、单线程，用户在用且内存紧时
    # 让路（compile_mem_need / babysit），屏保冻结时停着。COMPILE_BATT_MIN=101 = 回到只在充电时编。
    [ "$COMPILE_CHARGING_ONLY" = 1 ] && { [ "$b" -ge "${COMPILE_BATT_MIN:-40}" ]; return; }
    [ "$b" -ge 20 ]
}
mem_avail_mb() { awk '/^MemAvailable:/{a=$2} /^MemFree:/{f=$2} /^Cached:/{c=$2} END{print int((a ? a : f + c) / 1024)}' /proc/meminfo; }
# 前台应用的包名（VeraHome 写的 $X/fg；没有就空）
compile_fg() { head -n 1 $X/fg 2>/dev/null | tr -d '\r '; }
# 应用有没有进程在跑（前台、后台服务、:push / :seg 这类子进程都算）：按 packages.list 里的 uid 找 /proc（宿主看得见容器里的进程），
# 一次 awk 读完，不为每个进程 fork。dex2oat 是 installd 用 5xxxx 的共享 gid 起的，不会被算成应用自己。
# 为什么要看（0.98 门禁 PW6 模拟器 0.97 -> 0.98 第一次开机）：cmd package compile -f 先删掉应用的 odex 再从头写新的，写完前
# （dex2oat 中途崩了 / 被停掉时就一直）没有能用的 odex。已经在跑的进程手里是旧文件，不受影响；这期间新起的进程（用户点开、
# 后台服务被拉起）拿到的是没有 / 写了一半的 odex，从 apk 现解压现解释，大应用（微信读书）开不起来、反复崩。所以有进程在跑的
# 应用不编（等它退出），编着的时候它起了进程就停掉 dex2oat、重新排队。
# 这个应用现在根本没有能用的编译代码（Android 说 odex 不能用 / 过滤器是 interpret-only / 没有 odex）：它的进程本来就从 apk
# 解释执行，编着的时候新起的进程和不编时一样（都没有能用的代码），所以不用等它退出，在用着也编（COMPILE_RUNNING=auto，默认）。
# 为什么（2026-11-18 Oasis 3 用户诊断）：系统更新后微信读书的 odex 失效，speed 编译跑了 341 秒、用户一打开微信读书就停掉重排；
# 每次开机都这样，用户几分钟内就打开它，于是一直解释执行——“非常卡”。内存保护（在用时可用内存 < COMPILE_ACTIVE_ABORT_MB 就停）照旧。
# COMPILE_RUNNING=0：回到以前（在跑的应用一律不编）。
compile_nocode() { # pkg
    [ "${COMPILE_RUNNING:-auto}" != 0 ] || return 1
    [ -f $W/compile.nocode.$1 ] && return 0
    case "$(odex_filter "$1")" in ''|interpret-only|verify-none|verify-at-runtime) return 0 ;; esac
    return 1
}
compile_app_uid() { awk -v p="$1" '$1 == p { print $2; exit }' $SYS/data/system/packages.list 2>/dev/null; }
compile_app_running() { # pkg
    car_u=$(compile_app_uid "$1"); [ -n "$car_u" ] || return 1
    # 经 cat 读：busybox awk 打不开已退出进程的 status 时会提前中止导致误判
    cat /proc/[0-9]*/status 2>/dev/null | awk -v u="$car_u" '/^Uid:/ { if ($2 == u) { f = 1; exit } } END { exit !f }'
}
# 队列里只剩在跑的应用（不在前台）：用户空闲、等了 COMPILE_RUNNING_WAIT_S（默认 600）秒以后，请 Android 结束它可以安全结束的
# 进程（am kill：只杀后台 / 缓存进程，不碰前台和正在被用的服务），每个包 10 分钟最多一次。结束不了就继续等，不强编。
compile_bg_kill() { # pkg...
    for cbk_p in "$@"; do
        cbk_f=$W/compile.runwait.$cbk_p
        [ -f "$cbk_f" ] || { : > "$cbk_f"; continue; }
        compile_user_active && continue
        [ $(( $(date +%s) - $(stat -c %Y "$cbk_f" 2>/dev/null || date +%s) )) -ge ${COMPILE_RUNNING_WAIT_S:-600} ] || continue
        touch "$cbk_f"
        adb_sh "am kill $cbk_p" >/dev/null 2>&1
        t "compile: $cbk_p kept running in the background, asked Android to end its background processes (am kill)$(compile_app_running "$cbk_p" && echo ", still running: waiting")"
    done
}
# 多久没摸屏（秒）。$W/lastinput 不存在（这次开机还没摸过、或手势全关所以没有 poke）按空闲算
compile_idle_s() {
    l=$(stat -c %Y $W/lastinput 2>/dev/null) || { echo 999999; return 0; }
    d=$(( $(date +%s) - l )); [ $d -lt 0 ] && d=0; echo $d
}
compile_user_active() { [ "$(compile_idle_s)" -lt "${COMPILE_IDLE_S:-300}" ]; }
compile_charging() { kobo_is_charging; }
# 开始编之前要有的可用内存（MB）：dex2oat 编一个大应用（微信读书 ~25 MB dex）要 150–250 MB。
# 用户正在用：要求高得多（编译不能把前台应用挤进 zram），512 MB 机型按比例减半
compile_mem_need() {
    if compile_user_active; then
        if lowmem_ram; then echo ${COMPILE_ACTIVE_MB_LOW:-200}; else echo ${COMPILE_ACTIVE_MB:-400}; fi
    else
        if lowmem_ram; then echo ${COMPILE_MIN_MB_LOW:-120}; else echo ${COMPILE_MIN_MB:-180}; fi
    fi
}
compile_mem_ok() { [ "$(mem_avail_mb)" -ge "$(compile_mem_need)" ]; }
# 编着的时候用户在用、可用内存掉到这以下：停掉，等空闲再编
compile_active_abort_mb() { if lowmem_ram; then echo ${COMPILE_ACTIVE_ABORT_MB_LOW:-100}; else echo ${COMPILE_ACTIVE_ABORT_MB:-200}; fi; }
# 只停给某一个包编译的 dex2oat / patchoat。返回 0 = 真的停掉了至少一个；1 = 一个也没找到 / 没杀掉
compile_preempt_pkg() { # pkg
    cpp_r=1
    for p in $(pgrep dex2oat 2>/dev/null) $(pgrep patchoat 2>/dev/null); do
        pk=$( { tr '\0' '\n' < /proc/$p/cmdline; for fd in /proc/$p/fd/*; do readlink "$fd"; done; } 2>/dev/null |
              sed -n 's#.*/data/app/\([A-Za-z0-9._]*\)-[0-9][0-9]*/.*#\1#p' | head -n 1)
        [ "$pk" = "$1" ] && kill -9 "$p" 2>/dev/null && cpp_r=0
    done
    return $cpp_r
}
# babysit 决定停掉这个包的编译：停到了才记原因（compile.abort）、算 killed；没停到下一轮再试
compile_babysit_stop() { # 原因 包 日志
    if compile_preempt_pkg "$2"; then
        t "$3"; echo "$1" > $W/compile.abort; killed=$1
    elif [ "$cbs_miss" != "$1" ]; then
        cbs_miss=$1; t "compile: wanted to stop dexopt of $2 ($1) but found no dex2oat / patchoat for it yet, retrying"
    fi
}
# dex2oat 是 Android 的 installd 起的，不是我们的子进程：自己的 nice 管不到它。编译期间每 2 秒把所有
# dex2oat 线程调成 nice 19 + IO 空闲（ionice -c3；没有 ionice 就只调 nice）。内存低到危险时直接杀掉 dex2oat：
# 编译失败只是应用继续用解释执行，总比让 lowmemorykiller 杀前台应用或让机器换页卡死好。
compile_babysit() { # cmd 的 pid [包]
    killed=; cbs_miss=; t0=$(cut -d. -f1 /proc/uptime)
    # 没有能用代码的应用（compile_nocode，开始编之前判断：-f 一开始就把旧 odex 删了）：到了前台 / 起了进程也不停
    nocode=; [ -n "$2" ] && [ -f $W/compile.nocode_now ] && nocode=1
    while kill -0 "$1" 2>/dev/null; do
        # 已经决定停：cmd 还没返回时每一轮都再停一次这个包的 dex2oat / patchoat，不记日志
        [ -n "$2" ] && [ -n "$killed" ] && [ "$killed" != memory ] && compile_preempt_pkg "$2"
        # 正在编的应用被打开到了前台：停掉，等它离开前台再编（compile_one 重新排队）
        if [ -n "$2" ] && [ -z "$killed" ] && [ -z "$nocode" ] && [ "$(compile_fg)" = "$2" ]; then
            compile_babysit_stop foreground "$2" "compile: $2 came to the foreground, stopping its dexopt (will finish after it leaves the foreground)"
        fi
        # 编着的时候这个应用起了进程（点开了 / 后台服务被拉起）：它拿到的是没写完的 odex，停掉，等它退出再编
        if [ -n "$2" ] && [ -z "$killed" ] && [ -z "$nocode" ] && compile_app_running "$2"; then
            compile_babysit_stop running "$2" "compile: $2 started while it was being compiled, stopping its dexopt (will finish after it exits)"
        fi
        # 用户在用、内存紧：停掉，等空闲再编
        if [ -n "$2" ] && [ -z "$killed" ] && compile_user_active && [ "$(mem_avail_mb)" -lt "$(compile_active_abort_mb)" ]; then
            compile_babysit_stop busy "$2" "compile: device in use and only $(mem_avail_mb) MB available, stopping dexopt of $2 (will retry when idle)"
        fi
        # 自己的超时（默认 540 秒，小于 PackageManager 10 分钟看门狗）：超时后无论前面有没有停过都强杀
        if [ $(( $(cut -d. -f1 /proc/uptime) - t0 )) -ge ${COMPILE_MAX_S:-540} ]; then
            cbs_k=
            for p in $(pgrep dex2oat 2>/dev/null) $(pgrep patchoat 2>/dev/null); do kill -9 "$p" 2>/dev/null && cbs_k=1; done
            if [ -z "$killed" ]; then
                t "compile: still running after ${COMPILE_MAX_S:-540}s, aborting dex2oat"
                killed=timeout; echo timeout > $W/compile.abort
            elif [ -n "$cbs_k" ] && [ "$cbs_miss" != timeout ]; then
                cbs_miss=timeout; t "compile: dex2oat still running ${COMPILE_MAX_S:-540}s after start although stopped ($killed), killed again"
            fi
        fi
        for p in $(pgrep dex2oat 2>/dev/null); do
            for tk in /proc/$p/task/*; do
                tid=${tk##*/}
                renice -n 19 -p "$tid" >/dev/null 2>&1
                command -v ionice >/dev/null 2>&1 && ionice -c 3 -p "$tid" >/dev/null 2>&1
            done
            if [ "$(mem_avail_mb)" -lt "${COMPILE_ABORT_MB:-40}" ] && [ -z "$killed" ]; then
                t "compile: memory critically low ($(mem_avail_mb) MB available), aborting dex2oat $p"
                kill -9 "$p" 2>/dev/null && { killed=memory; echo memory > $W/compile.abort; }
            fi
        done
        sleep 2
    done
}
# 编译期间硬链接保住原来的 odex / art，避免后台编译时打开应用触发 ClassNotFoundException 或退回解释执行
compile_oat_dir() { # pkg -> 宿主路径 $SYS/data/app/<包>-N/oat/<isa>
    cod_d=$(app_dir "$1") || return 1
    for cod_i in arm arm64; do
        [ -d "$SYS/data/app/$cod_d/oat/$cod_i" ] && { echo "$SYS/data/app/$cod_d/oat/$cod_i"; return 0; }
    done
    return 1
}
compile_elf_ok() { [ -s "$1" ] && [ "$(dd if="$1" bs=4 count=1 2>/dev/null | tail -c 3)" = ELF ]; }
compile_keep_begin() { # pkg
    ckb_o=$(compile_oat_dir "$1") || return 1
    rm -f "$ckb_o"/.vd-keep.* "$ckb_o"/.vd-new.* "$ckb_o"/.vd-tmp.* 2>/dev/null
    compile_elf_ok "$ckb_o/base.odex" || return 1
    ln -f "$ckb_o/base.odex" "$ckb_o/.vd-keep.odex" 2>/dev/null || return 1
    [ -f "$ckb_o/base.art" ] && ln -f "$ckb_o/base.art" "$ckb_o/.vd-keep.art" 2>/dev/null
    echo "$ckb_o"
}
compile_keep_put() { # dir ext
    if [ -f "$1/.vd-keep.$2" ]; then
        [ "$1/base.$2" -ef "$1/.vd-keep.$2" ] && return 0
        ln -f "$1/.vd-keep.$2" "$1/.vd-tmp.$2" && mv -f "$1/.vd-tmp.$2" "$1/base.$2"
    else rm -f "$1/base.$2"; fi
}
compile_keep_divert() { # dir ext
    [ -f "$1/base.$2" ] || return 1
    [ -f "$1/.vd-keep.$2" ] && [ "$1/base.$2" -ef "$1/.vd-keep.$2" ] && return 1
    [ -f "$1/.vd-new.$2" ] && [ "$1/base.$2" -ef "$1/.vd-new.$2" ] && { compile_keep_put "$1" "$2"; return 0; }
    ln -f "$1/base.$2" "$1/.vd-new.$2" 2>/dev/null || return 1
    compile_keep_put "$1" "$2"
}
compile_keep_guard() { # cmd 的 pid  oat 目录  输出文件
    while kill -0 "$1" 2>/dev/null; do
        compile_keep_divert "$2" odex; compile_keep_divert "$2" art
        [ -f "$2/.vd-new.odex" ] && [ ! -f "$2/base.odex" ] && compile_keep_put "$2" odex
        usleep 200000 2>/dev/null || sleep 1
    done
    compile_keep_end "$2" "$3"
}
compile_keep_end() { # oat 目录  输出文件
    compile_keep_divert "$1" odex; compile_keep_divert "$1" art
    if grep -q Success "$2" 2>/dev/null && compile_elf_ok "$1/.vd-new.odex"; then
        mv -f "$1/.vd-new.odex" "$1/base.odex"
        if [ -f "$1/.vd-new.art" ]; then mv -f "$1/.vd-new.art" "$1/base.art"; else rm -f "$1/base.art"; fi
        touch -r "$1/../../base.apk" "$1/base.odex" 2>/dev/null
        t "compile: new odex of ${1#$SYS/data/app/} in place, the old one was kept until it was complete"
    elif [ -f "$1/.vd-new.odex" ]; then
        compile_keep_put "$1" odex; compile_keep_put "$1" art
        t "compile: compile of ${1#$SYS/data/app/} did not finish, the previous odex is back in place"
    else
        compile_keep_put "$1" odex; [ -f "$1/.vd-keep.art" ] && compile_keep_put "$1" art
    fi
    rm -f "$1"/.vd-keep.* "$1"/.vd-new.* "$1"/.vd-tmp.* 2>/dev/null
}
compile_pm_start() { # pkg 输出文件 cmd 参数...
    cps_p=$1; cps_out=$2; shift 2
    cps_o=$(compile_keep_begin "$cps_p")
    adb_sh "cmd package compile $*" > "$cps_out" 2>&1 &
    cp_=$!; cpg_=
    if [ -n "$cps_o" ]; then compile_keep_guard $cp_ "$cps_o" "$cps_out" </dev/null >>$LOG 2>&1 & cpg_=$!; fi
}
compile_pm_wait() {
    wait $cp_; cpw_r=$?
    [ -n "$cpg_" ] && wait $cpg_
    return $cpw_r
}
compile_keep_cleanup() {
    for ckc_k in $SYS/data/app/*/oat/*/.vd-keep.odex $SYS/data/app/*/oat/*/.vd-new.odex; do
        [ -f "$ckc_k" ] || continue
        ckc_o=${ckc_k%/*}; ckc_p=${ckc_o#$SYS/data/app/}; ckc_p=${ckc_p%%/*}; ckc_p=${ckc_p%-*}
        compile_dex2oat_for "$ckc_p" && continue
        if [ -f "$ckc_o/.vd-keep.odex" ] && ! { compile_elf_ok "$ckc_o/base.odex" && ! [ "$ckc_o/base.odex" -ef "$ckc_o/.vd-new.odex" ]; }; then
            compile_keep_put "$ckc_o" odex; compile_keep_put "$ckc_o" art
            t "compile: ${ckc_o#$SYS/data/app/}: put the previous odex back after an unfinished compile"
        fi
        rm -f "$ckc_o"/.vd-keep.* "$ckc_o"/.vd-new.* "$ckc_o"/.vd-tmp.* 2>/dev/null
    done
}
compile_dex2oat_for() { # pkg
    for p in $(pgrep dex2oat 2>/dev/null) $(pgrep patchoat 2>/dev/null); do
        tr '\0' '\n' < /proc/$p/cmdline 2>/dev/null | grep -q "/data/app/$1-[0-9]*/" && return 0
    done
    return 1
}
compile_light() { # pkg [timeout]
    rf=interpret-only
    [ "$2" = timeout ] && [ -s "$SYS/data/misc/profiles/cur/0/$1/primary.prof" ] && rf=speed-profile
    compile_low_big "$1" && rf=verify-at-runtime
    compile_pm_start "$1" $W/compile.light.out -m $rf -f "$1"
    compile_babysit $cp_ "$1"; compile_pm_wait
}
compile_restore_next() {
    [ -s $W/compile.restore ] || return 1
    crn_fg=$(compile_fg); crn_p=
    for crn_q in $(cat $W/compile.restore); do
        if ! app_dir "$crn_q" >/dev/null || [ -n "$(odex_filter "$crn_q")" ]; then
            sed -i "/^$crn_q\$/d" $W/compile.restore; continue
        fi
        [ "$crn_q" = "$crn_fg" ] && continue
        compile_app_running "$crn_q" && continue
        crn_p=$crn_q; break
    done
    [ -n "$crn_p" ] || return 1
    rm -f $W/compile.abort
    if compile_nocode "$crn_p"; then : > $W/compile.nocode_now; else rm -f $W/compile.nocode_now; fi
    crn_s=$(cut -d. -f1 /proc/uptime)
    crn_t=$(adb_sh "getprop dalvik.vm.dex2oat-threads" 2>/dev/null | tr -d '\r\n')
    if lowmem_ram || compile_user_active || ! compile_charging; then adb_sh "setprop dalvik.vm.dex2oat-threads 1" >/dev/null 2>&1; fi
    compile_light "$crn_p"
    adb_sh "setprop dalvik.vm.dex2oat-threads '$crn_t'" >/dev/null 2>&1
    crn_f=$(odex_filter "$crn_p"); crn_a=$(cat $W/compile.abort 2>/dev/null)
    t "compile: $crn_p had no odex after an aborted compile, restored to ${crn_f:-none} ($rf, $(( $(cut -d. -f1 /proc/uptime) - crn_s ))s${crn_a:+, aborted: $crn_a})"
    [ -n "$crn_f" ] || [ -z "$crn_a" ] && sed -i "/^$crn_p\$/d" $W/compile.restore
    rm -f $W/compile.abort $W/compile.nocode_now
    return 0
}
compile_one() { # pkg mode force
    pkg=$1; mode=$2
    dir=$(app_dir "$pkg") || return 1
    rm -f $W/compile.abort
    # dex2oat 线程数：只有充电 + 空闲（不在用）时用系统默认（最快）；用户在用或用电池时单线程（内存峰值低很多、
    # 不和前台抢 CPU）；512 MB 机型一律单线程。COMPILE_THREADS 可以强制指定。编完恢复。
    thr=${COMPILE_THREADS:-}
    if [ -z "$thr" ]; then
        if lowmem_ram || compile_user_active || ! compile_charging; then thr=1; fi
    fi
    othr=$(adb_sh "getprop dalvik.vm.dex2oat-threads" 2>/dev/null | tr -d '\r\n')
    [ -n "$thr" ] && adb_sh "setprop dalvik.vm.dex2oat-threads $thr" >/dev/null 2>&1
    # dex2oat 自带看门狗：9.5 分钟没编完就自杀，超时由 compile_babysit 自己管。
    oflags=$(adb_sh "getprop dalvik.vm.dex2oat-flags" 2>/dev/null | tr -d '\r\n')
    case "$oflags" in *--no-watch-dog*) ;; '') adb_sh "setprop dalvik.vm.dex2oat-flags --no-watch-dog" >/dev/null 2>&1 ;;
        *) adb_sh "setprop dalvik.vm.dex2oat-flags '$oflags --no-watch-dog'" >/dev/null 2>&1 ;; esac
    s=$(cut -d. -f1 /proc/uptime)
    if compile_nocode "$pkg"; then : > $W/compile.nocode_now; else rm -f $W/compile.nocode_now; fi
    compile_pm_start "$pkg" $W/compile.out -m $mode -f $pkg
    compile_babysit $cp_ "$pkg"
    compile_pm_wait; rc=$?
    sec=$(( $(cut -d. -f1 /proc/uptime) - s ))
    f=$(odex_filter "$pkg")
    ab=$(cat $W/compile.abort 2>/dev/null)
    if [ "$f" = "$mode" ] && grep -q Success $W/compile.out; then r=ok
    elif [ "$ab" = install ]; then r=aborted
    elif [ "$ab" = foreground ] || [ "$ab" = running ] || [ "$ab" = busy ]; then r=aborted
    elif [ "$ab" = timeout ]; then r=timeout
    elif grep -q "Can't find service" $W/compile.out || ! alive $W/pid; then r=aborted
    elif [ -n "$f" ] && grep -q Success $W/compile.out; then r=capped
    else r=fail; fi
    case "$oflags" in *--no-watch-dog*) ;; *) adb_sh "setprop dalvik.vm.dex2oat-flags '$oflags'" >/dev/null 2>&1 ;; esac
    if { [ $r = fail ] || [ $r = timeout ]; } && ! compile_held && { [ -n "$nocode" ] || ! compile_app_running "$pkg"; } &&
       { [ -z "$f" ] || { [ $r = timeout ] && [ "$f" != speed-profile ] && [ -s "$SYS/data/misc/profiles/cur/0/$pkg/primary.prof" ]; }; }; then
        compile_light "$pkg" $r
        t "compile: $pkg restored to $(odex_filter "$pkg") ($rf)"
    fi
    case "$ab" in foreground|running|busy)
        [ $r = aborted ] && [ -z "$f" ] && { grep -qx "$pkg" $W/compile.restore 2>/dev/null || echo "$pkg" >> $W/compile.restore; } ;;
    esac
    [ -n "$thr" ] && adb_sh "setprop dalvik.vm.dex2oat-threads '$othr'" >/dev/null 2>&1
    [ $r = ok ] && rm -f $W/compile.nocode.$pkg
    t "compile: $pkg -m $mode -> $r$( [ -f $W/compile.nocode_now ] && echo " (had no usable code: compiled while in use)") (filter=${f:-none}, ${sec}s, rc=$rc$( [ -f $W/compile.abort ] && echo ", aborted: $(cat $W/compile.abort)"): $(tr '\n' ' ' < $W/compile.out | cut -c1-120))"
    { tail -n 199 $CLOG 2>/dev/null; echo "$pkg $dir $r $mode ${sec}s $(date +%Y%m%d-%H%M%S)"; } > $CLOG.tmp 2>/dev/null && mv -f $CLOG.tmp $CLOG
    echo "$pkg $r $sec" > $W/compile.last
    [ $r = ok ] || case "$ab" in
        foreground|running|busy)
            sed -i "/^$pkg\( \|\$\)/d" $CQ 2>/dev/null; echo "$pkg force" >> $CQ
            echo $(( $(cat $W/compile.total 2>/dev/null || echo 0) + 1 )) > $W/compile.total
            [ "$ab" = busy ] && : > $W/compile.needidle ;;
    esac
    [ "$r" != fail ]
}
compile_nap() { # 秒
    cn_i=0
    while [ $cn_i -lt "$1" ]; do
        alive $W/pid && [ ! -f $W/compile.quit ] || return 1
        sleep 5; cn_i=$((cn_i + 5))
    done
    return 0
}
compile_worker() {
    trap 'rm -f $W/compile.pid; rm -rf $W/compile.lock' EXIT
    compile_keep_cleanup
    idx=$(cat $W/compile.index 2>/dev/null || echo 0); gaveup=
    while [ -s $CQ ]; do
        alive $W/pid || break
        mode=$(compile_mode)
        [ -n "$mode" ] || { compile_status state=paused reason=off "total=$(cat $W/compile.total 2>/dev/null)"; rm -f $CQ; break; }
        last=$(cat $W/compile.last 2>/dev/null)
        if compile_held; then compile_status state=waiting reason=install "index=$idx" "total=$(cat $W/compile.total 2>/dev/null)" "last=$last"; compile_nap 5 || break; continue; fi
        if [ -f $W/frozen ] || [ -f $W/saver_frozen ]; then compile_status state=waiting reason=frozen "index=$idx" "total=$(cat $W/compile.total)" "last=$last"; compile_nap 30 || break; continue; fi
        if ! compile_battery_ok; then compile_status state=paused reason=battery "index=$idx" "total=$(cat $W/compile.total)" "last=$last" "msg=电量低，应用优化暂停：充电或电量回到 $( [ "$COMPILE_CHARGING_ONLY" = 1 ] && echo ${COMPILE_BATT_MIN:-40} || echo 20) % 以上会继续（没优化完的应用会慢一些）"; t "compile: paused (battery $(kobo_battery 2>/dev/null)%, not charging, need $( [ "$COMPILE_CHARGING_ONLY" = 1 ] && echo ${COMPILE_BATT_MIN:-40} || echo 20)%)"; compile_nap 300 || break; continue; fi
        tot=$(cat $W/compile.total 2>/dev/null)
        if [ -f $W/compile.needidle ] && compile_user_active; then
            compile_status state=waiting reason=你在用机器，等空闲时再优化 code=busy "index=$idx" "total=$tot" "last=$last" "msg=你在用机器，等空闲时再优化"; compile_nap 30 || break; continue
        fi
        if alive $W/aot.pid; then compile_status state=waiting reason=正在优化桌面，稍后继续 code=busy "index=$idx" "total=$(cat $W/compile.total 2>/dev/null)" "last=$last" "msg=正在优化桌面，稍后继续"; compile_nap 5 || break; continue; fi
        fg=$(compile_fg); line=; crun=
        while read -r cl_p cl_f; do
            [ -n "$cl_p" ] || continue
            if [ "$cl_p" = "$fg" ] || compile_app_running "$cl_p"; then
                compile_nocode "$cl_p" && { line="$cl_p${cl_f:+ $cl_f}"; break; }
                [ "$cl_p" = "$fg" ] && continue
                crun="$crun $cl_p"; continue
            fi
            line="$cl_p${cl_f:+ $cl_f}"; break
        done < $CQ
        if [ -z "$line" ] && [ -n "$crun" ]; then
            compile_bg_kill $crun
            cr1=${crun# }; cr1=${cr1%% *}
            compile_status state=waiting reason=等应用退出后再优化 code=running "pkg=$cr1" "index=$idx" "total=$tot" "last=$last" "msg=等应用退出后再优化"
            compile_nap 30 || break; continue
        fi
        if [ -z "$line" ]; then
            compile_status state=waiting reason=等你不用这个应用时再优化 code=foreground "pkg=$fg" "index=$idx" "total=$tot" "last=$last" "msg=等你不用这个应用时再优化"
            compile_nap 10 || break; continue
        fi
        if ! compile_mem_ok; then
            if compile_user_active; then
                compile_status state=waiting reason=你在用机器、内存不多，等空闲时再优化 code=busy "index=$idx" "total=$tot" "last=$last" "msg=你在用机器、内存不多，等空闲时再优化"
                compile_nap 30 || break; continue
            fi
            compile_status state=waiting reason=memory "index=$idx" "total=$tot" "last=$last"
            if [ -n "$crun" ]; then compile_bg_kill $crun; compile_nap 30 || break; continue; fi
            n=$(( $(cat $W/compile.memwait 2>/dev/null || echo 0) + 1 )); echo $n > $W/compile.memwait
            if [ $n -ge 20 ]; then
                t "compile: not enough free memory for 10 min ($(mem_avail_mb) MB), retrying in 30 min"
                rm -f $W/compile.memwait; echo $(( $(cut -d. -f1 /proc/uptime) + 1800 )) > $W/compile.retry_at
                compile_status state=paused reason=memory "index=$idx" "total=$tot" "last=$last"; gaveup=1; break
            fi
            compile_nap 30 || break; continue
        fi
        rm -f $W/compile.memwait
        compile_restore_next && continue
        set -- $line; pkg=$1; force=$2
        sed -i "/^$pkg\( \|\$\)/d" $CQ
        compile_needed "$pkg" "$force" || continue
        rm -f $W/compile.runwait.$pkg
        compile_user_active || rm -f $W/compile.needidle
        idx=$((idx + 1)); echo $idx > $W/compile.index
        compile_status state=running "pkg=$pkg" "index=$idx" "total=$tot" "last=$last"
        compile_one "$pkg" "$(compile_pkg_mode "$pkg" "$mode")"
    done
    [ -n "$gaveup" ] && return 0
    compile_status state=idle "last=$(cat $W/compile.last 2>/dev/null)" "done=$idx"
    [ -s $CQ ] || rm -f $W/compile.total $W/compile.index
}
# 命令：compile all | compile <包>
# 用户明确要求的编译在 APP_COMPILE=off 时也做（子 shell 里临时改成 speed，不影响命令监听进程自己的设置）
compile_cmd() {
    case "$1" in all) ;; *[!A-Za-z0-9._]*|'') return 1 ;; esac
    (
        [ -n "$(compile_mode)" ] || APP_COMPILE=speed
        if [ "$1" = all ]; then for p in $(data_pkgs); do compile_enqueue "$p"; done
        else compile_enqueue "$1" force; fi
        compile_kick
    )
}
