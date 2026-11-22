package com.veradroid.home;

import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ResolveInfo;
import android.os.Build;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 方块风格“我的”下面的设置页：用步进器“‹ 值 ›”和方块级别条，不用滑条；每页几个黑底标题分组。
 * 这里只放最常用的几项，偏好键和宿主设置键都是现有的（KFB_SMOOTH / KFB_FLASH / KFB_CONTRAST / KFB_INVERT /
 * RETURN_MODE / TIME_12_24、light / warmth / sleeptime 命令）；其余的从每页最下面“更多…”进经典设置的对应分类，一项不少。
 */
final class BlocksSettings {
    private final BlocksHome h;
    private final HomeActivity a;
    private final SharedPreferences prefs;

    static final String[] SMOOTH_L = { "跟随", "流畅", "均衡", "画质" };
    static final String[] FLASH_L = { "不按页数", "每页", "3 页", "6 页", "8 页", "10 页", "20 页" };
    static final String[] FLASH_V = { "0", "1", "3", "6", "8", "10", "20" };
    static final String[] CONTRAST_L = { "1.0 柔和", "1.3 标准", "1.6 较黑", "1.9 很黑", "2.2 最黑" };
    static final String[] CONTRAST_V = { "1.0", "1.3", "1.6", "1.9", "2.2" };
    static final String[] SLEEP_L = { "5 分钟", "10 分钟", "30 分钟", "1 小时" };
    static final int[] SLEEP_S = { 300, 600, 1800, 3600 };
    static final String[] RETURN_L = { "挂起", "关闭" };
    static final String[] RETURN_V = { "freeze", "off" };
    static final String[] TIME_L = { "跟随 Kobo", "24 小时", "12 小时" };
    static final String[] TIME_V = { "auto", "24", "12" };
    static final String[] MODE_L = { "均衡", "灰度最准", "最快", "自动" };
    static final String[] MODE_V = { "0", "1", "2", "3" };
    static final String[] DARKCRUSH_L = { "关", "轻", "标准", "强" };
    static final String[] DARKCRUSH_V = { "0", "24", "36", "48" };
    static final String[] GCN_L = { "关", "20 次", "30 次", "50 次" };
    static final String[] GCN_V = { "0", "20", "30", "50" };
    static final String[] FONT_L = { "小", "标准", "大", "特大" };
    static final float[] FONT_S = { 0.85f, 1.0f, 1.15f, 1.3f };

    BlocksSettings(BlocksHome home) { h = home; a = home.a; prefs = home.prefs; }

    private int dp(int v) { return Ui.dp(a, v); }

    static final String[] CAT_EN = { "Wi-Fi & Bluetooth", "Display & refresh", "Gestures", "Apps & home", "Transfer", "Device & update", "About" };

    String sig(int key) {
        if (BlocksHome.isCat(key)) {
            int t = key - BlocksHome.S_CATS - 1;
            // “关于”页显示可用内存：每分钟算新的一次；其余按设置文件 + 偏好（和经典设置页同一个签名）
            return a.settingsSig() + (t == HomeActivity.CAT_ABOUT_ ? "|" + System.currentTimeMillis() / 60000 : "");
        }
        Map<String, String> st = HostLink.kv(HostLink.CTL + "status");
        String cfg = new java.util.TreeMap<String, String>(HostLink.kv(HostLink.KFB + "settings")).toString();
        switch (key) {
        case BlocksHome.S_DISPLAY: return cfg + prefs.getString("name", "VeraDroid") + prefs.getString("quick", "") + prefs.getString("panelname", "") + AppFont.user(a) + st.get("light") + st.get("warmth") + st.get("lightmax") + st.get("haslight") + st.get("haswarmth") + Blocks.on(a);
        case BlocksHome.S_POWER: return cfg + st.get("sleep") + prefs.getBoolean("clock12", false) + "|" + java.util.Calendar.getInstance().get(java.util.Calendar.DAY_OF_YEAR);
        case BlocksHome.S_STORAGE: return st.get("wifi") + "|" + Transfer.get(a).running() + "|" + AdbWifi.on() + "|" + BlocksHome.storageUsed();
        case BlocksHome.S_CARDS: return prefs.getString(BlocksCards.KEY, BlocksCards.DEFAULT) + prefs.getString("blk_quick", "") + prefs.getString("wx_city", "") + prefs.getString("blk_readers", "") + a.appsVersion();
        default: return prefs.getString("name", "VeraDroid") + "|" + (System.currentTimeMillis() / 60000);
        }
    }

    View build(int key) {
        if (BlocksHome.isCat(key)) {
            int t = key - BlocksHome.S_CATS - 1;
            return shell(t < 0 ? "All settings" : CAT_EN[t], HomeActivity.catName(t), (LinearLayout) a.blocksCategory(t));
        }
        switch (key) {
        case BlocksHome.S_DISPLAY: return display();
        case BlocksHome.S_POWER: return power();
        case BlocksHome.S_STORAGE: return storage();
        case BlocksHome.S_CARDS: return cards();
        default: return about();
        }
    }

    /** 设置页的外壳：标题区（右边一个返回方块）+ 可以翻页的内容。 */
    private LinearLayout shell(String en, String zh, LinearLayout content) {
        LinearLayout pg = new LinearLayout(a);
        pg.setOrientation(LinearLayout.VERTICAL);
        pg.addView(Blocks.pageHead(a, en, zh, Blocks.squareButton(a, Icons.Kind.BACK, new View.OnClickListener() {
            @Override public void onClick(View v) { h.back(); }
        })));
        pg.addView(h.paged(content), new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        return pg;
    }

    private LinearLayout content() {
        LinearLayout l = new LinearLayout(a);
        l.setOrientation(LinearLayout.VERTICAL);
        l.setPadding(dp(16), 0, dp(16), dp(8));
        return l;
    }

    /** 一个分组：黑底标题条 + 外框，里面的行用细线隔开。 */
    private LinearLayout group(LinearLayout content, String title) {
        LinearLayout g = new LinearLayout(a);
        g.setOrientation(LinearLayout.VERTICAL);
        g.setBackground(Blocks.frame(a));
        int st = Blocks.stroke(a), sh = Blocks.shade(a);
        g.setPadding(st, st, st + sh, st + sh);
        g.addView(Blocks.header(a, title));
        content.addView(g, Blocks.gap(a, content.getChildCount() == 0 ? 4 : 14));
        return g;
    }

    private void add(LinearLayout g, View row) {
        if (g.getChildCount() > 1) g.addView(Blocks.hair(a));
        g.addView(row, Blocks.match());
    }

    /** 标签在左、宽控件（级别条 / 分段）占满右边的一行。 */
    private LinearLayout wideRow(String zh, String en, View control) {
        LinearLayout r = new LinearLayout(a);
        r.setGravity(Gravity.CENTER_VERTICAL);
        r.setPadding(dp(12), dp(8), dp(10), dp(8));
        r.setMinimumHeight(dp(60));
        LinearLayout left = new LinearLayout(a);
        left.setOrientation(LinearLayout.VERTICAL);
        left.addView(Ui.text(a, zh, 17, true));
        left.addView(Blocks.cap(a, en));
        r.addView(left, Blocks.lp(dp(104), ViewGroup.LayoutParams.WRAP_CONTENT));
        r.addView(control, Blocks.weight(1));
        return r;
    }

    private static int idx(String[] vals, String cur, int def) {
        for (int i = 0; i < vals.length; i++) if (vals[i].equals(cur)) return i;
        return def;
    }

    private void host(String kv) { if (!HostLink.settings(kv + "\n")) VeraToast.show(a, "保存失败"); }

    private View toggle(boolean on, Icons.Toggle.Listener l) { return new Blocks.Switch(a, on, l); }

    // ------------------------------------------------------------------ 显示与刷新

    private View display() {
        LinearLayout c = content();
        final Map<String, String> st = HostLink.kv(HostLink.CTL + "status");
        final Map<String, String> cfg = HostLink.kv(HostLink.KFB + "settings");
        int max = HostLink.num(st, "lightmax", 24);
        if (HostLink.num(st, "haslight", 1) == 1) {
            LinearLayout g = group(c, "屏幕光");
            Blocks.BlockBar cool = new Blocks.BlockBar(a, 12);
            cool.setMax(max);
            cool.setValue(HostLink.num(st, "light", 0));
            cool.setListener(new Blocks.BlockBar.Listener() { @Override public void onCommit(int v) { HostLink.cmd("light " + v); } });
            add(g, wideRow("亮度", "Front light", cool));
            if (HostLink.num(st, "haswarmth", 0) == 1) {
                Blocks.BlockBar warm = new Blocks.BlockBar(a, 12);
                warm.setMax(max);
                warm.setValue(HostLink.num(st, "warmth", 0));
                warm.setListener(new Blocks.BlockBar.Listener() { @Override public void onCommit(int v) { HostLink.cmd("warmth " + v); } });
                add(g, wideRow("暖光", "Warm light", warm));
            }
        }
        LinearLayout g = group(c, "刷新");
        int sm = Math.max(0, Math.min(3, HostLink.num(cfg, "KFB_SMOOTH", 0)));
        LinearLayout smRow = new LinearLayout(a);
        smRow.setOrientation(LinearLayout.VERTICAL);
        smRow.setPadding(dp(12), dp(8), dp(10), dp(10));
        smRow.addView(Ui.text(a, "刷新档位", 17, true));
        smRow.addView(Blocks.cap(a, "Refresh profile"));
        TextView smHint = Ui.text(a, "流畅：先快刷再补灰度 · 均衡：一次刷完 · 画质：最干净（跟随 = 用下面“更多”里的各项）", 12, false);
        smHint.setPadding(0, dp(2), 0, dp(6));
        smRow.addView(smHint);
        smRow.addView(new Blocks.SegBar(a, SMOOTH_L, sm, new Blocks.SegBar.Listener() { @Override public void onPick(int i) { host("KFB_SMOOTH=" + i); } }), Blocks.match());
        add(g, smRow);
        add(g, Blocks.row(a, "刷新方式", "Partial update", new Blocks.Stepper(a, MODE_L, idx(MODE_V, cfg.get("KFB_MODE"), 0), new Blocks.Stepper.Listener() {
            @Override public void onStep(int i) { host("KFB_MODE=" + MODE_V[i]); } })));
        add(g, Blocks.row(a, "全刷周期", "Full refresh period", new Blocks.Stepper(a, FLASH_L, idx(FLASH_V, cfg.get("KFB_FLASH"), 3), new Blocks.Stepper.Listener() {
            @Override public void onStep(int i) { host("KFB_FLASH=" + FLASH_V[i]); } })));
        add(g, Blocks.row(a, "对比度", "Contrast", new Blocks.Stepper(a, CONTRAST_L, idx(CONTRAST_V, cfg.get("KFB_CONTRAST"), 1), new Blocks.Stepper.Listener() {
            @Override public void onStep(int i) { host("KFB_CONTRAST=" + CONTRAST_V[i]); } })));
        add(g, Blocks.row(a, "浅色过滤", "Light-colour filter", new Blocks.Stepper(a, Panel.LIGHTF_L, idx(Panel.LIGHTF_V, cfg.get("KFB_LIGHTF"), 0), new Blocks.Stepper.Listener() {
            @Override public void onStep(int i) { host("KFB_LIGHTF=" + Panel.LIGHTF_V[i]); } })));
        add(g, Blocks.row(a, "深色加深", "Darken light text", toggle("1".equals(cfg.get("KFB_DARKEN")), new Icons.Toggle.Listener() {
            @Override public void onToggle(boolean on) { host("KFB_DARKEN=" + (on ? 1 : 0)); } })));
        add(g, Blocks.row(a, "反色", "Invert", toggle("1".equals(cfg.get("KFB_INVERT")), new Icons.Toggle.Listener() {
            @Override public void onToggle(boolean on) { host("KFB_INVERT=" + (on ? 1 : 0)); } })));
        add(g, Blocks.row(a, "立即整屏刷新", "Clear ghosting", Blocks.button(a, "刷新", false, new View.OnClickListener() {
            @Override public void onClick(View v) { HostLink.cmd("clear"); } })));
        int am = HostLink.num(cfg, "KFB_ANIM_MODE", 0);
        final int[] animLast = { am > 0 ? am : 1 };
        add(g, Blocks.row(a, "翻页动画", "Page-turn swipe", toggle(am > 0, new Icons.Toggle.Listener() {
            @Override public void onToggle(boolean on) { host("KFB_ANIM_MODE=" + (on ? animLast[0] : 0)); } })));
        if (HostLink.isKobo()) {
            LinearLayout ng = group(c, "夜间与残影");
            add(ng, Blocks.row(a, "夜间原生波形", "Eclipse GLKW16 / GCK16", toggle(!"0".equals(cfg.get("KFB_ECLIPSE")), new Icons.Toggle.Listener() {
                @Override public void onToggle(boolean on) { host("KFB_ECLIPSE=" + (on ? 1 : 0)); } })));
            add(ng, Blocks.row(a, "暗底压纯黑", "Dark background crush", new Blocks.Stepper(a, DARKCRUSH_L, idx(DARKCRUSH_V, cfg.get("KFB_DARKCRUSH"), 2), new Blocks.Stepper.Listener() {
                @Override public void onStep(int i) { host("KFB_DARKCRUSH=" + DARKCRUSH_V[i]); } })));
            add(ng, Blocks.row(a, "大图后自动清残影", "Auto flash after images", toggle(!"0".equals(cfg.get("KFB_HEAVY_FLASH")), new Icons.Toggle.Listener() {
                @Override public void onToggle(boolean on) { host("KFB_HEAVY_FLASH=" + (on ? 1 : 0)); } })));
            add(ng, Blocks.row(a, "非翻页定时全刷", "UI ghosting cleanup", new Blocks.Stepper(a, GCN_L, idx(GCN_V, cfg.get("KFB_GCN"), 1), new Blocks.Stepper.Listener() {
                @Override public void onStep(int i) { host("KFB_GCN=" + GCN_V[i]); } })));
            add(ng, Blocks.row(a, "切换应用首屏全刷", "Full refresh on app switch", toggle(!"0".equals(cfg.get("KFB_NEWWIN")), new Icons.Toggle.Listener() {
                @Override public void onToggle(boolean on) { host("KFB_NEWWIN=" + (on ? 1 : 0)); } })));
        }
        if (HostLink.isKobo()) {
            LinearLayout kr = group(c, "方向与实体按键");
            add(kr, Blocks.row(a, "重力感应自动旋转", "Auto rotate (0° / 180°, keys follow)", toggle("1".equals(cfg.get("KFB_AUTO_ROTATE")), new Icons.Toggle.Listener() {
                @Override public void onToggle(boolean on) { host("KFB_AUTO_ROTATE=" + (on ? 1 : 0)); } })));
            add(kr, Blocks.row(a, "翻页键功能互换", "Swap page-turn buttons", toggle("1".equals(cfg.get("PAGE_KEYS_SWAP")), new Icons.Toggle.Listener() {
                @Override public void onToggle(boolean on) { host("PAGE_KEYS_SWAP=" + (on ? 1 : 0)); } })));
        }
        LinearLayout fg = group(c, "文字");
        float fs = AppFont.user(a);
        int fi = 0;
        for (int i = 0; i < FONT_S.length; i++) if (Math.abs(FONT_S[i] - fs) < Math.abs(FONT_S[fi] - fs)) fi = i;
        add(fg, Blocks.row(a, "应用字号", "App font size", new Blocks.Stepper(a, FONT_L, fi, new Blocks.Stepper.Listener() {
            @Override public void onStep(int i) { AppFont.setUser(a, FONT_S[i]); } })));
        add(fg, Blocks.navRow(a, "应用优化", "单独给某个应用设刷新、全刷、对比度、字号、保持后台", new View.OnClickListener() {
            @Override public void onClick(View v) { appDisplayPicker(); } }));
        LinearLayout ui = group(c, "界面");
        add(ui, Blocks.row(a, "界面风格", "Launcher style", new Blocks.Stepper(a, new String[] { "经典", "方块" }, 1, new Blocks.Stepper.Listener() {
            @Override public void onStep(final int i) { if (i == 0) a.setStyle("classic"); } }).wrap()));
        add(ui, Blocks.row(a, "动画", "E-ink animation", new Blocks.Stepper(a, Blocks.ANIM_L, Blocks.anim(a), new Blocks.Stepper.Listener() {
            @Override public void onStep(int i) { prefs.edit().putInt(Blocks.ANIM_KEY, i).apply(); } })));
        add(ui, Blocks.navRow(a, "下拉面板的快捷开关", "最多 5 个：" + quickNames(), new View.OnClickListener() {
            @Override public void onClick(View v) { a.quickDialog(); } }));
        String devName = prefs.getString("name", "VeraDroid");
        if (devName.length() == 0) devName = "VeraDroid";
        add(ui, Blocks.navRow(a, "阅读器名称", devName + "（显示在左上角）", new View.OnClickListener() {
            @Override public void onClick(View v) { a.titleDialog(); } }));
        add(ui, Blocks.navRow(a, "面板名称", prefs.getString("panelname", "").length() == 0 ? "（不显示）" : prefs.getString("panelname", ""), new View.OnClickListener() {
            @Override public void onClick(View v) { a.textDialog("面板名称", "最多 16 个字；留空就不显示。", "panelname", "", 16); } }));
        add(ui, Blocks.row(a, "界面字重", "UI font weight", new Blocks.Stepper(a, Fonts.WEIGHT_L, Fonts.weight(a), new Blocks.Stepper.Listener() {
            @Override public void onStep(int i) { prefs.edit().putInt(Fonts.WEIGHT_KEY, i).commit(); a.reloadBlocks(BlocksHome.S_DISPLAY); } })));
        add(ui, Blocks.row(a, "英文小字", "English captions", toggle(Blocks.caps(a), new Icons.Toggle.Listener() {
            @Override public void onToggle(boolean on) { prefs.edit().putBoolean(Blocks.CAPS_KEY, on).commit(); h.show(BlocksHome.S_DISPLAY); a.changed(); } })));
        c.addView(Blocks.navRow(a, "显示设置（屏幕旋转、刷新方式、REAGL…）", "宿主显示参数的步进器页", new View.OnClickListener() {
            @Override public void onClick(View v) { HostSettingsActivity.open(a, "display"); } }), Blocks.gap(a, 14));
        c.addView(Blocks.navRow(a, "更多显示设置", "系统字体 · 滑动合并 · 翻页动画速度 · 抖动 · 桌面大小", new View.OnClickListener() {
            @Override public void onClick(View v) { h.openCat(1); } }), Blocks.gap(a, 14));
        return shell("System / display", "显示与刷新", c);
    }

    // ------------------------------------------------------------------ 电源与时间

    private View power() {
        LinearLayout c = content();
        Map<String, String> st = HostLink.kv(HostLink.CTL + "status");
        Map<String, String> cfg = HostLink.kv(HostLink.KFB + "settings");
        LinearLayout g = group(c, "电源");
        if (HostLink.num(st, "hassleeptime", 1) == 1) {
            int sl = HostLink.num(st, "sleep", 600), bi = 1;
            for (int i = 0; i < SLEEP_S.length; i++) if (Math.abs(SLEEP_S[i] - sl) < Math.abs(SLEEP_S[bi] - sl)) bi = i;
            add(g, Blocks.row(a, "自动休眠", "Auto lock", new Blocks.Stepper(a, SLEEP_L, bi, new Blocks.Stepper.Listener() {
                @Override public void onStep(int i) { HostLink.cmd("sleeptime " + SLEEP_S[i]); } })));
        }
        if (!HostLink.isKobo()) {
            add(g, Blocks.row(a, "回到 Kobo", "Return mode", new Blocks.Stepper(a, RETURN_L, idx(RETURN_V, cfg.get("RETURN_MODE"), 0), new Blocks.Stepper.Listener() {
                @Override public void onStep(int i) { host("RETURN_MODE=" + RETURN_V[i]); } })));
        }
        LinearLayout btns = new LinearLayout(a);
        btns.setPadding(dp(10), dp(10), dp(10), dp(10));
        btns.addView(Blocks.button(a, "回 Kobo", false, new View.OnClickListener() { @Override public void onClick(View v) { HostLink.cmd("exit"); } }), Blocks.weight(1));
        View s1 = new View(a); btns.addView(s1, Blocks.lp(dp(8), 1));
        btns.addView(Blocks.button(a, "重启系统", false, new View.OnClickListener() { @Override public void onClick(View v) { a.confirmRestart(); } }), Blocks.weight(1));
        View s2 = new View(a); btns.addView(s2, Blocks.lp(dp(8), 1));
        btns.addView(Blocks.button(a, "关机…", true, new View.OnClickListener() { @Override public void onClick(View v) { a.powerMenu(); } }), Blocks.weight(1));
        add(g, btns);
        LinearLayout tools = new LinearLayout(a);
        tools.setPadding(dp(10), dp(10), dp(10), dp(10));
        tools.addView(Blocks.button(a, "切换应用", false, new View.OnClickListener() { @Override public void onClick(View v) {
            a.startActivity(new Intent(a, SwitcherActivity.class).addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)); a.overridePendingTransition(0, 0); } }), Blocks.weight(1));
        View s3 = new View(a); tools.addView(s3, Blocks.lp(dp(8), 1));
        final TextView clean = Blocks.button(a, "清理后台", false, null);
        clean.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
            clean.setText("清理中…");
            Cleaner.run(a, null, new Cleaner.Done() { @Override public void done(int stopped, long freedMb) { clean.setText(stopped == 0 ? "没有后台应用" : "已清理 " + stopped + " 个 · 约 " + freedMb + " MB"); } });
        } });
        tools.addView(clean, Blocks.weight(1));
        add(g, tools);
        LinearLayout bk = new LinearLayout(a);
        bk.setOrientation(LinearLayout.VERTICAL);
        bk.addView(Blocks.row(a, "后台保留应用", "Background apps", new Blocks.Stepper(a, Cleaner.LIMIT_L, Math.max(0, Math.min(4, prefs.getInt(Cleaner.LIMIT_KEY, Cleaner.defaultLimit()))), new Blocks.Stepper.Listener() {
            @Override public void onStep(int i) { prefs.edit().putInt(Cleaner.LIMIT_KEY, i).apply(); } })), Blocks.match());
        TextView bkHint = Ui.text(a, "前台以外最多留几个自己装的应用在后台，多出来的（最久没用的）在换应用 3 秒后停掉，省内存。应用长按 → 保持后台 的不算。", 12, false);
        bkHint.setPadding(dp(12), 0, dp(12), dp(10));
        bk.addView(bkHint);
        add(g, bk);
        add(g, Blocks.navRow(a, "锁屏密码", "开机 / 唤醒时输入 PIN", new View.OnClickListener() {
            @Override public void onClick(View v) { a.startActivity(new Intent(a, LockSettingsActivity.class)); } }));
        add(g, Blocks.navRow(a, "屏保", "休眠时显示的图片", new View.OnClickListener() {
            @Override public void onClick(View v) { a.startActivity(new Intent(a, ScreensaverActivity.class)); } }));
        LinearLayout t = group(c, "时间与日期");
        add(t, Blocks.row(a, "制式", "Format", new Blocks.Stepper(a, TIME_L, idx(TIME_V, cfg.get("TIME_12_24"), 0), new Blocks.Stepper.Listener() {
            @Override public void onStep(int i) {
                host("TIME_12_24=" + TIME_V[i]);
                prefs.edit().putBoolean("clock12", i == 2).apply();
                a.refreshStatusNow();
            } })));
        java.util.TimeZone tz = java.util.TimeZone.getDefault();
        int off = tz.getOffset(System.currentTimeMillis()) / 60000;
        add(t, Blocks.row(a, "时区", "Time zone", Ui.text(a, "GMT" + (off >= 0 ? "+" : "-") + Math.abs(off) / 60 + (off % 60 != 0 ? ":" + Math.abs(off % 60) : "") + "（跟随 Kobo）", 15, false)));
        java.util.Calendar cal = java.util.Calendar.getInstance();
        add(t, Blocks.row(a, "日期", "Date", Ui.text(a, cal.get(java.util.Calendar.YEAR) + " 年 " + (cal.get(java.util.Calendar.MONTH) + 1) + " 月 " + cal.get(java.util.Calendar.DAY_OF_MONTH) + " 日", 15, false)));
        TextView note = Ui.text(a, "日期、时间和时区跟 Kobo 同步（Kobo 联网自动对时）。要改请回到 Kobo 的“设置／设备选项／设备时间”。", 12, false);
        note.setPadding(dp(12), dp(6), dp(12), dp(10));
        add(t, note);
        return shell("System / power", "电源与时间", c);
    }

    // ------------------------------------------------------------------ 存储与连接

    private View storage() {
        LinearLayout c = content();
        LinearLayout g = group(c, "存储");
        LinearLayout use = new LinearLayout(a);
        use.setOrientation(LinearLayout.VERTICAL);
        use.setPadding(dp(12), dp(10), dp(12), dp(10));
        long total = 0, free = 0;
        try { android.os.StatFs s = new android.os.StatFs("/data/media/0"); total = s.getTotalBytes(); free = s.getAvailableBytes(); } catch (Throwable ignored) { }
        use.addView(Ui.text(a, "已用 " + gb(total - free) + " / 共 " + gb(total) + "，剩 " + gb(free), 16, true));
        Blocks.BlockBar bar = new Blocks.BlockBar(a, 20);
        bar.setMax(100);
        bar.setValue(BlocksHome.storageUsed());
        LinearLayout.LayoutParams bp = Blocks.match(); bp.topMargin = dp(6);
        use.addView(bar, bp);
        add(g, use);
        add(g, Blocks.navRow(a, "存储空间", "调大调小 Android 的空间、快满时自动扩大", new View.OnClickListener() {
            @Override public void onClick(View v) { a.startActivity(new Intent(a, StorageActivity.class)); } }));
        LinearLayout n = group(c, "连接");
        final Map<String, String> st = HostLink.kv(HostLink.CTL + "status");
        add(n, Blocks.row(a, "Wi-Fi", "Wireless", toggle(HostLink.num(st, "wifi", 1) == 1, new Icons.Toggle.Listener() {
            @Override public void onToggle(boolean on) { HostLink.cmd("wifi " + (on ? 1 : 0)); HostLink.cmd("status"); } })));
        add(n, Blocks.navRow(a, "Wi-Fi 网络", "切换已保存的网络，或连接附近的新网络", new View.OnClickListener() {
            @Override public void onClick(View v) { WifiActivity.open(a); } }));
        if (BluetoothActivity.supported()) add(n, Blocks.navRow(a, "蓝牙翻页器", "扫描、配对、连接", new View.OnClickListener() {
            @Override public void onClick(View v) { BluetoothActivity.open(a); } }));
        add(n, Blocks.navRow(a, "DNS 等更多", "Wi-Fi 与蓝牙的全部设置", new View.OnClickListener() {
            @Override public void onClick(View v) { h.openCat(0); } }));
        // 网络诊断：Wi-Fi / 域名解析 / 服务器 / 下载速度（宿主 netdiag 命令，结果 ctl/netdiag.status）
        c.addView(new TaskCards.Net(a), Blocks.gap(a, 14));
        LinearLayout w = group(c, "Web 文件管理");
        final Transfer t = Transfer.get(a);
        add(w, Blocks.row(a, "网页传书", "Web file manager", toggle(t.running(), new Icons.Toggle.Listener() {
            @Override public void onToggle(boolean on) {
                if (on) { t.setIdleMinutes(prefs.getInt("xfer_idle", 30)); if (!t.start()) VeraToast.show(a, "打不开传输服务：" + t.lastError()); } else t.stop();
                HostLink.cmd("status");
                a.handler().postDelayed(new Runnable() { @Override public void run() { if (h.current() == BlocksHome.S_STORAGE) { h.show(BlocksHome.S_STORAGE); a.changed(); } } }, 900);
            } })));
        String ip = st.get("lanip");
        TextView addr = Ui.text(a, t.running() ? (ip == null || ip.length() == 0 ? "正在获取地址…" : "http://" + ip + ":" + t.port()) + "\nPIN  " + t.pin()
            : "打开后，手机和 Kobo 连同一个 Wi-Fi，在浏览器里输入这里显示的地址和 PIN。", t.running() ? 20 : 13, t.running());
        addr.setPadding(dp(12), dp(8), dp(12), dp(10));
        add(w, addr);
        add(w, Blocks.navRow(a, "传书页面", "大字显示地址和 PIN", new View.OnClickListener() {
            @Override public void onClick(View v) { a.startActivity(new Intent(a, TransferActivity.class).addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)); a.overridePendingTransition(0, 0); } }));
        if (!HostLink.isKobo()) {
            // 无线调试（adb）：需要内核 IPv6 支持，Kobo 4.1.15 内核未启用 IPv6 故隐藏
            add(w, Blocks.row(a, "无线调试 (adb)", "adb over Wi-Fi", toggle(AdbWifi.on(), new Icons.Toggle.Listener() {
                @Override public void onToggle(boolean on) {
                    AdbWifi.set(a, on, 30, new Runnable() { @Override public void run() { if (h.current() == BlocksHome.S_STORAGE) { h.show(BlocksHome.S_STORAGE); a.changed(); } } });
                } })));
            TextView adbNote = Ui.text(a, AdbWifi.DESC, 13, false);
            adbNote.setPadding(dp(12), dp(4), dp(12), dp(10));
            add(w, adbNote);
        }
        return shell("Storage / network", "存储与连接", c);
    }

    private String quickNames() {
        StringBuilder sb = new StringBuilder();
        int n = 0;
        for (String id : prefs.getString("quick", Panel.QUICK_DEFAULT).split(",")) {
            for (int i = 0; i < Panel.QUICK_ID.length; i++) if (Panel.QUICK_ID[i].equals(id.trim()) && n < BlocksPanel.MAX_TILES) {
                if ("bt".equals(id.trim()) && !BluetoothActivity.supported()) continue;
                if (sb.length() > 0) sb.append(" · ");
                sb.append(Panel.QUICK_NAME[i]); n++;
            }
        }
        return sb.toString();
    }

    /** 每个应用的显示效果：挑一个应用，进它的显示效果页（和长按应用图标 → 显示效果是同一页）。 */
    private void appDisplayPicker() {
        final List<ResolveInfo> apps = new java.util.ArrayList<ResolveInfo>(a.appList());
        if (apps.isEmpty()) { VeraToast.show(a, "还没有安装应用"); return; }
        // 新宿主（appprof.sh）：每个应用后面写上现在用的是什么；单独设置过的排在前面，最上面一项“全部恢复默认”
        final boolean nh = AppProf.host();
        final java.util.Map<String, String[]> t = nh ? AppProf.table() : null;
        int users = 0;
        if (nh) {
            java.util.List<ResolveInfo> mine = new java.util.ArrayList<ResolveInfo>(), rest = new java.util.ArrayList<ResolveInfo>();
            for (ResolveInfo ri : apps) (AppProf.lookup(t, ri.activityInfo.packageName)[0].startsWith("u") ? mine : rest).add(ri);
            users = mine.size();
            apps.clear(); apps.addAll(mine); apps.addAll(rest);
        }
        final int off = users > 0 ? 1 : 0;
        String[] names = new String[apps.size() + off];
        if (off > 0) names[0] = "全部恢复默认（" + users + " 个单独设置过的应用）";
        for (int i = 0; i < apps.size(); i++) {
            String n = a.labelFor(apps.get(i));
            if (nh) {
                String[] r = AppProf.lookup(t, apps.get(i).activityInfo.packageName);
                if (r[0].startsWith("u")) n += "  · 已单独设置：" + AppProf.summary(r[1]);
                else if (r[0].equals("b")) n += "  · 推荐：" + AppProf.summary(r[1]);
            }
            names[i + off] = n;
        }
        new VeraDialog.Builder(a).title("优化哪个应用").items(names, new VeraDialog.OnPick() {
            @Override public void onPick(int w) {
                if (off > 0 && w == 0) {
                    new VeraDialog.Builder(a).title("全部恢复默认").message("单独设置过的应用都回到内置推荐 / 全局设置（字号的单独设置不变）。")
                        .negative("取消", null).positive("恢复", new Runnable() { @Override public void run() {
                            AppProf.save("*", ""); VeraToast.show(a, "已恢复默认"); } }).show();
                    return;
                }
                ResolveInfo ri = apps.get(w - off);
                Intent i = new Intent(a, AppDisplayActivity.class);
                i.putExtra("pkg", ri.activityInfo.packageName);
                i.putExtra("label", a.labelFor(ri));
                a.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION));
                a.overridePendingTransition(0, 0);
            }
        }).negative("取消", null).show();
    }

    private static String gb(long b) { return b >= 1073741824L ? String.format(java.util.Locale.US, "%.1f GB", b / 1073741824.0) : (b / 1048576) + " MB"; }

    // ------------------------------------------------------------------ 设备与关于

    private View about() {
        LinearLayout c = content();
        LinearLayout g = group(c, "设备");
        android.app.ActivityManager am = (android.app.ActivityManager) a.getSystemService(android.content.Context.ACTIVITY_SERVICE);
        android.app.ActivityManager.MemoryInfo mi = new android.app.ActivityManager.MemoryInfo();
        am.getMemoryInfo(mi);
        String devName = prefs.getString("name", "VeraDroid");
        if (devName.length() == 0) devName = "VeraDroid";
        add(g, Blocks.navRow(a, "阅读器名称", devName + "（点击自定义，显示在左上角）", new View.OnClickListener() {
            @Override public void onClick(View v) { a.titleDialog(); } }));
        add(g, Blocks.row(a, "机型", "Model", Ui.text(a, h.model(), 15, false)));
        add(g, Blocks.row(a, "系统", "Android", Ui.text(a, "Android " + Build.VERSION.RELEASE, 15, false)));
        add(g, Blocks.row(a, "桌面版本", "Launcher", Ui.text(a, h.version() + " · " + h.buildDate(), 15, false)));
        add(g, Blocks.row(a, "内存", "Memory", Ui.text(a, (mi.availMem >> 20) + " / " + (mi.totalMem >> 20) + " MB 可用", 15, false)));
        add(g, Blocks.row(a, "原作者", "Original author", Ui.text(a, "ajie · wenjin.jp", 15, false)));
        add(g, Blocks.row(a, "kobo系统移植优化", "Kobo port", Ui.text(a, "Scokyfei", 15, false)));
        // 系统更新的进度（宿主写 ctl/update.status；没有在更新时不占地方）
        c.addView(new TaskCards.Update(a, false), Blocks.gap(a, 14));
        LinearLayout m = group(c, "维护");
        boolean kobo = HostLink.isKobo();
        String[][] rows = {
            { "系统与性能", kobo ? "低内存 · 应用编译" : "Wi-Fi 省电 · 低内存 · Kobo 界面 · 应用编译" },
            { "检查系统更新", "有新版本优先下载增量补丁" }, { "使用统计", "电量和阅读时长，只在本机" }, { "问题反馈", "连同系统日志一起上传" },
            { "设备与管理", "日志 · 重启 · 恢复默认" }, { "手势", "边缘滑动 · 双指 · 四角长按 · 导航键" },
            { "应用与桌面", "壁纸 · 图标 · 面板 · 状态栏 · 输入法" }, { "传书", "无线传输的开关、地址、自动关闭" }, { "全部设置", "所有设置的分类列表" } };
        for (int i = 0; i < rows.length; i++) {
            if (kobo && (i == 1 || i == 3)) continue;
            final int k = i;
            add(m, Blocks.navRow(a, rows[i][0], rows[i][1], new View.OnClickListener() { @Override public void onClick(View v) {
                switch (k) {
                case 0: HostSettingsActivity.open(a, "system"); break;
                case 1: a.fullUpdateDialog(); break;
                case 2: a.startActivity(new Intent(a, StatsActivity.class)); a.overridePendingTransition(0, 0); break;
                case 3: a.feedbackDialog(); break;
                case 4: h.openCat(5); break;
                case 5: h.openCat(2); break;
                case 6: h.openCat(3); break;
                case 7: h.openCat(4); break;
                default: h.openCat(-1); break;
                }
            } }));
        }
        return shell("Device / about", "设备与关于", c);
    }

    // ------------------------------------------------------------------ 首页卡片

    private View cards() {
        LinearLayout c = content();
        final List<String> order = BlocksCards.order(a);
        List<String> rows = new ArrayList<String>(order);
        for (String id : BlocksCards.IDS) if (!rows.contains(id)) rows.add(id);
        LinearLayout g = group(c, "首页卡片（从上到下）");
        for (final String id : rows) {
            final boolean on = order.contains(id);
            LinearLayout r = new LinearLayout(a);
            r.setGravity(Gravity.CENTER_VERTICAL);
            r.setPadding(dp(12), dp(6), dp(8), dp(6));
            r.setMinimumHeight(dp(60));
            LinearLayout left = new LinearLayout(a);
            left.setOrientation(LinearLayout.VERTICAL);
            TextView name = BlocksCards.line(a, BlocksCards.name(a, id), 16, on);
            left.addView(name);
            left.addView(Blocks.cap(a, BlocksCards.en(id)));
            r.addView(left, Blocks.weight(1));
            if (BlocksCards.isWidget(id)) {
                final int wid = BlocksCards.widgetId(id);
                r.addView(Blocks.squareButton(a, Icons.Kind.MORE, new View.OnClickListener() { @Override public void onClick(View v) { widgetMenu(wid); } }));
            } else {
                r.addView(toggle(on, new Icons.Toggle.Listener() { @Override public void onToggle(boolean v) {
                    List<String> l = BlocksCards.order(a);
                    if (v && !l.contains(id)) { l.add(id); h.flashCard = id; } else if (!v) l.remove(id);
                    saveOrder(l);
                } }));
            }
            if (on) {
                View sp = new View(a); r.addView(sp, Blocks.lp(dp(8), 1));
                r.addView(Blocks.squareButton(a, Icons.Kind.CHEV_U, new View.OnClickListener() { @Override public void onClick(View v) { move(id, -1); } }));
                View sp2 = new View(a); r.addView(sp2, Blocks.lp(dp(6), 1));
                r.addView(Blocks.squareButton(a, Icons.Kind.CHEV_D, new View.OnClickListener() { @Override public void onClick(View v) { move(id, 1); } }));
            }
            add(g, r);
        }
        LinearLayout more = group(c, "卡片内容");
        add(more, Blocks.navRow(a, "添加 Android 小部件", "已安装应用提供的小部件，更新最多一分钟一次", new View.OnClickListener() {
            @Override public void onClick(View v) { BlocksCards.pickWidget(a, new Runnable() { @Override public void run() { refresh(); } }); } }));
        add(more, Blocks.navRow(a, "继续阅读认哪些应用", "已认 " + installedReaders() + " 个已安装的阅读应用（EinkBro 等浏览器默认不算）", new View.OnClickListener() {
            @Override public void onClick(View v) { readersDialog(); } }));
        String q = prefs.getString("blk_quick", "");
        add(more, Blocks.navRow(a, "快捷应用", q.length() == 0 ? "还没挑" : "已挑 " + q.split(",").length + " 个", new View.OnClickListener() {
            @Override public void onClick(View v) { quickApps(); } }));
        String city = prefs.getString("wx_city", "");
        add(more, Blocks.navRow(a, "天气城市", city.length() == 0 ? "还没设" : city, new View.OnClickListener() {
            @Override public void onClick(View v) { BlocksCards.cityDialog(a, new Runnable() { @Override public void run() { refresh(); } }); } }));
        return shell("Home / cards", "首页卡片", c);
    }

    private void refresh() { h.invalidate(BlocksHome.HOME); if (h.current() == BlocksHome.S_CARDS) { h.show(BlocksHome.S_CARDS); a.changed(); } }

    private void saveOrder(List<String> l) {
        BlocksCards.save(a, l);
        if (BlocksCards.hasWidgets(a)) BlocksCards.startListening(a);
        refresh();
    }

    private void move(String id, int dir) {
        List<String> l = BlocksCards.order(a);
        int i = l.indexOf(id), j = i + dir;
        if (i < 0 || j < 0 || j >= l.size()) return;
        l.set(i, l.get(j));
        l.set(j, id);
        saveOrder(l);
    }

    private void widgetMenu(final int id) {
        int sz = prefs.getInt("wsz_" + id, 1);
        new VeraDialog.Builder(a).title(BlocksCards.name(a, "w" + id))
            .items(new String[] { "高度：小", "高度：中", "高度：大", "移除这个小部件" }, new VeraDialog.OnPick() {
                @Override public void onPick(int w) {
                    if (w < 3) prefs.edit().putInt("wsz_" + id, w).apply();
                    else BlocksCards.removeWidget(a, id);
                    refresh();
                }
            }).selected(sz).negative("取消", null).show();
    }

    private int installedReaders() { int n = 0; for (String p : BlocksCards.readers(a)) if (a.findApp(p) != null) n++; return n; }

    /** 继续阅读认哪些应用：已安装的应用一个个列出来，点一下勾上 / 去掉。 */
    private void readersDialog() {
        final List<ResolveInfo> apps = a.appList();
        if (apps.isEmpty()) { VeraToast.show(a, "还没有安装应用"); return; }
        final List<String> chosen = BlocksCards.readers(a);
        final LinearLayout box = new LinearLayout(a);
        box.setOrientation(LinearLayout.VERTICAL);
        final TextView[] rows = new TextView[apps.size()];
        final Runnable paint = new Runnable() { @Override public void run() {
            for (int i = 0; i < rows.length; i++) rows[i].setText((chosen.contains(apps.get(i).activityInfo.packageName) ? "[x] " : "[  ] ") + a.labelFor(apps.get(i)));
        } };
        for (int i = 0; i < rows.length; i++) {
            final String pkg = apps.get(i).activityInfo.packageName;
            TextView r = Ui.text(a, "", 18, false);
            r.setPadding(dp(8), dp(9), dp(8), dp(9));
            r.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) { if (!chosen.remove(pkg)) chosen.add(pkg); paint.run(); } });
            rows[i] = r;
            box.addView(r);
        }
        paint.run();
        PageScrollView sv = new PageScrollView(a);
        sv.addView(box);
        sv.setLayoutParams(new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, Math.min(dp(420), a.getResources().getDisplayMetrics().heightPixels / 2)));
        new VeraDialog.Builder(a).title("继续阅读认哪些应用").message("从这些应用回到桌面时，首页“继续阅读”会记下它和离开时的画面。").view(sv)
            .negative("恢复默认", new Runnable() { @Override public void run() { prefs.edit().remove("blk_readers").apply(); refresh(); } })
            .positive("保存", new Runnable() { @Override public void run() { prefs.edit().putString("blk_readers", android.text.TextUtils.join(",", chosen)).apply(); refresh(); } }).show();
    }

    /** 快捷应用：点一下加入（按点的先后排），再点一下拿掉；最多 5 个。 */
    private void quickApps() {
        final List<ResolveInfo> apps = a.appList();
        if (apps.isEmpty()) { VeraToast.show(a, "还没有安装应用"); return; }
        final List<String> chosen = new ArrayList<String>();
        for (String s : prefs.getString("blk_quick", "").split(",")) if (s.length() > 0) chosen.add(s);
        final LinearLayout box = new LinearLayout(a);
        box.setOrientation(LinearLayout.VERTICAL);
        final TextView[] rows = new TextView[apps.size()];
        final Runnable paint = new Runnable() { @Override public void run() {
            for (int i = 0; i < rows.length; i++) {
                int at = chosen.indexOf(apps.get(i).activityInfo.packageName);
                rows[i].setText((at >= 0 ? "[" + (at + 1) + "] " : "[  ] ") + a.labelFor(apps.get(i)));
            }
        } };
        for (int i = 0; i < rows.length; i++) {
            final String pkg = apps.get(i).activityInfo.packageName;
            TextView r = Ui.text(a, "", 18, false);
            r.setPadding(dp(8), dp(9), dp(8), dp(9));
            r.setOnClickListener(new View.OnClickListener() { @Override public void onClick(View v) {
                if (chosen.contains(pkg)) chosen.remove(pkg); else if (chosen.size() < 5) chosen.add(pkg); else VeraToast.show(a, "最多 5 个");
                paint.run();
            } });
            rows[i] = r;
            box.addView(r);
        }
        paint.run();
        PageScrollView sv = new PageScrollView(a);
        sv.addView(box);
        sv.setLayoutParams(new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, Math.min(dp(420), a.getResources().getDisplayMetrics().heightPixels / 2)));
        new VeraDialog.Builder(a).title("快捷应用").message("点一下加入（数字是顺序），再点一下拿掉。最多 5 个。").view(sv).negative("取消", null)
            .positive("保存", new Runnable() { @Override public void run() {
                prefs.edit().putString("blk_quick", android.text.TextUtils.join(",", chosen)).apply();
                if (!BlocksCards.order(a).contains("apps") && !chosen.isEmpty()) { List<String> l = BlocksCards.order(a); l.add("apps"); BlocksCards.save(a, l); }
                refresh();
            } }).show();
    }

}
