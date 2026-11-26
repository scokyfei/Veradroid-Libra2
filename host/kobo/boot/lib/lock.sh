# 锁屏密码（VeraHome 的 LockScreen.java）。密码只以加盐哈希存在 Android 私有目录里；
# 宿主只做两件事：
#   lock_request      屏保前 / 醒来后让桌面盖上锁屏（ctl/act.lock；没设密码时桌面什么都不做）
#   lock_reset_check  用户忘了密码：在 Kobo 盘根目录或 .adds/Veradroid-Libra2/ 放 reset-pin.txt，
#                     下次启动 / 屏保醒来时删掉它并写 ctl/lock.reset，桌面清掉密码。
lock_request() { [ -d $X/ctl ] && : > $X/ctl/act.lock 2>/dev/null; return 0; }
lock_reset_check() {
    for f in /mnt/onboard/reset-pin.txt /mnt/onboard/RESET-PIN.txt /mnt/onboard/reset-pin.txt.txt \
             "$VD/reset-pin.txt" "$VD/reset-pin" "$VD/RESET-PIN.txt" "$VD/reset-pin.txt.txt"; do
        [ -e "$f" ] || continue
        rm -f "$f"
        [ -d $X/ctl ] && : > $X/ctl/lock.reset 2>/dev/null
        t "lock: reset file found ($f), asking VeraHome to clear the PIN"
        return 0
    done
    return 0
}
