// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.os.BatteryManager;
import android.os.Handler;
import android.os.IBinder;
import android.util.Log;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * Kobo 风格的状态栏：顶部一条很窄的白条，左边时间、右边电量，点一下打开下拉面板。
 * 只在“设置 → 桌面 → 状态栏”打开时显示；桌面和面板自己已经有顶栏，所以它们在前台时隐藏。
 * 用 TYPE_PHONE 覆盖在别的 App 上；需要 SYSTEM_ALERT_WINDOW（安装后用 appops 放行）。
 */
public class StatusBarService extends Service {
    private static final String TAG = "VeraStatusBar";
    private static boolean suppressed = false;   // Home / Panel 在前台时为 true
    private static boolean appSuppressed = false; // 自带顶栏的应用（如微信读书）在前台时为 true
    private WindowManager wm;
    private View bar;
    private TextView clock, batt;
    private Icons.IconView btIcon, wifiIcon;
    private CtlWatch.Listener statusWatch;
    private final Handler handler = new Handler();
    private final Runnable tick = new Runnable() {
        @Override public void run() {
            if (suppressed || appSuppressed) { hide(); return; }
            refreshNow();
            handler.postDelayed(this, toNextMinute());
        }
    };

    /** 系统的分钟广播 / 改时间 / 改时区 / 电量与充电变化：马上刷新。 */
    private final BroadcastReceiver timeReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) {
            if (suppressed || appSuppressed) return;
            String act = i != null ? i.getAction() : null;
            if (Intent.ACTION_BATTERY_CHANGED.equals(act)
                    || Intent.ACTION_POWER_CONNECTED.equals(act)
                    || Intent.ACTION_POWER_DISCONNECTED.equals(act)) {
                refreshNow();
            } else {
                handler.removeCallbacks(tick);
                tick.run();
            }
        }
    };
    private boolean timeReceiverOn;

    /** 时间只显示到分钟：在整分钟后一点点更新。以前固定每 2 分钟一次，时间最多慢 2 分钟（应用里看到 04:13，其实已经 04:14 多）。 */
    private static long toNextMinute() { return 60000 - System.currentTimeMillis() % 60000 + 300; }

    public static void start(Context c) { c.startService(new Intent(c, StatusBarService.class)); }
    public static void stop(Context c) { c.stopService(new Intent(c, StatusBarService.class)); }
    public static void setSuppressed(boolean v) { suppressed = v; }
    public static void setAppSuppressed(Context c, boolean v) {
        if (appSuppressed == v) return;
        appSuppressed = v;
        refresh(c);
    }
    public static void refresh(Context c) { c.startService(new Intent(c, StatusBarService.class)); }

    @Override public IBinder onBind(Intent i) { return null; }
    @Override public int onStartCommand(Intent i, int flags, int startId) {
        boolean on = Store.prefs(this, "home").getBoolean("statusbar", true);
        if (!on) { hide(); stopSelf(); return START_NOT_STICKY; }
        handler.removeCallbacks(tick);
        if (suppressed || appSuppressed) {
            hide();
            return START_STICKY;
        }
        refreshNow();
        handler.postDelayed(tick, toNextMinute());
        if (!timeReceiverOn) {
            IntentFilter tf = new IntentFilter(Intent.ACTION_TIME_TICK);
            tf.addAction(Intent.ACTION_TIME_CHANGED); tf.addAction(Intent.ACTION_TIMEZONE_CHANGED);
            tf.addAction(Intent.ACTION_BATTERY_CHANGED);
            tf.addAction(Intent.ACTION_POWER_CONNECTED); tf.addAction(Intent.ACTION_POWER_DISCONNECTED);
            try { registerReceiver(timeReceiver, tf); timeReceiverOn = true; } catch (Throwable ignored) { }
        }
        if (statusWatch == null) {
            statusWatch = new CtlWatch.Listener() {
                @Override public void onCtl(String path) {
                    if (!"status".equals(path)) return;
                    handler.post(new Runnable() { @Override public void run() { if (!suppressed && !appSuppressed) refreshNow(); } });
                }
            };
            CtlWatch.add(statusWatch);
        }
        return START_STICKY;
    }

    private boolean enabled() {
        return Store.prefs(this, "home").getBoolean("statusbar", true);
    }

    private void refreshNow() {
        if (!enabled() || suppressed || appSuppressed) { hide(); return; }
        if (bar != null && builtBlocks != Blocks.on(this)) hide();   // 界面风格换了：按新风格重搭这一条
        show();
        // 主题：statusbar.json 可以关掉时间/电量、改时间格式、在左边加一段文字
        org.json.JSONObject cfg = Theme.statusBar();
        if (clock != null) {
            String fmt = cfg.optString("clock_format", Ui.clockPattern(this));
            String now;
            try { now = new SimpleDateFormat(fmt, Locale.CHINA).format(new Date()); }
            catch (Throwable t) { now = new SimpleDateFormat("HH:mm", Locale.CHINA).format(new Date()); }
            String text = cfg.optString("text", "").trim();
            if (!cfg.optBoolean("clock", true)) now = "";
            String clockText = text.length() == 0 ? now : now.length() == 0 ? text : text + "   " + now;
            if (!clockText.equals(String.valueOf(clock.getText()))) clock.setText(clockText);
        }
        java.util.Map<String, String> st = HostLink.kv(HostLink.CTL + "status");
        if (btIcon != null) {
            boolean btOn = "1".equals(st.get("bton"));
            int bvis = btOn ? View.VISIBLE : View.GONE;
            if (btIcon.getVisibility() != bvis) btIcon.setVisibility(bvis);
        }
        if (wifiIcon != null) {
            String lanip = st.get("lanip");
            boolean wifiOn = "1".equals(st.get("wifi")) && lanip != null && lanip.trim().length() > 0;
            int wvis = wifiOn ? View.VISIBLE : View.GONE;
            if (wifiIcon.getVisibility() != wvis) wifiIcon.setVisibility(wvis);
        }
        if (batt != null) batt.setVisibility(cfg.optBoolean("battery", true) ? View.VISIBLE : View.GONE);
        if (batt != null) {
            int p = -1;
            boolean charging = false;
            int[] live = Ui.liveBattery(this);
            if (live != null) {
                p = live[0];
                charging = live[1] == 1;
            } else {
                try {
                    BatteryManager bm = (BatteryManager) getSystemService(BATTERY_SERVICE);
                    if (bm != null) {
                        p = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
                        charging = bm.isCharging();
                    }
                } catch (Throwable ignored) { }
            }
            if (p > 100) p = 100;
            boolean usbConn = "1".equals(st.get("usbconn"));
            String btAudio = st.get("btaudio");
            boolean hasAudio = btAudio != null && btAudio.trim().length() > 0;
            String battText = (hasAudio ? "♪ " : "") + (usbConn ? "USB  " : "") + (p >= 0 ? (charging ? "充电中 " + p + "%" : p + "%") : "");
            if (!battText.equals(String.valueOf(batt.getText()))) batt.setText(battText);
            Stats.sampleBattery(this, p, charging);
        }
    }

    private boolean builtBlocks;

    private void show() {
        if (bar != null) return;
        wm = (WindowManager) getSystemService(WINDOW_SERVICE);
        builtBlocks = Blocks.on(this);
        LinearLayout wrap = new LinearLayout(this);
        wrap.setOrientation(LinearLayout.VERTICAL);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setBackgroundColor(Color.WHITE);
        row.setPadding(dp(8), 0, dp(4), 0);
        clock = Ui.text(this, "", 13, true);
        batt = Ui.text(this, "", 11, false);
        // 不抗锯齿：状态栏每分钟只刷时钟那一小块，用的是 DU（只有黑白两级）+ 抖动。抗锯齿字边上的灰点被抖成斜纹，
        // 每分钟换一次图案，看起来就是“左上角斜着闪”（PW6 真机：每 60 s 一次 24x22 的 DU，就是分钟那一位）。纯黑白的字 DU 刷出来和原图一样。
        for (TextView tv : new TextView[] { clock, batt }) { tv.getPaint().setAntiAlias(false); tv.getPaint().setSubpixelText(false); }
        row.addView(clock, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1));
        btIcon = new Icons.IconView(this, Icons.Kind.BLUETOOTH);
        LinearLayout.LayoutParams btp = new LinearLayout.LayoutParams(dp(13), dp(13));
        btp.rightMargin = dp(5);
        btIcon.setVisibility(View.GONE);
        row.addView(btIcon, btp);
        wifiIcon = new Icons.IconView(this, Icons.Kind.WIFI);
        LinearLayout.LayoutParams wp = new LinearLayout.LayoutParams(dp(13), dp(13));
        wp.rightMargin = dp(6);
        wifiIcon.setVisibility(View.GONE);
        row.addView(wifiIcon, wp);
        row.addView(batt, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.MATCH_PARENT));
        // 状态栏只有 20dp 高。以前用 14dp 的线条箭头（﹀）：线只有 2 像素，墨水屏抖动后又淡又细，看起来像残缺的，
        // 还贴着屏幕右边。改成实心倒三角 ▼（14dp 宽、8dp 高），离右边 10dp；整行仍然都能点开面板。
        View chev = new View(this) {
            private final android.graphics.Paint fill = new android.graphics.Paint();   // 不抗锯齿，理由同上
            private final android.graphics.Path tri = new android.graphics.Path();
            @Override protected void onDraw(android.graphics.Canvas c) {
                float w = getWidth(), h = getHeight();
                fill.setColor(Color.BLACK);
                fill.setStyle(android.graphics.Paint.Style.FILL);
                tri.reset();
                tri.moveTo(0, 0);
                tri.lineTo(w, 0);
                tri.lineTo(w / 2f, h);
                tri.close();
                c.drawPath(tri, fill);
            }
        };
        LinearLayout.LayoutParams cp = new LinearLayout.LayoutParams(dp(12), dp(6));
        cp.leftMargin = dp(10); cp.rightMargin = dp(10);
        if (builtBlocks) {
            // 方块风格：只有时间和电量（粗体），右边留出同样的边距；底下一条实心黑线（2 像素以上，不是会抖成虚线的 1 像素）
            Fonts.apply(batt, true);
            batt.setTextSize(12);
            batt.setPadding(0, 0, dp(8), 0);
        } else row.addView(chev, cp);
        // Click or short pull-down both open the panel.  There is no black
        // divider rule: on e-ink a 1px rule reads as a thick, broken line.
        row.setOnTouchListener(new View.OnTouchListener() {
            private float downY;
            private boolean dragging;
            @Override public boolean onTouch(View v, MotionEvent e) {
                switch (e.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                        downY = e.getRawY(); dragging = false; return true;
                    case MotionEvent.ACTION_MOVE:
                        if (e.getRawY() - downY > dp(8)) dragging = true;
                        return true;
                    case MotionEvent.ACTION_UP:
                        if (dragging || e.getRawY() - downY > dp(8)) openPanel();
                        else openPanel();
                        return true;
                }
                return false;
            }
        });
        wrap.addView(row, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, builtBlocks ? dp(18) - Blocks.stroke(this) : dp(18)));
        if (builtBlocks) wrap.addView(Ui.rule(this, Blocks.stroke(this), Color.BLACK));
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(18),
                WindowManager.LayoutParams.TYPE_PHONE,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        try {
            wm.addView(wrap, lp);
            bar = wrap;
        } catch (Throwable t) {
            Log.w(TAG, "cannot add status bar: " + t);
            bar = null;
        }
    }

    private void hide() {
        if (bar == null) return;
        try { wm.removeView(bar); } catch (Throwable ignored) { }
        bar = null;
        wifiIcon = null;
    }

    private void openPanel() {
        Perf.begin();
        Panel.open(this);
    }

    private int dp(int v) { return Ui.dp(this, v); }

    @Override public void onDestroy() {
        handler.removeCallbacks(tick);
        if (statusWatch != null) { CtlWatch.remove(statusWatch); statusWatch = null; }
        if (timeReceiverOn) { try { unregisterReceiver(timeReceiver); } catch (Throwable ignored) { } timeReceiverOn = false; }
        hide();
        super.onDestroy();
    }
}
