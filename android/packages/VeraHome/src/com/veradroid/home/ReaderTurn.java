package com.veradroid.home;

/**
 * 阅读器在整本书分完页之前的翻页与动画方向计算。
 */
final class ReaderTurn {
    private ReaderTurn() { }

    /** 从 from 开始一页排到哪里（ReaderActivity.pageEnd）。 */
    interface Cut { int end(String s, int from); }

    /** 跳过页首的空行（每页都不以空行开头）。 */
    static int skipBreaks(String s, int i) {
        while (i < s.length() && (s.charAt(i) == '\n' || s.charAt(i) == '\r')) i++;
        return i;
    }

    /**
     * 这一章里、起点在 before 之前的最后一页的起点；before 前面没有页了返回 -1。
     * before = Integer.MAX_VALUE：本章最后一页的起点；空章返回 -1。
     */
    static int prevStart(String s, int before, Cut cut) {
        int i = 0, last = -1;
        while (i < s.length()) {
            i = skipBreaks(s, i);
            if (i >= s.length() || i >= before) break;
            last = i;
            int e = cut.end(s, i);
            i = e > i ? e : i + 1;
        }
        return last;
    }

    /** 这一页 [start, end) 之后本章还有字吗（没有 = 本章最后一页，下一页要进下一章）。 */
    static boolean chapterHasMore(String s, int end) {
        return skipBreaks(s, Math.max(0, end)) < s.length();
    }

    /** 显示桥 SWIPE 的方向（0 下 1 上 2 左 3 右），-1 = 不动画。mode：0 关、1 跟随、2 左、3 右、4 上、5 下。 */
    static int slideDir(int mode, boolean noSwipe, int dir) {
        if (mode <= 0 || mode > 5 || noSwipe) return -1;
        switch (mode) {
        case 2: return 2;
        case 3: return 3;
        case 4: return 1;
        case 5: return 0;
        default: return dir < 0 ? 3 : 2;
        }
    }
}
