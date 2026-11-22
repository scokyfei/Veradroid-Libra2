package com.veradroid.home;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.os.Bundle;
import android.os.FileObserver;
import android.os.Handler;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.util.Map;

/**
 * 以前只有宿主 / 传书网页才能改的设置，在设备上给一个入口。两页，Intent extra "page"：
 *   display  显示与刷新：旋转（KFB_ROTATE）、显示档位（KFB_SMOOTH）、局部刷新（KFB_MODE）、快速滑动（KFB_SCROLLDU）、图片灰度（KFB_IMG）、整页刷新（KFB_REAGL_MIN）、整屏闪刷（KFB_FLASH）、
 *            浅色过滤（KFB_LIGHTF）、深色加深（KFB_DARKEN）
 *   system   系统与性能：Wi-Fi 省电（WIFI_PS）、小内存模式（LOWMEM）、Kobo 界面（KINDLE_UI）、应用预编译（APP_COMPILE + ctl/compile.status + 全部优化）
 * 每项一行“< 值 >”步进：点一下只改那一行的字（一次小刷新），同时经 HostLink.settings 写给宿主（ctl/settings.new + apply → settings.conf）。
 * 不搭列表、不滚动：一页放得下；小屏放不下时用 PageScrollView 整页翻。
 */
public class HostSettingsActivity extends Activity {
    static void open(Context c, String page) {
        c.startActivity(new Intent(c, HostSettingsActivity.class).putExtra("page", page).addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION));
    }

    private final Handler handler = new Handler();
    private Map<String, String> host;
    private LinearLayout list;
    private TextView compileView, smoothNote;
    private CtlWatch.Listener compileWatch;
    private boolean system;
    private boolean rotatePending;
    private Runnable pendingRotate = new Runnable() { @Override public void run() { } };

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(Color.WHITE));
        getWindow().setWindowAnimations(0);
        system = "system".equals(getIntent().getStringExtra("page"));
        host = HostLink.kv(HostLink.KFB + "settings");
        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setBackgroundColor(Color.WHITE);
        page.setPadding(dp(16), dp(8), dp(16), dp(8));
        setContentView(page);
        TextView title = Ui.text(this, system ? "系统与性能" : "显示与刷新", 30, true);
        title.setPadding(0, dp(8), 0, dp(4));
        page.addView(title);
        final PageScrollView sv = new PageScrollView(this);
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        sv.addView(list);
        page.addView(sv, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        LinearLayout nav = new LinearLayout(this);
        nav.addView(Ui.button(this, "返回", 17, false, new View.OnClickListener() { @Override public void onClick(View v) { finish(); } }), weight());
        nav.addView(Ui.button(this, "上一屏", 17, false, new View.OnClickListener() { @Override public void onClick(View v) { sv.page(-1); } }), weight());
        nav.addView(Ui.button(this, "下一屏", 17, false, new View.OnClickListener() { @Override public void onClick(View v) { sv.page(1); } }), weight());
        page.addView(nav);
        if (Blocks.on(this)) {   // 方块风格：方块页头；“上一屏 / 下一屏 / 返回”换成翻页条（返回在页头右边）
            Blocks.restyle(this, page, title, null, system ? "System / performance" : "Display / host");
            page.removeView(nav);
            page.removeView(sv);
            sv.removeView(list);
            page.addView(Blocks.paged(this, list), new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        }
        if (system) buildSystem(); else buildDisplay();
    }

    private int dp(int v) { return Ui.dp(this, v); }
    private LinearLayout.LayoutParams weight() { return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1); }

    private void section(String s) {
        if (Blocks.on(this)) { list.addView(Blocks.sectionTitle(this, s, 15)); return; }
        TextView h = Ui.text(this, s, 15, true);
        h.setPadding(0, dp(16), 0, dp(4));
        list.addView(h);
        list.addView(Ui.rule(this, 2, Color.BLACK));
    }

    interface OnSet { void set(String v); }

    /** 一行：标题、说明、下面“< 值 >”。值不在选项里（手改过 settings.conf）时显示原值，按 ‹ › 跳到最近的一项。 */
    private void stepper(String title, String desc, final String key, final String[] labels, final String[] values, String def, final OnSet after) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.VERTICAL);
        row.setPadding(0, dp(10), 0, dp(10));
        row.addView(Ui.text(this, title, 20, true));
        if (desc != null) {
            TextView d = Ui.text(this, desc, 15, false);
            d.setPadding(0, dp(2), 0, dp(6));
            row.addView(d);
        }
        String cur = host.get(key);
        if (cur == null || cur.length() == 0) cur = def;
        int at = -1;
        for (int i = 0; i < values.length; i++) if (values[i].equals(cur)) at = i;
        final int[] idx = { at };
        final TextView val = Ui.text(this, at >= 0 ? labels[at] : cur, 20, false);
        val.setGravity(Gravity.CENTER);
        final boolean blk = Blocks.on(this);
        if (blk) {   // 方块风格：值是黑底白字的方块，两边方框箭头（和步进器一样）
            Fonts.apply(val, true);
            val.setTextSize(17);
            val.setTextColor(Color.WHITE);
            val.setBackground(Blocks.plainFilled(this));
            val.setSingleLine(true);
            val.setEllipsize(android.text.TextUtils.TruncateAt.END);
        }
        LinearLayout line = new LinearLayout(this);
        line.setGravity(Gravity.CENTER_VERTICAL);
        View.OnClickListener step = null;
        for (int dir = -1; dir <= 1; dir += 2) {
            final int d = dir;
            View.OnClickListener l = new View.OnClickListener() {
                @Override public void onClick(View v) {
                    int n = idx[0] < 0 ? (d > 0 ? 0 : values.length - 1) : idx[0] + d;
                    if (n < 0 || n >= values.length) return;   // 到头了：不绕回去，免得一下跳到另一端
                    idx[0] = n;
                    val.setText(labels[n]);
                    host.put(key, values[n]);
                    if (after != null) after.set(values[n]);
                    final String line = key + "=" + values[n] + "\n";
                    // 旋转：横屏要重启 Android，连点几下“›”路过的档位不能每个都生效——停手 2.5 秒后才发最后选的那个
                    if (key.equals("KFB_ROTATE")) {
                        handler.removeCallbacks(pendingRotate);
                        rotatePending = true;
                        pendingRotate = new Runnable() { @Override public void run() { rotatePending = false; HostLink.settings(line); } };
                        handler.postDelayed(pendingRotate, 2500);
                    } else HostLink.settings(line);
                }
            };
            if (dir < 0) {
                line.addView(Ui.button(this, "<", 26, false, l), new LinearLayout.LayoutParams(dp(72), dp(56)));
                LinearLayout.LayoutParams vp = new LinearLayout.LayoutParams(0, blk ? dp(56) : ViewGroup.LayoutParams.WRAP_CONTENT, 1);
                if (blk) { vp.leftMargin = dp(6); vp.rightMargin = dp(6); }
                line.addView(val, vp);
            } else {
                line.addView(Ui.button(this, ">", 26, false, l), new LinearLayout.LayoutParams(dp(72), dp(56)));
            }
        }
        row.addView(line);
        list.addView(row);
    }

    // ---- 显示与刷新 ----------------------------------------------------------------------------------------------

    private void buildDisplay() {
        section("方向");
        stepper("屏幕旋转", "画面顺时针转。倒过来（180°）立即生效；横屏（90° / 270°）要重启 Android（约 20 秒，自动进行）。停手 2.5 秒后才生效。",
            "KFB_ROTATE", new String[] { "竖屏（0°）", "倒过来（180°）", "横屏（90°，会重启）", "横屏（270°，会重启）" },
            new String[] { "0", "180", "90", "270" }, "0", null);
        if (HostLink.isKobo()) {
            stepper("重力感应自动旋转", "开启后倒拿设备自动在 0° / 180° 间实时旋转，触摸坐标、手势与实体翻页键自动随动；横屏模式下在 90° / 270° 间随动。",
                "KFB_AUTO_ROTATE", new String[] { "关（默认）", "开" }, new String[] { "0", "1" }, "0", null);
            stepper("翻页键功能互换", "交换上下实体翻页键的上一页 / 下一页功能，立即生效，且自动跟随屏幕旋转。",
                "PAGE_KEYS_SWAP", new String[] { "关（默认）", "开" }, new String[] { "0", "1" }, "0", null);
        }
        section("档位");
        stepper("显示档位", "一次定好下面的刷新方式：流畅（先快刷、停下再补灰度）、均衡、画质（驱动自动选波形，合并中间帧）。选“自定义”时按下面几项单独设。",
            "KFB_SMOOTH", new String[] { "自定义", "流畅", "均衡", "画质" }, new String[] { "0", "1", "2", "3" }, "0",
            new OnSet() { @Override public void set(String v) { smoothNote(v); } });
        smoothNote = Ui.text(this, "", 15, false);
        list.addView(smoothNote);
        smoothNote(host.get("KFB_SMOOTH"));
        section("局部刷新（屏幕上一小块变化：点按钮、翻列表）");
        stepper("局部刷新方式", "均衡：快，残影少；灰度最准：颜色最准，稍慢；最快：只有黑白，最灵敏，残影多；自动：和 Kobo 自己一样由驱动选。",
            "KFB_MODE", new String[] { "均衡", "灰度最准", "最快", "自动（同 Kobo）" }, new String[] { "0", "1", "2", "3" }, "0", null);
        stepper("快速滑动", "滚动、拖动列表时先用黑白快刷跟上手指，停下约 0.3 秒后再用 16 级灰度补刷一遍（清掉残影）。滑动时字会粗糙一点。",
            "KFB_SCROLLDU", new String[] { "关（默认）", "开" }, new String[] { "0", "300" }, "0", null);
        stepper("图片灰度", "均衡方式下，小块变化里是图片（封面、头像、照片）的部分用 16 级灰度刷，不再变成黑白点阵；文字照旧快刷。图片会慢约 70 毫秒。",
            "KFB_IMG", new String[] { "关（默认）", "开" }, new String[] { "0", "25" }, "0", null);
        section("整页刷新（翻页、换页面）");
        stepper("多大算整页", "一次变化超过屏幕的这么多，就用 16 级灰度的整页波形（清残影，约慢 70 毫秒）；小于它按局部刷新。",
            "KFB_REAGL_MIN", new String[] { "三成", "翻页（默认）", "一半", "七成", "接近整屏" }, new String[] { "30", "35", "50", "70", "85" }, "35", null);
        stepper("整屏闪刷", "每翻这么多页，整个屏幕黑白闪一下，彻底清掉残影（和 Kobo 的“页面刷新”一样）。",
            "KFB_FLASH", new String[] { "不按页数闪", "每页", "每 3 页", "每 6 页", "每 8 页", "每 10 页", "每 20 页" },
            new String[] { "0", "1", "3", "6", "8", "10", "20" }, "6", null);
        if (HostLink.isKobo()) {
            section("夜间与残影（Libra 2）");
            stepper("夜间原生波形（Eclipse）", "在系统反色或应用深色模式下自动切换硬件 GLKW16 / GCK16 波形：黑底更匀、白字更锐利，全刷暗闪不刺眼。",
                "KFB_ECLIPSE", new String[] { "关", "开（默认）" }, new String[] { "0", "1" }, "1", null);
            stepper("暗底压纯黑", "暗色页面中把深灰背景（如 #181818）压成纯黑并轻提白字对比度，消除深灰底斑驳残影；看暗色漫画可设为关。",
                "KFB_DARKCRUSH", new String[] { "关", "轻", "标准（默认）", "强" }, new String[] { "0", "24", "36", "48" }, "36", null);
            stepper("大图后自动清残影", "离开包含大面积插图或深色块的页面时，自动做一次整屏全刷清残影（开启“不按页数闪”时同步停用）。",
                "KFB_HEAVY_FLASH", new String[] { "关", "开（默认）" }, new String[] { "0", "1" }, "1", null);
            stepper("非翻页定时全刷", "开关目录、弹窗、划词等非翻页局部刷新累计达到此次数后自动整屏清残影。",
                "KFB_GCN", new String[] { "关", "每 20 次（默认）", "每 30 次", "每 50 次" }, new String[] { "0", "20", "30", "50" }, "20", null);
            stepper("切换应用首屏全刷", "切换到新应用的第一屏自动全刷一次，防止上一个界面的底影带入新页面。",
                "KFB_NEWWIN", new String[] { "关", "开（默认）" }, new String[] { "0", "1" }, "1", null);
        }
        section("画面");
        stepper("浅色过滤", Panel.LIGHTF_DESC, "KFB_LIGHTF", Panel.LIGHTF_L, Panel.LIGHTF_V, "0", null);
        stepper("深色加深", Panel.DARKEN_DESC, "KFB_DARKEN", new String[] { "关", "开" }, new String[] { "0", "1" }, "0", null);
        LinearLayout r = new LinearLayout(this);
        r.setPadding(0, dp(12), 0, 0);
        r.addView(Ui.button(this, "立即整屏刷新一次", 17, false, new View.OnClickListener() {
            @Override public void onClick(View v) { HostLink.cmd("clear"); }
        }), weight());
        list.addView(r);
    }

    private void smoothNote(String v) {
        if (smoothNote == null) return;
        boolean preset = v != null && !v.equals("0") && v.length() > 0;
        smoothNote.setText(preset ? "现在由档位决定局部 / 整页刷新方式，下面两项改了也不起作用；要单独设先把档位改成“自定义”。" : "");
        smoothNote.setVisibility(preset ? View.VISIBLE : View.GONE);
    }

    // ---- 系统与性能 ----------------------------------------------------------------------------------------------

    private void buildSystem() {
        boolean kobo = HostLink.isKobo();
        if (!kobo) {
            section("Wi-Fi");
            stepper("Wi-Fi 省电", "自动：平时省电，传书开着或大量下载时临时关掉省电；始终省电：下载慢、最省电；运行时关闭：下载快、耗电多。回到 Kobo 和屏保时一律还给 Kobo。",
                "WIFI_PS", new String[] { "自动", "始终省电", "运行时关闭" }, new String[] { "auto", "on", "off" }, "auto", null);
        }
        section("内存");
        stepper("小内存模式", kobo
                ? "自动：512 MB 内存机型（Kobo Libra 2）自动开启，停掉不需要的后台服务并优化内存阈值。下次启动 Android 生效。"
                : "自动：内存不到约 700 MB 的机型自动开。开着时 Kobo 的书库程序停掉腾内存、回 Kobo 完全退出（再进要重新开机）。下次启动 Android 生效。",
            "LOWMEM", new String[] { "自动", "开", "关" }, new String[] { "auto", "on", "off" }, "auto", null);
        if (!kobo) {
            stepper("Android 运行时 Kobo 界面", "只暂停：回 Kobo 最快；冻结：再把 Kobo 的后台程序冻住；停掉：腾出最多内存，回 Kobo 约一分钟。自动：小内存模式用“停掉”，否则“冻结”。下次启动 Android 生效。",
                "KINDLE_UI", new String[] { "自动", "只暂停", "冻结", "停掉" }, new String[] { "auto", "keep", "freeze", "stop" }, "auto", null);
        }
        section("应用预编译");
        stepper("自动优化新装的应用", "装好后在后台把应用编译成机器码，打开更快（微信读书冷启动约快一倍）。自动优化等你 5 分钟不碰屏幕才开始；"
            + "点下面的“立即优化”马上开始。电量低、内存不够、应用在前台、Android 冻结时都会先等。",
            "APP_COMPILE", new String[] { "开", "关" }, new String[] { "auto", "off" }, "auto", null);
        compileView = Ui.text(this, "", 17, false);
        compileView.setPadding(0, dp(6), 0, dp(6));
        list.addView(compileView);
        LinearLayout r = new LinearLayout(this);
        r.addView(Ui.button(this, "立即优化", 17, true, new View.OnClickListener() {
            @Override public void onClick(View v) { HostLink.cmd("compile all"); compileView.setText("已收到，正在检查要优化的应用…"); }
        }), weight());
        list.addView(r);
        showCompile();
        // 进度文件一变就改那一行字（inotify，不轮询）
        compileWatch = new CtlWatch.Listener() {
            @Override public void onCtl(final String path) {
                if ("compile.status".equals(path)) handler.post(new Runnable() { @Override public void run() { showCompile(); } });
            }
        };
        CtlWatch.add(compileWatch);
    }

    @Override protected void onPause() {
        super.onPause();
        if (rotatePending) { handler.removeCallbacks(pendingRotate); pendingRotate.run(); }
    }

    @Override protected void onDestroy() {
        if (compileWatch != null) CtlWatch.remove(compileWatch);
        handler.removeCallbacksAndMessages(null);
        super.onDestroy();
    }

    private String appName(String pkg) {
        try { return getPackageManager().getApplicationLabel(getPackageManager().getApplicationInfo(pkg, 0)).toString(); }
        catch (Exception e) { return pkg; }
    }

    private void showCompile() {
        if (compileView == null) return;
        Map<String, String> m = HostLink.kv(HostLink.CTL + "compile.status");
        String st = m.get("state");
        String s;
        if (st == null) s = "状态：还没有记录（开机 1 分钟后开始检查）";
        else if (st.equals("running")) s = "正在优化 " + appName(String.valueOf(m.get("pkg"))) + "（" + m.get("index") + " / " + m.get("total") + "）";
        else if (st.equals("waiting") || st.equals("paused")) {
            String r = m.get("reason"), msg = m.get("msg"), code = m.get("code"), pkg = m.get("pkg");
            String why = "battery".equals(r) ? "电量低" : "memory".equals(r) ? "内存不够" : "frozen".equals(r) ? "Android 冻结中" : "off".equals(r) ? "已关闭" : String.valueOf(r);
            // 等的是哪个应用（前台 / 还在后台跑）写上名字
            String who = pkg != null && ("foreground".equals(code) || "running".equals(code)) ? appName(pkg) + (("foreground".equals(code)) ? " 在前台，" : " ") : "";
            String head = "starting".equals(code) ? "" : st.equals("paused") ? "暂停：" : "等待：";
            // 宿主给了现成的一句话（等什么、什么时候开始）就直接用
            if (msg != null && msg.length() > 0) s = head + who + msg;
            else s = head + why + "，条件满足后继续";
            if ("1".equals(m.get("manual")) && !"starting".equals(code)) s = "已按“立即优化”。" + s;
            long n = HostLink.num(m, "total", 0);
            if (n > 0) s += "\n还有 " + Math.max(1, n - HostLink.num(m, "index", 0)) + " 个应用要优化";
        } else {
            String msg = m.get("msg");
            s = msg != null && msg.length() > 0 ? msg : "空闲：没有要优化的应用";
        }
        String last = m.get("last");
        if (last != null && last.length() > 0) {
            String[] a = last.split(" ");
            if (a.length >= 2) s += "\n上一个：" + appName(a[0]) + (a[1].equals("ok") ? " 完成" : " 失败") + (a.length >= 3 ? "（" + a[2] + " 秒）" : "");
        }
        compileView.setText(s);
    }
}
