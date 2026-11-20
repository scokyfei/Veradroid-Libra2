package com.veradroid.home;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import java.io.File;
import java.util.Map;

/**
 * 无线调试（adb over Wi-Fi）：默认关，开着时电脑用 `adb connect <Kobo 的地址>:5555` 连进 Android 管理文件和应用
 * （adb push / pull / install / shell）。只认用户自己电脑的 adb 公钥（~/.android/adbkey.pub，在传书网页“SSH 与诊断”里添加，
 * 或插 USB 拷成 Kobo 的 veradroid/adb/adb_keys），到时间自动关。真正的开关、公钥和端口都在宿主（webadmin.sh 的 adb*）。
 * 没有 IPv6 的老机型内核上 Android 7.1 的 adbd 开不了监听，宿主会回 noipv6。
 */
final class AdbWifi {
    private AdbWifi() { }

    static final int PORT = 5555;
    static final int[] MINUTES = { 15, 30, 60, 120 };

    static int minutes(int m) { return Math.max(5, Math.min(240, m)); }

    /** 宿主写的 /dev/kfb/ctl/adb.on（"到期 uptime 分钟数"）：只用来显示开关状态。 */
    static boolean on() { return new File(HostLink.CTL + "adb.on").exists(); }

    static String error(String e) {
        if (e.equals("noipv6")) return "这台 Kobo 的内核没有 IPv6，Android 7.1 的 adb 在它上面开不了无线调试；请用传书网页或 USB 管理文件";
        if (e.equals("nokey")) return "还没有 adb 公钥：先在传书网页的“SSH 与诊断”里添加电脑上 ~/.android/adbkey.pub 的内容";
        if (e.equals("notbooted")) return "Android 还没开机完成，请稍后再试";
        if (e.equals("badkey")) return "公钥格式不对：要的是电脑上 ~/.android/adbkey.pub 里那一整行（QAAAA 开头）";
        if (e.equals("toomany")) return "公钥太多了（最多 10 把）";
        if (e.equals("symlink")) return "公钥文件是一个链接，拒绝写入";
        if (e.equals("fwd") || e.equals("noslirp")) return "端口 5555 没能放行到 Android（网络转发失败）";
        if (e.equals("start")) return "adbd 没有起来（看 VeraDroid 运行日志）";
        if (e.equals("insecure")) return "没能打开 adb 的公钥验证，为了安全不打开无线调试";
        return "失败：" + e;
    }

    /** adbkey.pub 的一行：base64 正好 700 个字符（524 字节、开头是 64 位字长的 RSA 公钥），后面可带一个简单注释。返回规范化的行或 null。 */
    static String checkKey(String s, String[] why) {
        why[0] = "公钥格式不对：要的是电脑上 ~/.android/adbkey.pub 里那一整行（QAAAA 开头）";
        if (s == null) return null;
        if (s.contains("PRIVATE KEY")) { why[0] = "这是私钥（adbkey）！请改用同一个文件夹里的 adbkey.pub"; return null; }
        s = s.replace("﻿", "").trim();
        if (s.indexOf('\n') >= 0 || s.indexOf('\r') >= 0) { why[0] = "一次只能添加一把公钥（一行）"; return null; }
        String[] f = s.split("[ \t]+");
        if (f.length < 1 || f[0].length() != 700 || !f[0].matches("QAAAA[A-Za-z0-9+/]+={0,2}")) return null;
        byte[] blob;
        try { blob = android.util.Base64.decode(f[0], android.util.Base64.NO_WRAP); } catch (Exception e) { return null; }
        if (blob.length != 524 || blob[0] != 64 || blob[1] != 0 || blob[2] != 0 || blob[3] != 0) return null;
        StringBuilder c = new StringBuilder();
        for (int i = 1; i < f.length; i++) {
            String w = f[i].replaceAll("[^A-Za-z0-9@._+:=-]", "");
            if (w.length() == 0) continue;
            if (c.length() > 0) c.append('_');
            c.append(w);
        }
        String comment = c.length() > 60 ? c.substring(0, 60) : c.toString();
        return f[0] + (comment.length() > 0 ? " " + comment : "");
    }

    /** 设置里的开关：在后台问宿主，结果用提示条说；done 在主线程跑。设备上的开关不再要 PIN（人就在 Kobo 前面）。 */
    static void set(final Context c, final boolean on, final int min, final Runnable done) {
        new Thread(new Runnable() { @Override public void run() {
            final Map<String, String> kv = HostReq.kv(HostReq.run(c, on ? "adbstart" : "adbstop", on ? String.valueOf(minutes(min)) : null, null, 30000));
            new Handler(Looper.getMainLooper()).post(new Runnable() { @Override public void run() {
                String err = kv.get("adb.error");
                if (kv.isEmpty()) VeraToast.show(c, "宿主没有回应（VeraDroid 宿主程序是不是旧版本？）");
                else if (err != null) VeraToast.show(c, error(err));
                else if (on) {
                    String ip = kv.get("adb.ip");
                    VeraToast.show(c, "无线调试已打开：电脑上 adb connect " + (ip == null || ip.length() == 0 ? "<Kobo 的地址>" : ip) + ":" + PORT + "，" + minutes(min) + " 分钟后自动关闭");
                } else VeraToast.show(c, "无线调试已关闭");
                if (done != null) done.run();
            } });
        } }, "adb-wifi").start();
    }

    /** 设置行的说明文字。 */
    static final String DESC = "电脑和 Kobo 连同一个 Wi-Fi，用 adb connect 连进 Android 传文件、装应用（adb push / pull / install）。"
        + "只认你在传书网页里添加过的电脑公钥；打开后这台电脑能完全控制 Android，用完请关，到时间也会自动关。";
}
