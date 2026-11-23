// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.hardware.input.InputManager;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.LinearLayout;

import java.lang.reflect.Method;

/**
 * 传统“三大金刚键”导航栏：屏幕底部 返回 / 主页 / 多任务。
 * 用 overscan 把底部这一条从应用的显示区域里让出来，所以不会挡住应用自己的底栏（比如微信读书的工具栏）。
 * 设置 → 桌面 → 导航方式 里打开；prefs "navmode"：0 手势，1 三大金刚键，2 两者都要。
 */
public class NavBarService extends Service {
    private static final String TAG = "VeraNavBar";
    private static final int TYPE_NAVIGATION_BAR = 2019; // WindowManager.LayoutParams.TYPE_NAVIGATION_BAR (@hide in SDK)
    static final int HEIGHT_DP = 28;   // 24 → 28：三个键按得更准（用户反馈“有点小”）
    private WindowManager wm;
    private View bar;

    static int mode(Context c) { return Store.prefs(c, "home").getInt("navmode", 0); }

    static void apply(Context c) {
        Intent i = new Intent(c, NavBarService.class);
        if (mode(c) == 0) { c.stopService(i); clearStaleOverscan(c); } else c.startService(i);
    }

    private boolean overscanUsed;
    private int builtDpi;
    private int retries;
    private boolean destroyed;

    @Override public void onConfigurationChanged(android.content.res.Configuration c) {
        super.onConfigurationChanged(c);
        if (bar instanceof android.widget.FrameLayout && c.densityDpi != builtDpi && !overscanUsed) {
            builtDpi = c.densityDpi;
            android.widget.FrameLayout f = (android.widget.FrameLayout) bar;
            f.removeAllViews();
            f.addView(build(LinearLayout.LayoutParams.MATCH_PARENT));
        }
    }

    @Override public IBinder onBind(Intent i) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (mode(this) == 0) { stopSelf(); return START_NOT_STICKY; }
        show();
        return START_STICKY;
    }

    private void show() {
        if (bar != null || destroyed) return;
        wm = (WindowManager) getSystemService(WINDOW_SERVICE);
        builtDpi = getResources().getConfiguration().densityDpi;
        clearStaleOverscan(this);
        android.widget.FrameLayout sys = new android.widget.FrameLayout(this);
        sys.setBackgroundColor(Color.WHITE);
        sys.addView(build(LinearLayout.LayoutParams.MATCH_PARENT));
        WindowManager.LayoutParams sl = new WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT,
            TYPE_NAVIGATION_BAR,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_TOUCHABLE_WHEN_WAKING
                | WindowManager.LayoutParams.FLAG_SPLIT_TOUCH,
            PixelFormat.OPAQUE);
        sl.gravity = Gravity.BOTTOM | Gravity.LEFT;
        sl.windowAnimations = 0;
        sl.setTitle("VeraNavBar");
        try {
            wm.addView(sys, sl);
            bar = sys;
            return;
        } catch (Throwable t) {
            if (String.valueOf(t.getMessage()).contains("already exists") && retries++ < 3) {
                Log.w(TAG, "nav bar window still there, retrying: " + t);
                new android.os.Handler().postDelayed(new Runnable() { @Override public void run() { show(); } }, 700);
                return;
            }
            Log.w(TAG, "TYPE_NAVIGATION_BAR not allowed, falling back to overscan: " + t);
        }
        showOverscan();
    }

    private View build(int h) {
        LinearLayout wrap = new LinearLayout(this);
        wrap.setOrientation(LinearLayout.VERTICAL);
        wrap.setBackgroundColor(Color.WHITE);
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.addView(button(Icons.Kind.BACK, new Runnable() { @Override public void run() { key(KeyEvent.KEYCODE_BACK); } }),
            new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1));
        row.addView(button(Icons.Kind.HOME, new Runnable() { @Override public void run() { home(); } }),
            new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1));
        row.addView(button(Icons.Kind.SWITCH, new Runnable() { @Override public void run() { recents(); } }),
            new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1));
        wrap.addView(row, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, h));
        return wrap;
    }

    private void showOverscan() {
        int h = Ui.dp(this, HEIGHT_DP);
        View wrap = build(h);
        WindowManager.LayoutParams lp = new WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, h,
            WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_OVERSCAN,
            PixelFormat.OPAQUE);
        android.util.DisplayMetrics real = new android.util.DisplayMetrics();
        wm.getDefaultDisplay().getRealMetrics(real);
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        lp.y = real.heightPixels - h;
        try {
            setOverscanBottom(h);
            overscanUsed = true;
            wm.addView(wrap, lp);
            bar = wrap;
        } catch (Throwable t) {
            Log.w(TAG, "cannot add nav bar: " + t);
            setOverscanBottom(0);
            overscanUsed = false;
        }
    }

    private View button(Icons.Kind k, final Runnable r) {
        LinearLayout b = new LinearLayout(this);
        b.setGravity(Gravity.CENTER);
        android.graphics.drawable.StateListDrawable bg = new android.graphics.drawable.StateListDrawable();
        bg.addState(new int[] { android.R.attr.state_pressed }, new android.graphics.drawable.ColorDrawable(Color.BLACK));
        b.setBackground(bg);
        b.addView(new Icons.IconView(this, k), new LinearLayout.LayoutParams(Ui.dp(this, 19), Ui.dp(this, 19)));
        b.setClickable(true);
        b.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { r.run(); } });
        return b;
    }

    private void key(int code) {
        try {
            InputManager im = (InputManager) getSystemService(Context.INPUT_SERVICE);
            Method m = InputManager.class.getMethod("injectInputEvent", InputEvent.class, int.class);
            long now = SystemClock.uptimeMillis();
            for (int action : new int[] { KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP }) {
                KeyEvent e = new KeyEvent(now, now, action, code, 0, 0, KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                    KeyEvent.FLAG_FROM_SYSTEM | KeyEvent.FLAG_VIRTUAL_HARD_KEY, InputDevice.SOURCE_KEYBOARD);
                m.invoke(im, e, 0);   // INJECT_INPUT_EVENT_MODE_ASYNC
            }
        } catch (Throwable t) { Log.w(TAG, "inject key failed: " + t); }
    }

    private void home() {
        startActivity(HomeActivity.homeIntent(this));
    }

    private void recents() {
        Intent i = new Intent(this, SwitcherActivity.class);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        startActivity(i);
    }

    static void clearStaleOverscan(Context c) {
        try {
            android.view.Display d = ((WindowManager) c.getSystemService(WINDOW_SERVICE)).getDefaultDisplay();
            Class<?> dic = Class.forName("android.view.DisplayInfo");
            Object info = dic.newInstance();
            android.view.Display.class.getMethod("getDisplayInfo", dic).invoke(d, info);
            int l = dic.getField("overscanLeft").getInt(info), t = dic.getField("overscanTop").getInt(info);
            int r = dic.getField("overscanRight").getInt(info), b = dic.getField("overscanBottom").getInt(info);
            if (b == 0) return;
            Log.i(TAG, "clearing stale overscan " + l + "," + t + "," + r + "," + b);
            Class<?> g = Class.forName("android.view.WindowManagerGlobal");
            Object wms = g.getMethod("getWindowManagerService").invoke(null);
            wms.getClass().getMethod("setOverscan", int.class, int.class, int.class, int.class, int.class)
                .invoke(wms, 0, l, t, r, 0);
        } catch (Throwable t) { Log.w(TAG, "overscan check failed: " + t); }
    }

    /** IWindowManager.setOverscan(display 0, 0, 0, 0, bottom): apps lay out above the bar instead of under it. */
    private void setOverscanBottom(int px) {
        try {
            Class<?> g = Class.forName("android.view.WindowManagerGlobal");
            Object wms = g.getMethod("getWindowManagerService").invoke(null);
            wms.getClass().getMethod("setOverscan", int.class, int.class, int.class, int.class, int.class)
                .invoke(wms, 0, 0, 0, 0, px);
        } catch (Throwable t) { Log.w(TAG, "setOverscan failed: " + t); }
    }

    @Override public void onDestroy() {
        destroyed = true;
        if (bar != null) {
            try { wm.removeViewImmediate(bar); } catch (Throwable ignored) { }
            bar = null;
        }
        if (overscanUsed) { setOverscanBottom(0); overscanUsed = false; }
        super.onDestroy();
    }
}
