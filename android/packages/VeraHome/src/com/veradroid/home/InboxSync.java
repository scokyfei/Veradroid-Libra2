// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.security.MessageDigest;

/** Background Send-to-Kobo pickup: download pending mail attachments into Books/. */
final class InboxSync {
    static final String BASE = "https://veradroid.wenjin.jp";
    private static final long EVERY = 15 * 60 * 1000L;

    interface Result { void done(int count, String error); }

    private InboxSync() { }

    static void maybe(final Context c) {
        final SharedPreferences p = Store.prefs(c, "home");
        long now = System.currentTimeMillis();
        if (now - p.getLong("inbox_checked", 0) < EVERY) return;
        p.edit().putLong("inbox_checked", now).commit();
        new Thread(new Runnable() {
            @Override public void run() { sync(c, null); }
        }, "InboxSync").start();
    }

    static void sync(Context c, Result cb) {
        String token = Token.get(c);
        String device = Update.deviceId(c);
        if (token.length() == 0) { if (cb != null) cb.done(0, "还没有绑定账号"); return; }
        int n = 0;
        try {
            String base = BASE + "/api/inbox?device_id=" + enc(device) + "&token=" + enc(token);
            JSONObject list = get(base);
            JSONArray files = list.optJSONArray("files");
            if (files == null) { if (cb != null) cb.done(0, null); return; }
            File dir = new File(Transfer.BOOKS);
            if (!dir.isDirectory() && !dir.mkdirs()) throw new Exception("不能创建 Books 目录");
            for (int i = 0; i < files.length(); i++) {
                JSONObject f = files.getJSONObject(i);
                String name = safe(f.optString("filename", "book.epub"));
                File out = unique(new File(dir, name));
                String url = f.optString("download", "") + "?device_id=" + enc(device) + "&token=" + enc(token);
                download(url, out, f.optString("sha256", ""), f.optLong("size", -1));
                ack(device, token, f.optInt("id", 0));
                n++;
            }
            if (cb != null) cb.done(n, null);
        } catch (Exception e) {
            if (cb != null) cb.done(n, e.getMessage());
        }
    }

    private static void download(String url, File out, String sha, long size) throws Exception {
        HttpURLConnection h = (HttpURLConnection) new URL(url).openConnection();
        h.setConnectTimeout(15000); h.setReadTimeout(180000);
        h.setRequestProperty("User-Agent", "VeraDroid/Inbox");
        int code = h.getResponseCode();
        if (code != 200) throw new Exception("收件下载失败 HTTP " + code);
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        InputStream in = new BufferedInputStream(h.getInputStream(), 65536);
        FileOutputStream fo = new FileOutputStream(out);
        byte[] b = new byte[65536]; int n; long done = 0;
        try {
            while ((n = in.read(b)) > 0) { fo.write(b, 0, n); md.update(b, 0, n); done += n; }
        } catch (Exception e) {
            // 断网 / 读超时：半本书留在 Books 里会出现在书库、打不开，下次同步又多一个 “-2”
            try { fo.close(); } catch (Exception ignored) { }
            out.delete();
            throw e;
        } finally { fo.close(); in.close(); h.disconnect(); }
        if (size > 0 && done != size) { out.delete(); throw new Exception("文件大小不对"); }
        if (sha.length() == 64 && !hex(md.digest()).equalsIgnoreCase(sha)) { out.delete(); throw new Exception("SHA-256 校验失败"); }
        out.setReadable(true, false);
    }

    private static void ack(String device, String token, int id) {
        try {
            byte[] body = ("device_id=" + enc(device) + "&token=" + enc(token)).getBytes("UTF-8");
            HttpURLConnection h = (HttpURLConnection) new URL(BASE + "/api/inbox/" + id + "/ack").openConnection();
            h.setConnectTimeout(10000); h.setReadTimeout(10000);
            h.setDoOutput(true); h.setRequestMethod("POST");
            h.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
            OutputStream o = h.getOutputStream(); o.write(body); o.close();
            h.getResponseCode(); h.disconnect();
        } catch (Exception ignored) { }
    }

    private static JSONObject get(String url) throws Exception {
        HttpURLConnection h = (HttpURLConnection) new URL(url).openConnection();
        h.setConnectTimeout(15000); h.setReadTimeout(30000);
        h.setRequestProperty("User-Agent", "VeraDroid/Inbox");
        int code = h.getResponseCode();
        InputStream in = code >= 400 ? h.getErrorStream() : h.getInputStream();
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        byte[] b = new byte[8192]; int n;
        while (in != null && (n = in.read(b)) > 0) bo.write(b, 0, n);
        if (in != null) in.close();
        h.disconnect();
        JSONObject j = new JSONObject(bo.toString("UTF-8"));
        if (code >= 400) throw new Exception(j.optString("error", "HTTP " + code));
        return j;
    }

    private static File unique(File f) {
        if (!f.exists()) return f;
        String n = f.getName(); int dot = n.lastIndexOf('.');
        String base = dot > 0 ? n.substring(0, dot) : n, ext = dot > 0 ? n.substring(dot) : "";
        for (int i = 2; ; i++) { File x = new File(f.getParentFile(), base + "-" + i + ext); if (!x.exists()) return x; }
    }

    private static String safe(String s) {
        String n = s.replaceAll("[^A-Za-z0-9._\\-\\u4e00-\\u9fff]", "_");
        if (n.length() == 0) n = "book.epub";
        return n.length() > 100 ? n.substring(n.length() - 100) : n;
    }

    private static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format("%02x", x & 0xff));
        return sb.toString();
    }

    private static String enc(String s) throws Exception { return URLEncoder.encode(s == null ? "" : s, "UTF-8"); }
}
