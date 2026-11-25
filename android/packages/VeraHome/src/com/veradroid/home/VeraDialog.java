// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.app.Activity;
import android.app.Dialog;
import android.graphics.Color;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** All VeraDroid dialogs are drawn here: white paper, thin black frame, no Holo/Material. */
final class VeraDialog {
    interface OnPick { void onPick(int index); }

    static final class Builder {
        private final Activity a;
        private String title, message, negative, positive;
        private String[] items;
        private int selected = -1;
        private View extra;
        private OnPick pick;
        private Runnable negativeAction, positiveAction;

        Builder(Activity a) { this.a = a; }

        Builder title(String s) { title = s; return this; }
        Builder message(String s) { message = s; return this; }
        Builder view(View v) { extra = v; return this; }
        Builder items(String[] s, OnPick p) { items = s; pick = p; return this; }
        Builder selected(int i) { selected = i; return this; }
        Builder negative(String label, Runnable action) { negative = label; negativeAction = action; return this; }
        Builder positive(String label, Runnable action) { positive = label; positiveAction = action; return this; }

        Dialog show() {
            final Dialog d = new Dialog(a);
            d.requestWindowFeature(Window.FEATURE_NO_TITLE);
            d.setCanceledOnTouchOutside(true);

            LinearLayout box = new LinearLayout(a);
            box.setOrientation(LinearLayout.VERTICAL);
            box.setPadding(dp(22), dp(18), dp(22), dp(16));
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(Color.WHITE);
            bg.setStroke(2, Color.BLACK);
            bg.setCornerRadius(dp(4));
            box.setBackground(bg);
            // 方块风格：对话框也是直角双线框 + 投影，选项是直角框，选中的黑底
            final boolean blk = Blocks.on(a);
            if (blk) {
                box.setBackground(Blocks.frameDouble(a));
                box.setPadding(dp(22), dp(18), dp(22) + Blocks.shade(a), dp(16) + Blocks.shade(a));
            }

            if (title != null && title.length() > 0) {
                TextView t = Ui.text(a, title, 24, true);
                t.setPadding(0, 0, 0, dp(6));
                box.addView(t);
            }
            if (message != null && message.length() > 0) {
                TextView m = Ui.text(a, message, 16, false);
                m.setTextColor(Blocks.on(a) ? Color.BLACK : Color.DKGRAY);   // 方块风格只用纯黑白
                m.setPadding(0, dp(4), 0, dp(12));
                // 长错误文案（如安装/更新失败堆栈）放入限高滚动容器，防止把底部「知道了」按钮挤出屏幕
                if (message.length() > 140 || message.indexOf('\n') >= 0) {
                    final int maxH = Math.max(dp(180), (int) (a.getResources().getDisplayMetrics().heightPixels * 0.50f));
                    PageScrollView msv = new PageScrollView(a) {
                        @Override protected void onMeasure(int ws, int hs) {
                            int mode = MeasureSpec.getMode(hs);
                            int sz = MeasureSpec.getSize(hs);
                            int cap = (mode == MeasureSpec.UNSPECIFIED) ? maxH : Math.min(sz, maxH);
                            super.onMeasure(ws, MeasureSpec.makeMeasureSpec(cap, MeasureSpec.AT_MOST));
                        }
                    };
                    msv.addView(m, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
                    box.addView(msv, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
                } else {
                    box.addView(m);
                }
            }
            if (extra != null) {
                // 闪烁的光标会让墨水屏每 0.5 秒刷一小块：对话框里的输入框一律不显示光标
                if (extra instanceof EditText) ((EditText) extra).setCursorVisible(false);
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                lp.bottomMargin = dp(12);
                box.addView(extra, lp);
            }
            if (items != null) {
                for (int i = 0; i < items.length; i++) {
                    final int at = i;
                    TextView b = Ui.text(a, items[i], 17, i == selected);
                    b.setGravity(Gravity.CENTER_VERTICAL);
                    b.setPadding(dp(14), dp(13), dp(14), dp(13));
                    b.setBackground(blk ? (i == selected ? Blocks.plainFilled(a) : Blocks.plain(a)) : Ui.frame(a, i == selected));
                    if (i == selected) b.setTextColor(Color.WHITE);
                    b.setOnClickListener(new View.OnClickListener() {
                        @Override public void onClick(View v) {
                            d.dismiss();
                            if (pick != null) pick.onPick(at);
                        }
                    });
                    LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                    lp.topMargin = dp(5);
                    box.addView(b, lp);
                }
            }

            if (negative != null || positive != null) {
                LinearLayout row = new LinearLayout(a);
                row.setGravity(Gravity.END);
                row.setPadding(0, dp(14), 0, 0);
                if (negative != null) {
                    View b = Ui.button(a, negative, 16, false, new View.OnClickListener() {
                        @Override public void onClick(View v) { d.dismiss(); if (negativeAction != null) negativeAction.run(); }
                    });
                    if (blk) b.setBackground(Blocks.plain(a));
                    row.addView(b);
                }
                if (positive != null) {
                    View b = Ui.button(a, positive, 16, true, new View.OnClickListener() {
                        @Override public void onClick(View v) { d.dismiss(); if (positiveAction != null) positiveAction.run(); }
                    });
                    if (blk) b.setBackground(Blocks.plainFilled(a));
                    row.addView(b);
                }
                box.addView(row);
            }

            PageScrollView sv = new PageScrollView(a);
            sv.setBackgroundColor(Color.TRANSPARENT);
            sv.addView(box, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            d.setContentView(sv);
            d.show();
            Window w = d.getWindow();
            if (w != null) {
                w.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
                w.setWindowAnimations(0);
                w.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);   // 墨水屏不压暗背景，黑框已经够清楚
                int width = (int) (a.getResources().getDisplayMetrics().widthPixels * 0.86);
                w.setLayout(width, ViewGroup.LayoutParams.WRAP_CONTENT);
                w.setGravity(Gravity.CENTER);
            }
            return d;
        }

        private int dp(int v) { return Ui.dp(a, v); }
    }
}
