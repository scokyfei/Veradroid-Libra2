package com.veradroid.home;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.security.MessageDigest;

/** What the app store and the font store share: the server address, small JSON / image requests, SHA-256. */
final class StoreNet {
    private StoreNet() { }

    /** 测试时可以让商店问别的服务器（root 才能设：setprop debug.vd.storebase http://测试服务器:端口），平时就是官网。 */
    static String base() {
        try {
            String b = (String) Class.forName("android.os.SystemProperties").getMethod("get", String.class, String.class).invoke(null, "debug.vd.storebase", "");
            if (b != null && b.matches("https?://[A-Za-z0-9.:-]+")) return b;
        } catch (Throwable ignored) { }
        return "https://veradroid.wenjin.jp";
    }

    static String enc(String s) {
        try { return URLEncoder.encode(s == null ? "" : s, "UTF-8"); } catch (Exception e) { return ""; }
    }

    static JSONObject json(String url) throws Exception {
        HttpURLConnection h = (HttpURLConnection) new URL(url).openConnection();
        h.setConnectTimeout(15000); h.setReadTimeout(30000);
        h.setRequestProperty("User-Agent", "VeraDroid/Store");
        int code = h.getResponseCode();
        InputStream in = code >= 400 ? h.getErrorStream() : h.getInputStream();
        ByteArrayOutputStream bo = new ByteArrayOutputStream();
        byte[] b = new byte[8192]; int n;
        while (in != null && (n = in.read(b)) > 0) bo.write(b, 0, n);
        if (in != null) in.close();
        h.disconnect();
        JSONObject j;
        try { j = new JSONObject(bo.toString("UTF-8")); }
        catch (Exception e) { throw new Exception(code >= 400 ? "HTTP " + code : "服务器的回答看不懂"); }
        if (code >= 400) throw new Exception(j.optString("error", "HTTP " + code));
        return j;
    }

    /**
     * A small picture from the store (app icon, font preview), kept in the cache folder under key (the file's sha256 or
     * the app id, so a changed picture gets a new name). null = not available; nothing is thrown.
     */
    static android.graphics.Bitmap image(String url, String key) {
        if (url == null || url.length() == 0 || key == null || !key.matches("[A-Za-z0-9._-]{1,80}")) return null;
        try {
            File f = new File(Store.cache("store-img"), key);
            if (!f.isFile() || f.length() == 0) {
                HttpURLConnection h = (HttpURLConnection) new URL(url).openConnection();
                try {
                    h.setConnectTimeout(10000); h.setReadTimeout(20000);
                    h.setRequestProperty("User-Agent", "VeraDroid/Store");
                    if (h.getResponseCode() != 200) return null;
                    InputStream in = h.getInputStream();
                    ByteArrayOutputStream bo = new ByteArrayOutputStream();
                    byte[] b = new byte[16384]; int n;
                    while ((n = in.read(b)) > 0) { bo.write(b, 0, n); if (bo.size() > (2 << 20)) { in.close(); return null; } }
                    in.close();
                    File tmp = new File(f.getParentFile(), key + ".tmp." + Thread.currentThread().getId());
                    try {
                        Dl.write(tmp, bo.toByteArray());
                        if (!tmp.renameTo(f)) {
                            Dl.write(f, bo.toByteArray());
                            tmp.delete();
                        }
                    } finally {
                        if (tmp.exists()) tmp.delete();
                    }
                } finally { h.disconnect(); }
            }
            android.graphics.Bitmap bm = android.graphics.BitmapFactory.decodeFile(f.getPath());
            if (bm == null) f.delete();
            return bm;
        } catch (Throwable t) { return null; }
    }

    static String sha256(File f) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        InputStream in = new java.io.FileInputStream(f);
        try { byte[] b = new byte[65536]; int n; while ((n = in.read(b)) > 0) md.update(b, 0, n); } finally { in.close(); }
        StringBuilder sb = new StringBuilder(64);
        for (byte x : md.digest()) sb.append(String.format("%02x", x & 0xff));
        return sb.toString();
    }

    /** Ping the host every minute while a download / install runs: "poke" resets the Kobo's screensaver timer (the same
     * thing a touch does), so the Kobo does not go to the screensaver - which freezes Android - in the middle of it. */
    static Thread keepAwake() {
        Thread k = new Thread(new Runnable() {
            @Override public void run() {
                try { while (true) { HostLink.cmd("poke"); Thread.sleep(60000); } } catch (InterruptedException e) { }
            }
        }, "StoreAwake");
        k.setDaemon(true); k.start();
        return k;
    }

    static String mb(long bytes) {
        if (bytes < (1 << 20)) return Math.max(1, bytes >> 10) + " KB";
        return bytes < (10 << 20) ? String.format("%.1f MB", bytes / 1048576.0) : (bytes >> 20) + " MB";
    }
}
