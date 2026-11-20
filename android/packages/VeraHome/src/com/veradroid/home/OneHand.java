package com.veradroid.home;

import android.app.Activity;
import android.graphics.Color;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 单手模式（设置 → 桌面 → 单手模式，偏好 onehand，默认关）。
 *
 * 只动主页：开着时顶栏（回 Kobo / 搜索 / 快捷设置 / 菜单）和应用网格整体移到屏幕下半部分，上面空出来的地方
 * 放一个大的“下拉面板”按钮（亮度、Wi-Fi、刷新……不用再伸到最上边去划）。网格行数按剩下的高度自己重算，
 * 一页少几个应用，翻页照旧。不做动画、不跟手，开关一次只重搭一次主页。
 */
final class OneHand {
    private OneHand() { }

    static final String KEY = "onehand";

    static boolean on(Activity a) { return Store.prefs(a, "home").getBoolean(KEY, false); }

    /** 主页最上面插的那一块（占屏幕高度的 40%）。关着时返回 null，什么都不加。 */
    static View topSpacer(final Activity a) {
        if (!on(a)) return null;
        LinearLayout box = new LinearLayout(a);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER);
        box.setBackgroundColor(Color.WHITE);
        int h = a.getResources().getDisplayMetrics().heightPixels * 2 / 5;
        box.setLayoutParams(new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, h));
        TextView hint = Ui.text(a, "单手模式：常用按钮在下半屏", 17, false);
        hint.setGravity(Gravity.CENTER);
        hint.setPadding(0, Ui.dp(a, 4), 0, Ui.dp(a, 16));
        box.addView(hint);
        android.widget.Button pull = Ui.button(a, "打开下拉面板", 22, false, new View.OnClickListener() {
            @Override public void onClick(View v) { Panel.open(a); }
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(a.getResources().getDisplayMetrics().widthPixels * 2 / 3, Ui.dp(a, 72));
        box.addView(pull, lp);
        return box;
    }
}
