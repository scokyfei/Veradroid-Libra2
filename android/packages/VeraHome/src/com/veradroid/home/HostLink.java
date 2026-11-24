// SPDX-License-Identifier: GPL-3.0-or-later
package com.veradroid.home;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.util.HashMap;
import java.util.Map;

/**
 * The link to the host program (the scripts on the Kobo), all through files in /dev/kfb:
 *   ctl/cmd            a FIFO the host reads one command line from: exit stop restart diag clear invert status apply
 *                      light N, warmth N, wifi 0|1.  (Writing blocks until the host reads, so it runs on its own thread.)
 *   ctl/settings.new   new settings (KEY=value lines); "apply" makes the host take them at once
 *   ctl/status         battery=NN charging=0|1 light=N lightmax=N warmth=N wifi=0|1 invert=0|1  (host -> here)
 *   settings           the host's current settings                                              (host -> here)
 *   ctl/app, ctl/act.* (host -> here) open an app / gesture actions, watched by HostService
 */
final class HostLink {
    static final String KFB = "/dev/kfb/";
    static final String CTL = KFB + "ctl/";

    private HostLink() { }

    // 一条线程按顺序发：宿主没在读 FIFO 时用 O_NONBLOCK 轮询最多 CMD_TIMEOUT_MS 毫秒，避免永久卡死 SENDER。
    private static final long CMD_TIMEOUT_MS = 2000L;
    private static final java.util.concurrent.ExecutorService SENDER = java.util.concurrent.Executors.newSingleThreadExecutor(
        new java.util.concurrent.ThreadFactory() {
            @Override public Thread newThread(Runnable r) { Thread t = new Thread(r, "hostlink"); t.setDaemon(true); return t; }
        });
    private static final java.util.concurrent.ExecutorService EPD_SENDER = java.util.concurrent.Executors.newSingleThreadExecutor(
        new java.util.concurrent.ThreadFactory() {
            @Override public Thread newThread(Runnable r) { Thread t = new Thread(r, "hostlink-epd"); t.setDaemon(true); return t; }
        });

    static void cmd(final String line) {
        SENDER.execute(new Runnable() {
            @Override public void run() {
                writeCmd(line);
            }
        });
    }

    private static void writeCmd(String line) {
        byte[] b = (line + "\n").getBytes();
        long deadline = android.os.SystemClock.uptimeMillis() + CMD_TIMEOUT_MS;
        while (true) {
            java.io.FileDescriptor fd = null;
            try {
                fd = android.system.Os.open(CTL + "cmd",
                        android.system.OsConstants.O_WRONLY | android.system.OsConstants.O_NONBLOCK, 0);
                int off = 0;
                while (off < b.length) {
                    try {
                        int w = android.system.Os.write(fd, b, off, b.length - off);
                        if (w <= 0) return;
                        off += w;
                    } catch (android.system.ErrnoException we) {
                        if (we.errno != android.system.OsConstants.EAGAIN && we.errno != android.system.OsConstants.EINTR) return;
                        long left = deadline - android.os.SystemClock.uptimeMillis();
                        if (left <= 0) return;
                        try { Thread.sleep(Math.min(50L, left)); } catch (InterruptedException ie) { return; }
                    }
                }
                return;
            } catch (android.system.ErrnoException e) {
                if (e.errno != android.system.OsConstants.ENXIO
                        && e.errno != android.system.OsConstants.EAGAIN
                        && e.errno != android.system.OsConstants.ENOENT
                        && e.errno != android.system.OsConstants.EINTR) {
                    return;
                }
            } catch (Throwable ignored) {
                return;
            } finally {
                if (fd != null) try { android.system.Os.close(fd); } catch (Throwable ignored) { }
            }
            long left = deadline - android.os.SystemClock.uptimeMillis();
            if (left <= 0) return;
            try { Thread.sleep(Math.min(50L, left)); } catch (InterruptedException e) { return; }
        }
    }

    /** Hand new settings to the host and make it apply them now. */
    static synchronized boolean settings(String lines) {
        // 同步 + 合并：界面线程和传书网页的线程会同时改设置。以前两次共用一个 settings.tmp，后一次改名失败（网页得到 ok:false），
        // 或者后一次把宿主还没取走的 settings.new 整个盖掉，前一次的改动就丢了。现在宿主没取走的那份留着，新的行接在后面（后面的优先）。
        try {
            File tmp = new File(CTL + "settings.tmp");
            String pending = "";
            File cur = new File(CTL + "settings.new");
            if (cur.isFile()) {
                try {
                    byte[] b = HostReq.read(cur, 65536);
                    pending = new String(b, "UTF-8");
                    if (pending.length() > 0 && !pending.endsWith("\n")) pending += "\n";
                } catch (Exception ignored) { pending = ""; }
            }
            FileWriter w = new FileWriter(tmp);
            w.write(pending + lines);
            w.close();
            if (!tmp.renameTo(new File(CTL + "settings.new"))) return false;
            cmd("apply");
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * 宿主的状态文件和显示设置文件（status / settings）：搭一页时、预搭时、签名里一再读同一个文件（开机时一秒里几十次）。
     * 一秒半之内、文件的修改时间、大小与 inode 都没变就用刚读过的那份（给调用方一份拷贝）。
     * 结合 inode 校验可避免同秒等长原子替换（tmp -> mv，如反色 0->1、亮度 12->24）命中旧缓存。
     */
    private static final class Kv { long at, mtime, len, ino; Map<String, String> m; }
    private static final Map<String, Kv> KV_CACHE = new HashMap<String, Kv>();

    static long inode(String path) {
        try { return android.system.Os.stat(path).st_ino; }
        catch (Throwable ignored) { return -1L; }
    }

    /** ctl/status 叠加 Android 实时电量 / 充电广播（healthd，宿主每分钟 bat_poke_tick 刷新）。 */
    static Map<String, String> status(android.content.Context c) {
        Map<String, String> st = new HashMap<String, String>(kv(CTL + "status"));
        try {
            android.content.Intent b = c.getApplicationContext().registerReceiver(null, new android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED));
            if (b != null && b.getBooleanExtra(android.os.BatteryManager.EXTRA_PRESENT, true)) {
                int lv = b.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1), sc = b.getIntExtra(android.os.BatteryManager.EXTRA_SCALE, 100);
                if (lv >= 0 && sc > 0) {
                    st.put("battery", String.valueOf(lv * 100 / sc));
                    st.put("charging", b.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) == android.os.BatteryManager.BATTERY_STATUS_CHARGING ? "1" : "0");
                }
            }
        } catch (Throwable ignored) { }
        return st;
    }

    static Map<String, String> kv(String path) {
        boolean hot = path.equals(CTL + "status") || path.equals(KFB + "settings");
        if (!hot) return kv0(path);
        java.io.File f = new java.io.File(path);
        long now = android.os.SystemClock.uptimeMillis(), mt = f.lastModified(), len = f.length(), ino = inode(path);
        synchronized (KV_CACHE) {
            Kv k = KV_CACHE.get(path);
            if (k != null && now - k.at < 1500 && k.mtime == mt && k.len == len && ino >= 0 && k.ino == ino) {
                return new HashMap<String, String>(k.m);
            }
        }
        Map<String, String> m = kv0(path);
        Kv k = new Kv();
        k.at = now; k.mtime = mt; k.len = len; k.ino = ino; k.m = new HashMap<String, String>(m);
        synchronized (KV_CACHE) { KV_CACHE.put(path, k); }
        return m;
    }

    private static Map<String, String> kv0(String path) {
        Map<String, String> m = new HashMap<String, String>();
        try {
            BufferedReader r = new BufferedReader(new FileReader(path));
            String line;
            while ((line = r.readLine()) != null) {
                int eq = line.indexOf('=');
                if (eq > 0) m.put(line.substring(0, eq).trim(), line.substring(eq + 1).trim());
            }
            r.close();
        } catch (Exception ignored) { }
        return m;
    }

    static int num(Map<String, String> m, String key, int def) {
        try { return Integer.parseInt(m.get(key)); } catch (Exception e) { return def; }
    }

    /** True when running on a Kobo host (e.g. Kobo Libra 2, imageclass=kobo-libra2). */
    static boolean isKobo() {
        Map<String, String> st = kv(CTL + "status");
        String ic = st.get("imageclass");
        if (ic != null && ic.startsWith("kobo")) return true;
        String m = st.get("model");
        if (m != null && (m.toLowerCase(java.util.Locale.US).contains("kobo") || m.toLowerCase(java.util.Locale.US).contains("libra"))) return true;
        try {
            byte[] b = HostReq.read(new File(KFB + "model"), 64);
            String s = new String(b, "UTF-8").trim().toLowerCase(java.util.Locale.US);
            if (s.startsWith("libra") || s.startsWith("kobo")) return true;
        } catch (Exception ignored) { }
        return false;
    }

    /**
     * One-shot hint to the display bridge (/dev/kfb/epd.fifo, see display/epd.c HINT): for the next ms, changes of at least pct %
     * of the screen go out as REAGL instead of DU. Used when the pull-down panel opens / closes: drawn with DU, the page under it
     * shone through ("ghost text under the panel"). Non-blocking: no bridge reading the FIFO = the hint is simply dropped.
     */
    static void epdHint(final int ms, final int pct) {
        EPD_SENDER.execute(new Runnable() {
            @Override public void run() {
                java.io.FileDescriptor fd = null;
                try {
                    fd = android.system.Os.open(KFB + "epd.fifo", android.system.OsConstants.O_WRONLY | android.system.OsConstants.O_NONBLOCK, 0);
                    byte[] b = ("HINT " + ms + " " + pct + "\n").getBytes();
                    android.system.Os.write(fd, b, 0, b.length);
                } catch (Throwable ignored) {
                } finally {
                    if (fd != null) try { android.system.Os.close(fd); } catch (Throwable ignored) { }
                }
            }
        });
    }

    /** 发一行命令给显示桥的 FIFO（/dev/kfb/epd.fifo），不阻塞：桥没在读就丢掉。用于 SWIPE（方块风格的换页 / 设置单动画）。 */
    /**
     * 发一行命令给显示桥的 FIFO（/dev/kfb/epd.fifo）。直接在调用的线程上写（非阻塞打开，桥没在读就丢掉，不到 1 ms）：
     * SWIPE 必须在这一帧的“P n”之前进到 FIFO，放到别的线程上会有一半赶不上。
     */
    static void epd(String line) {
        java.io.FileDescriptor fd = null;
        try {
            fd = android.system.Os.open(KFB + "epd.fifo", android.system.OsConstants.O_WRONLY | android.system.OsConstants.O_NONBLOCK, 0);
            byte[] b = (line + "\n").getBytes();
            android.system.Os.write(fd, b, 0, b.length);
        } catch (Throwable ignored) {
        } finally {
            if (fd != null) try { android.system.Os.close(fd); } catch (Throwable ignored) { }
        }
    }

    /** Ask the panel to redraw everything with a flashing refresh (clears ghosts). Delayed so the new picture is ready. */
    static void flashSoon(android.os.Handler h) {
        h.postDelayed(new Runnable() { @Override public void run() { cmd("clear"); } }, 500);
    }
}
