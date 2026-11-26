# SPDX-License-Identifier: GPL-3.0-or-later
# 冻结 / 解冻：cgroup v1 freezer。启动脚本自己先进组再 fork，容器所有进程从一开始就在组里，
# fork 完立刻回到根组（否则 stop.sh 之类跑在这个组里会被自己冻住）。
# 内核没有 freezer（PW4 / Oasis 3 的 4.1 内核）时退回信号模式：对容器 PID 命名空间里的
# 所有进程发 SIGSTOP / SIGCONT。$FZ 仍建成普通目录，调用方用 [ -d $FZ ] 判断能否冻结。
# 息屏回调可能在 freezer_cleanup 或 /dev/shm 被清掉之后仍触发（用户日志 43312552302：
# can't create .../freezer/vd/freezer.state: nonexistent directory）——freeze/thaw 前一律确保目录在。
freezer_setup() {
    mkdir -p $W/freezer
    if grep -qw freezer /proc/cgroups 2>/dev/null; then
        grep -q " $W/freezer " /proc/mounts || mount -t cgroup -o freezer freezer $W/freezer || return 1
        echo cgroup > $W/fzmode
    else
        echo signal > $W/fzmode
    fi
    mkdir -p $FZ
}
fz_signal() { [ "$(cat $W/fzmode 2>/dev/null)" = signal ]; }
freezer_enter() { freezer_setup || return 1; fz_signal || echo $$ > $FZ/tasks; }
freezer_leave() { fz_signal || echo $$ > $W/freezer/tasks; }
freezer_state() {
    if fz_signal; then cat $FZ/state 2>/dev/null || echo THAWED
    else cat $FZ/freezer.state 2>/dev/null; fi
}
# 容器里的所有进程：和容器 init（$W/pid）同一个 PID 命名空间
ns_pids() {
    [ "$(cat $W/mode 2>/dev/null)" = chroot ] && { chroot_pids; return 0; }   # 没有 PID 命名空间：按根目录认
    ip=$(cat $W/pid 2>/dev/null); [ -n "$ip" ] || return 0
    ns=$(readlink /proc/$ip/ns/pid 2>/dev/null); [ -n "$ns" ] || return 0
    for d in /proc/[0-9]*; do
        [ "$(readlink $d/ns/pid 2>/dev/null)" = "$ns" ] && echo ${d#/proc/}
    done
}
# slirp4netns（namespace 模式才有；chroot 模式走宿主网络）在 Android 冻结期间也停下：容器里开着的 TCP 连接让它每 0.5 秒醒一次。
net_pause()  { sp=$(cat $W/slirp.pid 2>/dev/null); [ -n "$sp" ] && kill -STOP "$sp" 2>/dev/null; return 0; }
net_resume() { sp=$(cat $W/slirp.pid 2>/dev/null); [ -n "$sp" ] && kill -CONT "$sp" 2>/dev/null; return 0; }
# 触摸前端（veradroid-input）：Android 里所有按下的触点都抬起。冻结前 / 解冻前各发一次：冻结期间或之前
# 被手势吞掉的触摸不会在解冻后变成永远按着的触点。写 inject FIFO 用 1<>：没人读也不会阻塞；veradroid-input 没在跑就不写。
vinput_reset() {
    pid=$(cat "$W/input.pid" 2>/dev/null)
    [ -p "$W/inject" ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 0
    echo "reset ${1:-host}" 1<>"$W/inject" 2>/dev/null
    return 0
}
android_freeze() {
    freezer_setup || return 1
    vinput_reset freeze
    # sync 不再挡在冻结前面：真机上它要等镜像文件的脏页全部写完（几十秒），屏保 / 返回 Kindle 都被它拖住。
    # 进程停住以后不会再有新的脏页，放到后台写，结果一样。
    ( sync ) </dev/null >/dev/null 2>&1 &
    if fz_signal; then
        kill -STOP $(ns_pids) 2>/dev/null
        echo FROZEN > $FZ/state
        net_pause
        cpu_gov_set powersave 2>/dev/null || true
        return 0
    fi
    wd_release 2>/dev/null
    echo FROZEN > $FZ/freezer.state
    cpu_gov_set powersave 2>/dev/null || true
    i=0; while [ "$(freezer_state)" != FROZEN ] && [ $i -lt 50 ]; do usleep 100000; i=$((i + 1)); done
    [ "$(freezer_state)" = FROZEN ] && net_pause
    [ "$(freezer_state)" = FROZEN ]
}
android_thaw() {
    vinput_reset thaw
    cpu_gov_restore 2>/dev/null || true
    net_resume
    freezer_setup || return 1
    if fz_signal; then
        kill -CONT $(ns_pids) 2>/dev/null
        echo THAWED > $FZ/state
        return 0
    fi
    wd_hold
    echo THAWED > $FZ/freezer.state
    wd_release_later
}
# BH081-5：冻结期间 CLOCK_MONOTONIC 照走。system_server 的 Watchdog 线程一解冻就看到“检查已发出 >60 秒还没完成”，
# 判 OVERDUE 直接杀 system_server（“WATCHDOG KILLING SYSTEM PROCESS: Blocked in handler on ActivityManager”），
# Android 软重启：返回 Kindle 超过 1 分钟再打开，应用全没了、要重新开机 2–6 分钟。
# 解法：解冻前把名为 watchdog 的那个线程单独放进自冻结的子组 $FZ/wd，先解冻其余线程，
# 4 秒后各 Handler 已经跑完积压的检查消息（mCompleted=true），再把它放回去。stop.sh 停 Android 时不分步（要尽快杀掉）。
# 兜底日志：freeze.sh 也会被 stop.sh / sleep.sh 单独 source，那时 common.sh 的 t() 未必已定义
type t >/dev/null 2>&1 || t() { echo "[$(date +%H:%M:%S) up=$(cut -d' ' -f1 /proc/uptime)] $*" >> "${LOG:-/tmp/veradroid.log}" 2>/dev/null; }
wd_hold() {
    case "$0" in *stop.sh) return 0 ;; esac
    [ -d $FZ/wd ] && return 0
    case "$(cat $FZ/freezer.state 2>/dev/null)" in FROZEN|FREEZING) ;; *) return 0 ;; esac
    ss=; for p in $(cat $FZ/cgroup.procs 2>/dev/null); do
        [ "$(cat /proc/$p/comm 2>/dev/null)" = system_server ] && { ss=$p; break; }
    done
    [ -n "$ss" ] || return 0
    wt=; for d in /proc/$ss/task/*; do
        [ "$(cat $d/comm 2>/dev/null)" = watchdog ] && { wt=${d##*/}; break; }
    done
    [ -n "$wt" ] || return 0
    mkdir $FZ/wd 2>/dev/null || return 0
    if echo FROZEN > $FZ/wd/freezer.state 2>/dev/null && echo $wt > $FZ/wd/tasks 2>/dev/null; then
        t "thaw: system_server watchdog thread $wt held 4s"
    else
        rmdir $FZ/wd 2>/dev/null; return 0
    fi
}
# 把 wd 子组里的线程放回 $FZ（随父组状态：父组已解冻就解冻，又被冻上就保持冻结），删掉子组
wd_release() {
    [ -d $FZ/wd ] || return 0
    for x in $(cat $FZ/wd/tasks 2>/dev/null); do echo $x > $FZ/tasks 2>/dev/null; done
    echo THAWED > $FZ/wd/freezer.state 2>/dev/null
    rmdir $FZ/wd 2>/dev/null || true
}
wd_release_later() {
    [ -d $FZ/wd ] || return 0
    ( sleep 4; wd_release; t "thaw: watchdog thread released" ) </dev/null >>"${LOG:-/tmp/veradroid.log}" 2>&1 &
}
freezer_cleanup() {
    wd_release 2>/dev/null
    if fz_signal; then
        [ -d $FZ ] && { android_thaw 2>/dev/null; rm -f $FZ/state; rmdir $FZ 2>/dev/null; }
    else
        [ -d $FZ ] && { echo THAWED > $FZ/freezer.state 2>/dev/null; rmdir $FZ 2>/dev/null; }
        grep -q " $W/freezer " /proc/mounts && umount $W/freezer 2>/dev/null
    fi
    rmdir $W/freezer 2>/dev/null
    rm -f $W/fzmode
}
