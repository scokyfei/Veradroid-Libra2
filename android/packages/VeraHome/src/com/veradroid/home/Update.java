// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;

import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.security.MessageDigest;

/**
 * Small OTA client: asks veradroid.wenjin.jp for a newer VeraHome APK, checks SHA-256 and asks the host to
 * install it.  The host has root in the container, so the update does not need a package-installer dialog.
 * The APK is accepted only if it has the same platform signature (PackageManager enforces that).
 */
final class Update {
    private static final String BASE = "https://veradroid.wenjin.jp";
    private static final long EVERY_MS = 6 * 60 * 60 * 1000L;
    private static final Object CHECK_LOCK = new Object();

    private Update() { }

    static void maybe(final Context c) {
        final SharedPreferences p = Store.prefs(c, "home");
        if (!p.getBoolean("autoupdate", true)) return;
        long now = System.currentTimeMillis();
        if (now - p.getLong("update_checked", 0) < EVERY_MS) return;
        p.edit().putLong("update_checked", now).commit();
        new Thread(new Runnable() {
            @Override public void run() {
                try {
                    synchronized (CHECK_LOCK) { check(c); }
                } catch (Throwable e) { android.util.Log.e("VeraUpdate", "check failed", e); }
            }
        }, "VeraUpdate").start();
    }

    private static String check(Context c) throws Exception {
        int versionCode = c.getPackageManager().getPackageInfo(c.getPackageName(), 0).versionCode;
        String versionName = c.getPackageManager().getPackageInfo(c.getPackageName(), 0).versionName;
        String device = deviceId(c);
        String token = Token.get(c);
        String url = BASE + "/api/ota/check?package=" + enc("com.veradroid.home")
            + "&version_code=" + versionCode
            + "&version_name=" + enc(versionName)
            + "&device_id=" + enc(device)
            + "&model=" + enc(model(c))
            + (token.length() > 0 ? "&token=" + enc(token) : "");
        JSONObject j = new JSONObject(get(url));
        android.util.Log.d("VeraUpdate", "json " + j);
        if (!j.optBoolean("update", false)) return "已是最新版本";
        long size = j.optLong("size", -1);
        String sha = j.optString("sha256", "");
        String apk = j.optString("url", "");
        android.util.Log.d("VeraUpdate", "download " + apk + " sha=" + sha + " size=" + size);
        if (apk.length() == 0 || sha.length() != 64) return "更新信息不完整";

        File dir = Transfer.tmpDir();
        if (!dir.isDirectory() && !dir.mkdirs()) { android.util.Log.e("VeraUpdate", "no dir " + dir); return "无法创建下载目录"; }
        File out = new File(dir, "ota.apk");
        out.delete();   // a leftover from an older install can belong to another uid: it cannot be overwritten, only replaced
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        HttpURLConnection h = (HttpURLConnection) new URL(apk).openConnection();
        h.setConnectTimeout(20000); h.setReadTimeout(120000);
        h.setRequestProperty("User-Agent", "VeraDroid/OTA");
        InputStream in = new BufferedInputStream(h.getInputStream(), 65536);
        FileOutputStream fo = new FileOutputStream(out);
        byte[] buf = new byte[65536];
        long done = 0; int n;
        try {
            while ((n = in.read(buf)) > 0) {
                fo.write(buf, 0, n);
                md.update(buf, 0, n);
                done += n;
            }
        } finally { fo.close(); in.close(); h.disconnect(); }
        if ((size > 0 && done != size) || !hex(md.digest()).equalsIgnoreCase(sha)) {
            out.delete();
            return "下载校验失败";
        }
        out.setReadable(true, false);
        android.util.Log.d("VeraUpdate", "downloaded " + out.length() + " installing");
        HostLink.cmd("install " + out.getAbsolutePath());   // absolute path: the staging folder is not always .upload
        return "发现新版本，正在下载并安装…";
    }

    /** Hardware model from the host (pw6/pw5/kt5...); Android's Build.MODEL is generic. */
    static String model(Context c) {
        for (String p : new String[] { "/dev/kfb/model", "/mnt/base-us/system/veradroid/model", "/mnt/base-us/veradroid/model" }) {
            try {
                File f = new File(p);
                if (!f.isFile()) continue;
                BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(f), "UTF-8"));
                String s = r.readLine();
                r.close();
                if (s != null) {
                    s = s.trim();
                    if (s.matches("[A-Za-z0-9_-]{2,32}")) return s;
                }
            } catch (Throwable ignored) { }
        }
        return Build.MODEL;
    }

    static String deviceId(Context c) {
        // Prefer the host-persisted id in /mnt/base-us/veradroid/device-id.
        // It survives a factory reset of /data; Android ID does not.
        for (String path : new String[] { "/data/media/0/.veradroid/device-id", "/mnt/base-us/veradroid-device-id", "/mnt/us/veradroid-device-id", "/mnt/base-us/veradroid/device-id", "/mnt/us/veradroid/device-id" }) {
            try {
                File f = new File(path);
                if (!f.isFile()) continue;
                BufferedReader r = new BufferedReader(new InputStreamReader(new FileInputStream(f), "UTF-8"));
                String s = r.readLine();
                r.close();
                if (s != null) {
                    s = s.trim();
                    if (s.matches("[A-Za-z0-9_-]{6,64}")) return s;
                }
            } catch (Throwable ignored) { }
        }
        String device = Settings.Secure.getString(c.getContentResolver(), Settings.Secure.ANDROID_ID);
        if (device == null || device.length() < 6) device = "unknown-" + Build.SERIAL;
        return device;
    }

    /** Check for a VeraHome APK update immediately (manual "check now"). */
    static void now(final Context c) {
        new Thread(new Runnable() {
            @Override public void run() {
                String msg;
                try {
                    synchronized (CHECK_LOCK) { msg = check(c); }
                }
                catch (Throwable e) {
                    android.util.Log.e("VeraUpdate", "manual check failed", e);
                    msg = "检查更新失败，请检查网络";
                }
                final String fm = msg;
                new Handler(Looper.getMainLooper()).post(new Runnable() {
                    @Override public void run() { VeraToast.show(c, fm); }
                });
            }
        }, "VeraUpdateNow").start();
    }

    interface BindResult { void done(boolean ok, String message); }

    /** Bind this machine to the account that generated a 6-digit code on the website. */
    static void bind(final Context c, final String code, final BindResult cb) {
        new Thread(new Runnable() {
            @Override public void run() {
                String msg = "网络错误";
                boolean ok = false;
                try {
                    JSONObject body = new JSONObject();
                    body.put("code", code);
                    body.put("device_id", deviceId(c));
                    body.put("model", model(c));
                    body.put("version_code", c.getPackageManager().getPackageInfo(c.getPackageName(), 0).versionCode);
                    body.put("version_name", c.getPackageManager().getPackageInfo(c.getPackageName(), 0).versionName);
                    JSONObject j = postJson(BASE + "/api/device/bind", body.toString());
                    ok = j.optBoolean("ok", false);
                    if (ok) {
                        Token.put(c, j.optString("token", ""));
                        msg = "已绑定这台 Kobo";
                    } else {
                        msg = j.optString("error", "绑定失败");
                    }
                } catch (Throwable e) {
                    msg = String.valueOf(e.getMessage());
                }
                final boolean fok = ok; final String fm = msg;
                new Handler(Looper.getMainLooper()).post(new Runnable() {
                    @Override public void run() { cb.done(fok, fm); }
                });
            }
        }, "VeraBind").start();
    }

    private static JSONObject postJson(String url, String body) throws Exception {
        HttpURLConnection h = (HttpURLConnection) new URL(url).openConnection();
        h.setConnectTimeout(15000); h.setReadTimeout(30000);
        h.setRequestMethod("POST");
        h.setDoOutput(true);
        h.setRequestProperty("Content-Type", "application/json; charset=utf-8");
        h.setRequestProperty("User-Agent", "VeraDroid/Bind");
        java.io.OutputStream o = h.getOutputStream();
        o.write(body.getBytes("UTF-8")); o.close();
        InputStream in = h.getResponseCode() >= 400 ? h.getErrorStream() : h.getInputStream();
        java.io.ByteArrayOutputStream bo = new java.io.ByteArrayOutputStream();
        byte[] b = new byte[4096]; int n;
        while (in != null && (n = in.read(b)) > 0) bo.write(b, 0, n);
        if (in != null) in.close();
        int code = h.getResponseCode();
        h.disconnect();
        JSONObject j = new JSONObject(bo.toString("UTF-8"));
        if (code >= 400 && j.optString("error", "").length() == 0) j.put("error", "HTTP " + code);
        return j;
    }

    private static String enc(String s) throws Exception { return URLEncoder.encode(s == null ? "" : s, "UTF-8"); }

    private static String get(String url) throws Exception {
        HttpURLConnection h = (HttpURLConnection) new URL(url).openConnection();
        h.setConnectTimeout(15000); h.setReadTimeout(30000);
        h.setRequestProperty("User-Agent", "VeraDroid/OTA");
        try {
            InputStream in = h.getInputStream();
            java.io.ByteArrayOutputStream bo = new java.io.ByteArrayOutputStream();
            byte[] b = new byte[8192]; int n;
            while ((n = in.read(b)) > 0) bo.write(b, 0, n);
            in.close();
            return bo.toString("UTF-8");
        } finally { h.disconnect(); }
    }

    private static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format("%02x", x & 0xff));
        return sb.toString();
    }
}
