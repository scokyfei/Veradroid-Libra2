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

    /** Query string carrying device_id and account token for authenticated store/font downloads. */
    static String downloadQuery(android.content.Context c) {
        return "device_id=" + enc(Update.deviceId(c)) + "&token=" + enc(Token.get(c));
    }

    /** Short account status label for store buttons and settings rows. */
    static String accountLabel(android.content.Context c) {
        if (!Token.bound(c)) return "登录账号";
        String u = Token.user(c);
        return u.length() > 0 ? u : "已绑定";
    }

    /**
     * Unified 6-digit bind-code login / unbind dialog shared by StoreActivity, FontStoreActivity,
     * BlocksSettings, and HomeActivity.
     */
    static void bindDialog(final android.app.Activity a, final String reason, final Runnable onChanged) {
        if (a == null || a.isFinishing()) return;
        if (Token.bound(a) && (reason == null || reason.length() == 0)) {
            String user = Token.user(a);
            StringBuilder info = new StringBuilder();
            info.append("当前状态：已绑定");
            if (user.length() > 0) info.append("（").append(user).append("）");
            info.append("\n设备 ID：").append(Update.deviceId(a));
            info.append("\n\n可在商店直接下载应用与字体。");
            new VeraDialog.Builder(a)
                .title("商店账号")
                .message(info.toString())
                .items(new String[] { "更换绑定账号（输入新绑定码）", "退出账号绑定" }, new VeraDialog.OnPick() {
                    @Override public void onPick(int which) {
                        if (which == 0) {
                            bindCodeDialog(a, "输入新的 6 位绑定码以切换账号。", onChanged);
                        } else if (which == 1) {
                            Token.clear(a);
                            VeraToast.show(a, "已退出账号绑定");
                            if (onChanged != null) onChanged.run();
                        }
                    }
                })
                .negative("关闭", null)
                .show();
            return;
        }
        bindCodeDialog(a, reason, onChanged);
    }

    static void bindCodeDialog(final android.app.Activity a, String reason, final Runnable onChanged) {
        if (a == null || a.isFinishing()) return;
        final android.widget.EditText input = new android.widget.EditText(a);
        input.setHint("6 位数字绑定码");
        input.setSingleLine(true);
        input.setInputType(android.text.InputType.TYPE_CLASS_NUMBER);
        input.setFilters(new android.text.InputFilter[] { new android.text.InputFilter.LengthFilter(6) });
        input.setTextSize(22);
        input.setTextColor(android.graphics.Color.BLACK);
        input.setTypeface(Fonts.typeface(a));
        input.setBackground(Ui.frame(a, false));
        int p = Ui.dp(a, 12);
        input.setPadding(p, Ui.dp(a, 10), p, Ui.dp(a, 10));

        StringBuilder msg = new StringBuilder();
        if (reason != null && reason.length() > 0) msg.append(reason).append("\n\n");
        msg.append("请先在手机或电脑浏览器打开 veradroid.wenjin.jp 注册并登录，在“我的设备”生成 6 位绑定码，填到这里即可下载商店应用与字体。");

        new VeraDialog.Builder(a)
            .title("绑定商店账号")
            .message(msg.toString())
            .view(input)
            .negative("取消", null)
            .positive("绑定", new Runnable() {
                @Override public void run() {
                    final String code = input.getText().toString().trim();
                    if (!code.matches("\\d{6}")) { VeraToast.show(a, "请输入 6 位数字绑定码"); return; }
                    VeraToast.show(a, "正在验证绑定码…");
                    Update.bind(a, code, new Update.BindResult() {
                        @Override public void done(final boolean ok, String message) {
                            if (a.isFinishing()) return;
                            VeraToast.show(a, message);
                            new VeraDialog.Builder(a)
                                .title(ok ? "绑定成功" : "绑定失败")
                                .message(message)
                                .positive("知道了", new Runnable() {
                                    @Override public void run() { if (ok && onChanged != null) onChanged.run(); }
                                }).show();
                        }
                    });
                }
            }).show();
    }
}
