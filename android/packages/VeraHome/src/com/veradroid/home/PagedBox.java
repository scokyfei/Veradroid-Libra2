// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.content.Context;
import android.view.MotionEvent;
import android.view.ViewConfiguration;
import android.widget.LinearLayout;

/**
 * 一页内容的容器：手指在上面横着或竖着划一段，抬手时翻一页（左划 / 上划 = 下一页），和 Kobo 书库一样。
 * 不跟手、不滚动、没有惯性：墨水屏上只换一次画面。划动时里面的格子收不到点击。
 */
class PagedBox extends LinearLayout {
    interface Listener { void onPage(int dir); }

    private Listener listener;
    private final int slop;
    private float downX, downY;
    private boolean swiping;

    PagedBox(Context c) {
        super(c);
        slop = ViewConfiguration.get(c).getScaledTouchSlop() * 3;
    }

    void setListener(Listener l) { listener = l; }

    @Override public boolean onInterceptTouchEvent(MotionEvent e) {
        switch (e.getActionMasked()) {
        case MotionEvent.ACTION_DOWN:
            downX = e.getX(); downY = e.getY(); swiping = false;
            return false;
        case MotionEvent.ACTION_MOVE:
            if (Math.abs(e.getX() - downX) > slop || Math.abs(e.getY() - downY) > slop) { swiping = true; return true; }
            return false;
        }
        return false;
    }

    @Override public boolean onTouchEvent(MotionEvent e) {
        switch (e.getActionMasked()) {
        case MotionEvent.ACTION_DOWN:
            downX = e.getX(); downY = e.getY(); swiping = false;
            return true;
        case MotionEvent.ACTION_MOVE:
            if (Math.abs(e.getX() - downX) > slop || Math.abs(e.getY() - downY) > slop) swiping = true;
            return true;
        case MotionEvent.ACTION_UP:
            if (swiping && listener != null) {
                float dx = e.getX() - downX, dy = e.getY() - downY;
                float main = Math.abs(dx) >= Math.abs(dy) ? dx : dy;
                final int dir = main < 0 ? 1 : -1;
                final Listener l = listener;
                // 翻页会 removeAllViews 重搭格子：排到这次触摸分发之后（见 Ui.clickAfterDispatch）
                if (!post(new Runnable() { @Override public void run() { l.onPage(dir); } })) l.onPage(dir);
            }
            swiping = false;
            return true;
        case MotionEvent.ACTION_CANCEL:
            swiping = false;
            return true;
        }
        return true;
    }
}
