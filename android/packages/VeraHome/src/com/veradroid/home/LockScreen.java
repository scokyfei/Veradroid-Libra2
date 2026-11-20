package com.veradroid.home;

import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.security.SecureRandom;

import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

/**
 * 锁屏密码（docs/host-settings.md 第 9 节）：4–6 位数字，可选，默认关。
 *
 * 什么时候问：Android 开机后桌面第一次起来（HostService.onCreate），和每次从 Kobo 屏保醒来（宿主 sleep.sh 进屏保前、
 * 醒来后各写一次 ctl/act.lock）。界面是一个盖住全屏的悬浮窗（TYPE_SYSTEM_ERROR，比状态栏、下拉面板、导航条都高），
 * 底下的应用不知道它在；“回到 Kobo”按钮、宿主的手势（四角长按回 Kobo）和电源键都不经过这里，照常有效。
 *
 * 存在哪：VeraHome 自己的私有目录（设备加密区，/data/user_de/0/com.veradroid.home/shared_prefs/lock.xml），
 * 只存随机盐和 PBKDF2-SHA1（20000 轮）的结果，不存密码本身。别的应用读不到；/sdcard/.vdhome 里的偏好别的应用能读，所以不放那里。
 *
 * 输错：连续错 5 次，30 秒内不让再输（时间存在文件里，重启 Android 也不清零）；之后每再错 5 次又等 30 秒。
 *
 * 忘了：没有账号可以找回。插 USB，在 Kobo 存储的 veradroid 文件夹里放一个名为 reset-pin.txt 的文件（内容随意），
 * 再打开 VeraDroid（或从屏保醒来）：宿主（lib/lock.sh）删掉这个文件并写 ctl/lock.reset，这里清掉密码。
 */
final class LockScreen {
    private LockScreen() { }

    static final int MIN = 4, MAX = 6;
    private static final int ITER = 20000;
    private static final int TRIES = 5;
    private static final long WAIT_MS = 30000;

    private static View view;
    private static final Handler H = new Handler(Looper.getMainLooper());

    static SharedPreferences prefs(Context c) {
        Context d = c.getApplicationContext();
        try { d = d.createDeviceProtectedStorageContext(); } catch (Throwable ignored) { }
        return d.getSharedPreferences("lock", Context.MODE_PRIVATE);
    }

    static boolean enabled(Context c) { return prefs(c).getString("hash", null) != null; }

    static boolean set(Context c, String pin) {
        if (!valid(pin)) return false;
        byte[] salt = new byte[16];
        new SecureRandom().nextBytes(salt);
        String h = hash(pin, salt);
        if (h == null) return false;
        return prefs(c).edit().putString("salt", hex(salt)).putString("hash", h).putInt("len", pin.length())
            .putInt("fails", 0).putLong("until", 0).commit();
    }

    static void clear(Context c) {
        prefs(c).edit().clear().commit();
        hide();
    }

    static boolean valid(String pin) { return pin != null && pin.length() >= MIN && pin.length() <= MAX && pin.matches("[0-9]+"); }

    /** 对就把错误次数清零；错就记一次（满 5 次开始等 30 秒）。在等待中一律算错，不去比对。 */
    static boolean check(Context c, String pin) {
        SharedPreferences p = prefs(c);
        if (waitMs(c) > 0) return false;
        String salt = p.getString("salt", null), want = p.getString("hash", null);
        if (salt == null || want == null) return true;
        String got = hash(pin, unhex(salt));
        if (got != null && slowEquals(got, want)) { p.edit().putInt("fails", 0).putLong("until", 0).commit(); return true; }
        int f = p.getInt("fails", 0) + 1;
        SharedPreferences.Editor e = p.edit().putInt("fails", f);
        if (f % TRIES == 0) e.putLong("until", System.currentTimeMillis() + WAIT_MS);
        e.commit();
        return false;
    }

    static int fails(Context c) { return prefs(c).getInt("fails", 0); }

    /** 还要等多久（毫秒）。时钟被往回拨时最多也只等 30 秒。 */
    static long waitMs(Context c) {
        long until = prefs(c).getLong("until", 0), now = System.currentTimeMillis();
        if (until <= now) return 0;
        return Math.min(until - now, WAIT_MS);
    }

    static boolean showing() { return view != null; }

    private static String hash(String pin, byte[] salt) {
        try {
            SecretKeyFactory f = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1");
            byte[] k = f.generateSecret(new PBEKeySpec(pin.toCharArray(), salt, ITER, 256)).getEncoded();
            return hex(k);
        } catch (Exception e) {
            android.util.Log.w("VeraHome", "lock hash: " + e);
            return null;
        }
    }

    private static boolean slowEquals(String a, String b) {
        if (a.length() != b.length()) return false;
        int d = 0;
        for (int i = 0; i < a.length(); i++) d |= a.charAt(i) ^ b.charAt(i);
        return d == 0;
    }

    private static String hex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(String.format("%02x", x & 0xff));
        return s.toString();
    }

    private static byte[] unhex(String s) {
        byte[] b = new byte[s.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return b;
    }

    // ---- 全屏悬浮窗 ------------------------------------------------------------------------------------------------

    static void hide() {
        if (view == null) return;
        try { ((WindowManager) view.getContext().getSystemService(Context.WINDOW_SERVICE)).removeView(view); } catch (Throwable ignored) { }
        view = null;
    }

    /** 设了密码而且还没盖上：盖上。只在主线程调。 */
    static void show(Context ctx) {
        final Context c = ctx.getApplicationContext();
        if (view != null || !enabled(c)) return;
        Panel.close();
        final StringBuilder typed = new StringBuilder();
        final int len = prefs(c).getInt("len", 0);
        final int sw = c.getResources().getDisplayMetrics().widthPixels, sh = c.getResources().getDisplayMetrics().heightPixels;

        LinearLayout root = new LinearLayout(c) {
            // 返回键、菜单键都吃掉：不能靠返回键把锁屏关掉
            @Override public boolean dispatchKeyEvent(KeyEvent e) {
                int k = e.getKeyCode();
                if (k == KeyEvent.KEYCODE_BACK || k == KeyEvent.KEYCODE_MENU || k == KeyEvent.KEYCODE_SEARCH) return true;
                return super.dispatchKeyEvent(e);
            }
        };
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.WHITE);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setFocusable(true);
        root.setFocusableInTouchMode(true);
        int pad = Ui.dp(c, 24);
        root.setPadding(pad, sh / 14, pad, pad);

        if (Blocks.on(c)) {   // 方块风格：标题上面一行英文小字（键盘按钮由 Ui.button 画成直角框）
            TextView cap = Blocks.cap(c, "Locked");
            cap.setGravity(Gravity.CENTER);
            root.addView(cap);
        }
        TextView title = Ui.text(c, "输入锁屏密码", 30, true);
        title.setGravity(Gravity.CENTER);
        root.addView(title);
        final TextView dots = Ui.text(c, "", 40, true);
        dots.setGravity(Gravity.CENTER);
        dots.setPadding(0, Ui.dp(c, 18), 0, Ui.dp(c, 6));
        root.addView(dots, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        final TextView msg = Ui.text(c, "", 18, false);
        msg.setGravity(Gravity.CENTER);
        msg.setPadding(0, 0, 0, Ui.dp(c, 18));
        root.addView(msg, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        final Runnable[] render = new Runnable[1];
        render[0] = new Runnable() {
            @Override public void run() {
                StringBuilder d = new StringBuilder();
                int n = Math.max(len, typed.length());
                for (int i = 0; i < n; i++) { if (i > 0) d.append(' '); d.append(i < typed.length() ? '*' : '_'); }
                dots.setText(d.length() == 0 ? " " : d.toString());
                long w = waitMs(c);
                if (w > 0) {
                    msg.setText("已连续输错 " + fails(c) + " 次，请 " + ((w + 999) / 1000) + " 秒后再试");
                    // 不倒计时（墨水屏上每秒刷一次不值得）：到点只改一次字
                    H.postDelayed(render[0], w + 100);
                } else {
                    int f = fails(c);
                    msg.setText(f > 0 ? "密码不对（已错 " + f + " 次，连续错 " + TRIES + " 次要等 30 秒）" : "忘了密码：见“设置 - 设备与更新 - 锁屏密码”里的说明");
                }
            }
        };

        final Runnable submit = new Runnable() {
            @Override public void run() {
                if (typed.length() < MIN) return;
                String pin = typed.toString();
                typed.setLength(0);
                if (check(c, pin)) { H.removeCallbacks(render[0]); hide(); return; }
                render[0].run();
            }
        };

        int keyH = Math.max(Ui.dp(c, 64), sh / 10), keyW = Math.min((sw - 2 * pad) / 3 - Ui.dp(c, 12), Ui.dp(c, 200));
        String[] keys = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "删除", "0", "确定" };
        for (int r = 0; r < 4; r++) {
            LinearLayout row = new LinearLayout(c);
            row.setGravity(Gravity.CENTER);
            for (int k = 0; k < 3; k++) {
                final String key = keys[r * 3 + k];
                Button b = Ui.button(c, key, key.length() == 1 ? 32 : 22, key.equals("确定"), new View.OnClickListener() {
                    @Override public void onClick(View v) {
                        if (waitMs(c) > 0) { render[0].run(); return; }
                        if (key.equals("删除")) { if (typed.length() > 0) typed.setLength(typed.length() - 1); }
                        else if (key.equals("确定")) { submit.run(); return; }
                        else if (typed.length() < MAX) typed.append(key);
                        // 长度和设的一样就直接比对，不用再点“确定”
                        if (len > 0 && typed.length() == len) { submit.run(); return; }
                        render[0].run();
                    }
                });
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(keyW, keyH);
                lp.setMargins(Ui.dp(c, 6), Ui.dp(c, 6), Ui.dp(c, 6), Ui.dp(c, 6));
                row.addView(b, lp);
            }
            root.addView(row);
        }

        View gap = new View(c);
        root.addView(gap, new LinearLayout.LayoutParams(1, 0, 1));
        // 回 Kobo 不需要密码（Kobo 那边有它自己的锁屏）；宿主的手势和电源键本来就不经过这里
        Button exit = Ui.button(c, "回到 Kobo", 20, false, new View.OnClickListener() {
            @Override public void onClick(View v) { HostLink.cmd("exit"); }
        });
        root.addView(exit, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, Math.max(Ui.dp(c, 56), sh / 16)));

        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.TYPE_SYSTEM_ERROR,
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_FULLSCREEN
                | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED,
            PixelFormat.OPAQUE);
        lp.windowAnimations = 0;
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        lp.setTitle("VeraLock");
        try {
            ((WindowManager) c.getSystemService(Context.WINDOW_SERVICE)).addView(root, lp);
            view = root;
            root.requestFocus();
            render[0].run();
        } catch (Throwable t) {
            android.util.Log.w("VeraHome", "lock overlay: " + t);
            view = null;
        }
    }
}
