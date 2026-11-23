// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * KoboWeReadOpt — Zero-APK-modification runtime optimizer for WeRead e-ink 1.9.7
 * on Kobo Libra 2 (512 MB RAM, single-core Cortex-A9).
 *
 * Loaded via DexClassLoader from libkobo_madvise.so ONLY inside
 * com.tencent.weread.eink and com.tencent.weread.eink:seg processes.
 *
 * Adapted from scokyfei/Koboweread (GPL-3.0):
 *  1. FontSizeCache     — caches FontSizeManager.getCurrentFontSize() in layout/hierarchy
 *                         listeners (eliminates LevelDB + JSON reads on every TextView).
 *  2. ReaderPageRelease — unregisters leaked off-screen Page$1 observers from
 *                         BookProgressImpl.mChapterProgress every 30s (~0.2 MB/page).
 *  3. SegDictRelease    — releases the ~21 MB IK segmentation dictionary
 *                         (moai.ik.dic.Dictionary.singleton) in :seg when idle and
 *                         returns heap pages via concurrentGC() + trimHeap().
 */
import android.app.Activity;
import android.app.Application;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.database.DataSetObservable;
import android.database.DataSetObserver;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;
import android.util.SparseArray;
import android.view.View;
import android.view.ViewGroup;
import android.content.res.AssetManager;
import android.graphics.Typeface;
import android.util.LruCache;
import android.widget.TextView;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.HashSet;
import java.util.IdentityHashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

public final class KoboWeReadOpt {
    private static final String TAG = "KoboWeRead";
    private static volatile boolean started;

    public static void init(Application app, String procName) {
        if (started || app == null || procName == null) return;
        started = true;
        if ("com.tencent.weread.eink".equals(procName)) {
            Log.i(TAG, "OPT_INIT proc=main");
            FontMap.start(app);
            FontSizeCache.start(app);
            SyncThrottle.start(app);
            MarkUsersCache.start(app);
            ReaderPageRelease.start(app);
            ChapterPrefetch.start(app);
            MemoryTrim.start(true);
            RMonitorStopper.start(app);
            SegPrestart.start(app);
            OpenBoost.start(app);
        } else if ("com.tencent.weread.eink:seg".equals(procName)) {
            Log.i(TAG, "OPT_INIT proc=seg");
            SegDictRelease.start(app);
            MemoryTrim.start(false);
        }
    }

    /* ========================================================================
     * 0. SegPrestart (adapted from Koboweread SegPrestart.java)
     *    Pre-starts WeRead's word-segmentation service (process :seg) ~4s after
     *    WeRead main starts, so :seg forks and initializes while idle on the
     *    bookshelf instead of competing for the single CPU core during the
     *    first book open.
     * ======================================================================== */
    static final class SegPrestart implements Runnable {
        private final Application app;

        private SegPrestart(Application app) {
            this.app = app;
        }

        static void start(Application app) {
            if (new File("/data/local/tmp/kobo-segprestart-disabled").exists()) return;
            Thread t = new Thread(new SegPrestart(app), "kobo-seg-prestart");
            t.setDaemon(true);
            t.start();
        }

        @Override
        public void run() {
            try {
                Process.setThreadPriority(19);
                Thread.sleep(4000);
                Intent intent = new Intent().setComponent(new ComponentName(
                        "com.tencent.weread.eink",
                        "com.tencent.weread.reader.segment.aidl.SegmentService"));
                ComponentName cn = app.startService(intent);
                Log.i(TAG, "SEG_PRESTART result=" + cn);
            } catch (Throwable t) {
                Log.w(TAG, "SEG_PRESTART err=" + t);
            }
        }
    }

    /* ========================================================================
     * 0b. OpenBoost — yield background pools (nice 16, still above :seg's 19)
     *     for 2.5s when ReaderFragmentActivity is created so main (-10) and
     *     TypeSetting (-6) own the single Cortex-A9 core during initial layout.
     * ======================================================================== */
    static final class OpenBoost implements Application.ActivityLifecycleCallbacks {
        private static final long BOOST_MS = 2500;
        private final Handler handler = new Handler(Looper.getMainLooper());
        private final Runnable restore = new Runnable() {
            @Override public void run() { applyPoolNice(10, 0); }
        };

        static void start(Application app) {
            app.registerActivityLifecycleCallbacks(new OpenBoost());
            Log.i(TAG, "OPEN_BOOST ready ms=" + BOOST_MS);
        }

        private static void applyPoolNice(int poolNice, int rxNice) {
            File taskDir = new File("/proc/self/task");
            String[] tids = taskDir.list();
            if (tids == null) return;
            for (String s : tids) {
                int tid;
                try { tid = Integer.parseInt(s); } catch (NumberFormatException e) { continue; }
                BufferedReader br = null;
                try {
                    br = new BufferedReader(new FileReader("/proc/self/task/" + s + "/comm"));
                    String comm = br.readLine();
                    if (comm == null) continue;
                    if (comm.startsWith("WRCommonPool") || comm.startsWith("WRNetworkPool") ||
                        comm.startsWith("MPool") || comm.startsWith("OkHttp")) {
                        Process.setThreadPriority(tid, poolNice);
                    } else if (comm.startsWith("RxComputation") || comm.startsWith("RxIoScheduler")) {
                        Process.setThreadPriority(tid, rxNice);
                    }
                } catch (Throwable ignored) {
                } finally {
                    try { if (br != null) br.close(); } catch (Throwable ignored) {}
                }
            }
        }

        @Override public void onActivityCreated(Activity a, Bundle b) {
            if (a != null && "com.tencent.weread.ReaderFragmentActivity".equals(a.getClass().getName())) {
                applyPoolNice(16, 16);
                handler.removeCallbacks(restore);
                handler.postDelayed(restore, BOOST_MS);
            }
        }
        @Override public void onActivityStarted(Activity a) {}
        @Override public void onActivityResumed(Activity a) {}
        @Override public void onActivityPaused(Activity a) {}
        @Override public void onActivityStopped(Activity a) {}
        @Override public void onActivitySaveInstanceState(Activity a, Bundle b) {}
        @Override public void onActivityDestroyed(Activity a) {}
    }

    static Method findMethod(Class<?> c, String name, Class<?>... types) throws NoSuchMethodException {
        for (Class<?> k = c; k != null; k = k.getSuperclass()) {
            try {
                Method m = k.getDeclaredMethod(name, types);
                m.setAccessible(true);
                return m;
            } catch (NoSuchMethodException ignored) {
            }
        }
        throw new NoSuchMethodException(c.getName() + "." + name);
    }

    static int readMemAvailableKb() {
        BufferedReader in = null;
        try {
            in = new BufferedReader(new FileReader("/proc/meminfo"));
            String line;
            while ((line = in.readLine()) != null) {
                if (line.startsWith("MemAvailable:")) {
                    String[] parts = line.substring(13).trim().split("\\s+");
                    return Integer.parseInt(parts[0]);
                }
            }
        } catch (Throwable ignored) {
        } finally {
            try { if (in != null) in.close(); } catch (Throwable ignored) {}
        }
        return -1;
    }

    static Field findField(Class<?> c, String name) throws NoSuchFieldException {
        for (Class<?> k = c; k != null; k = k.getSuperclass()) {
            try {
                Field f = k.getDeclaredField(name);
                f.setAccessible(true);
                return f;
            } catch (NoSuchFieldException ignored) {
            }
        }
        throw new NoSuchFieldException(c.getName() + "." + name);
    }

    static int readSelfRssKb() {
        BufferedReader in = null;
        try {
            in = new BufferedReader(new FileReader("/proc/self/status"));
            String line;
            while ((line = in.readLine()) != null) {
                if (line.startsWith("VmRSS:")) {
                    String[] parts = line.substring(6).trim().split("\\s+");
                    return Integer.parseInt(parts[0]);
                }
            }
        } catch (Throwable ignored) {
        } finally {
            try { if (in != null) in.close(); } catch (Throwable ignored) {}
        }
        return -1;
    }

    /* ---------------------------------------------------------------------- */
    /* 1. FontSizeCache                                                       */
    /* ---------------------------------------------------------------------- */
    private static final class FontSizeCache implements Runnable {
        private static final String FSM = "com.tencent.weread.fontsize.FontSizeManager";
        private static final long TTL_MS = 2000;
        private static FontSizeCache instance;

        private final Application app;
        private final Handler handler;
        private Object fsm, oldLayout, oldHierarchy, changeListener;
        private Field layoutField, hierarchyField, listenerInfoField, layoutListenersField, groupHierarchyField;
        private Method getCurrent, hModeGetter, isFunctionOfArity, function1Invoke;
        private Object hModeHolder, hierarchyMode;
        private Class<?> qqFaceView;
        private int tagLogic, tagCurrent;
        private int cached = Integer.MIN_VALUE;
        private long cachedAt;
        private boolean active, failed;
        private long reads, hits;
        private int walks, quietWalks, polls;

        final View.OnLayoutChangeListener layout = new View.OnLayoutChangeListener() {
            public void onLayoutChange(View v, int l, int t, int r, int b, int ol, int ot, int or, int ob) {
                if (!active) {
                    ((View.OnLayoutChangeListener) oldLayout).onLayoutChange(v, l, t, r, b, ol, ot, or, ob);
                    return;
                }
                try {
                    if (!(v instanceof ViewGroup)) return;
                    ViewGroup g = (ViewGroup) v;
                    int n = g.getChildCount();
                    for (int i = 0; i < n; i++) {
                        View c = g.getChildAt(i);
                        if (c != null && !matches(c)) dispatch(c);
                    }
                } catch (Throwable err) {
                    fail(err);
                }
            }
        };

        final ViewGroup.OnHierarchyChangeListener hierarchy = new ViewGroup.OnHierarchyChangeListener() {
            public void onChildViewAdded(View parent, View child) {
                if (!active) {
                    ((ViewGroup.OnHierarchyChangeListener) oldHierarchy).onChildViewAdded(parent, child);
                    return;
                }
                try {
                    if (child != null && !matches(child)) dispatch(child);
                } catch (Throwable err) {
                    fail(err);
                }
            }
            public void onChildViewRemoved(View parent, View child) {}
        };

        private FontSizeCache(Application app, Handler handler) {
            this.app = app;
            this.handler = handler;
        }

        static void start(final Application app) {
            if (new File("/data/local/tmp/kobo-fontcache-disabled").exists()) {
                Log.i(TAG, "FONTSIZE_CACHE disabled");
                return;
            }
            Looper main = Looper.getMainLooper();
            if (main == null) return;
            Handler h = new Handler(main);
            instance = new FontSizeCache(app, h);
            h.postDelayed(instance, 500);
        }

        public void run() {
            if (failed) return;
            try {
                if (!active) {
                    if (++polls > 600) {
                        Log.i(TAG, "FONTSIZE_CACHE no_activity");
                        return;
                    }
                    Object at = Class.forName("android.app.ActivityThread")
                            .getMethod("currentActivityThread").invoke(null);
                    if (at == null) { handler.postDelayed(this, 100); return; }
                    Map<?, ?> acts = (Map<?, ?>) findField(at.getClass(), "mActivities").get(at);
                    if (acts == null || acts.isEmpty()) { handler.postDelayed(this, 100); return; }
                    install(app.getClassLoader());
                    handler.postDelayed(this, 5000);
                    return;
                }
                int replaced = walkWindows();
                walks++;
                quietWalks = (replaced == 0) ? (quietWalks + 1) : 0;
                Log.i(TAG, "FONTSIZE_CACHE walk=" + walks + " replaced=" + replaced
                        + " reads=" + reads + " hits=" + hits);
                if (quietWalks < 3) handler.postDelayed(this, walks < 2 ? 30000 : 60000);
            } catch (Throwable err) {
                fail(err);
            }
        }

        private void install(ClassLoader cl) throws Exception {
            Class<?> m = Class.forName(FSM, true, cl);
            fsm = findField(m, "INSTANCE").get(null);
            getCurrent = m.getMethod("getCurrentFontSize");
            getCurrent.setAccessible(true);
            layoutField = findField(m, "mOnLayoutChangeListener");
            hierarchyField = findField(m, "mOnHierarchyChangeListener");
            oldLayout = layoutField.get(null);
            oldHierarchy = hierarchyField.get(null);

            Class<?> ids = Class.forName("com.tencent.weread.fontsize.R$id", true, cl);
            tagLogic = ids.getField("weread_adaptive_text_size_logic").getInt(null);
            tagCurrent = ids.getField("weread_adaptive_current_text_size").getInt(null);
            qqFaceView = Class.forName("com.qmuiteam.qmui.qqface.QMUIQQFaceView", false, cl);

            Class<?> h = Class.forName("d2.h", true, cl);
            hModeHolder = findField(h, "j").get(null);
            hModeGetter = Class.forName("d2.h$e", false, cl).getMethod("a", ViewGroup.class);
            hModeGetter.setAccessible(true);
            hierarchyMode = findField(Class.forName("d2.h$d", true, cl), "LISTEN_ON_HIERARCHY_CHANGE").get(null);

            isFunctionOfArity = Class.forName("kotlin.jvm.internal.H", true, cl)
                    .getMethod("f", Object.class, int.class);
            isFunctionOfArity.setAccessible(true);
            function1Invoke = Class.forName("l4.l", false, cl).getMethod("invoke", Object.class);
            function1Invoke.setAccessible(true);

            listenerInfoField = findField(View.class, "mListenerInfo");
            layoutListenersField = findField(Class.forName("android.view.View$ListenerInfo"), "mOnLayoutChangeListeners");
            groupHierarchyField = findField(ViewGroup.class, "mOnHierarchyChangeListener");

            if (oldLayout == null || oldHierarchy == null || hModeHolder == null) {
                throw new IllegalStateException("listeners not set");
            }

            final Class<?> iface = Class.forName("com.tencent.weread.fontsize.OnFontSizeChangeListener", false, cl);
            changeListener = Proxy.newProxyInstance(cl, new Class<?>[] { iface }, new InvocationHandler() {
                public Object invoke(Object proxy, Method method, Object[] args) {
                    String n = method.getName();
                    if ("equals".equals(n)) return proxy == args[0];
                    if ("hashCode".equals(n)) return System.identityHashCode(proxy);
                    if ("toString".equals(n)) return "kobo-fontsize-cache";
                    cached = Integer.MIN_VALUE;
                    return null;
                }
            });
            m.getMethod("addFontSizeChangeListener", iface).invoke(fsm, changeListener);
            int size = font();
            layoutField.set(null, layout);
            hierarchyField.set(null, hierarchy);
            active = true;
            int replaced = walkWindows();
            Log.i(TAG, "FONTSIZE_CACHE ready size=" + size + " replaced=" + replaced);
        }

        private int font() throws Exception {
            long now = SystemClock.uptimeMillis();
            if (cached != Integer.MIN_VALUE && now - cachedAt < TTL_MS) {
                hits++;
                return cached;
            }
            reads++;
            cached = (Integer) getCurrent.invoke(fsm);
            cachedAt = now;
            return cached;
        }

        private boolean matches(View v) throws Exception {
            Object cur = v.getTag(tagCurrent);
            return cur instanceof Integer && ((Integer) cur).intValue() == font();
        }

        private void dispatch(View v) throws Exception {
            if (v instanceof ViewGroup) {
                ViewGroup g = (ViewGroup) v;
                if (hModeGetter.invoke(hModeHolder, g) == hierarchyMode) g.setOnHierarchyChangeListener(hierarchy);
                else g.addOnLayoutChangeListener(layout);
                int n = g.getChildCount();
                for (int i = 0; i < n; i++) {
                    View c = g.getChildAt(i);
                    if (c != null) dispatch(c);
                }
                return;
            }
            if (v instanceof TextView) {
                CharSequence cs = ((TextView) v).getText();
                if (cs != null && cs.length() >= 7 && cs.length() <= 14 && cs.toString().contains("上滑显示工具栏")) {
                    if (v.getVisibility() != View.GONE) v.setVisibility(View.GONE);
                    if (v.getParent() instanceof ViewGroup) {
                        ViewGroup p = (ViewGroup) v.getParent();
                        if (p.getChildCount() <= 2 && p.getVisibility() != View.GONE) p.setVisibility(View.GONE);
                    }
                    return;
                }
            }
            if (!(v instanceof TextView) && !qqFaceView.isInstance(v)) return;
            Object logic = v.getTag(tagLogic);
            Object cur = v.getTag(tagCurrent);
            int size = font();
            if (cur instanceof Integer && ((Integer) cur).intValue() == size) return;
            if (!(Boolean) isFunctionOfArity.invoke(null, logic, 1)) return;
            v.setTag(tagCurrent, Integer.valueOf(size));
            function1Invoke.invoke(logic, v);
            v.invalidate();
        }

        private int walkWindows() throws Exception {
            Class<?> wmg = Class.forName("android.view.WindowManagerGlobal");
            Object global = wmg.getMethod("getInstance").invoke(null);
            List<?> roots = (List<?>) findField(wmg, "mRoots").get(global);
            int n = 0;
            Object[] list;
            synchronized (findField(wmg, "mLock").get(global)) {
                list = roots.toArray();
            }
            for (Object root : list) {
                View v = (View) findField(root.getClass(), "mView").get(root);
                if (v != null) {
                    n += swap(v, active ? oldLayout : layout, active ? layout : oldLayout,
                            active ? oldHierarchy : hierarchy, active ? hierarchy : oldHierarchy);
                }
            }
            return n;
        }

        @SuppressWarnings("unchecked")
        private int swap(View v, Object fromL, Object toL, Object fromH, Object toH) throws Exception {
            int n = 0;
            Object info = listenerInfoField.get(v);
            if (info != null) {
                ArrayList<Object> ls = (ArrayList<Object>) layoutListenersField.get(info);
                if (ls != null) {
                    int i = ls.indexOf(fromL);
                    if (i >= 0) {
                        if (ls.contains(toL)) ls.remove(i);
                        else ls.set(i, toL);
                        n++;
                    }
                }
            }
            if (v instanceof ViewGroup) {
                ViewGroup g = (ViewGroup) v;
                if (groupHierarchyField.get(g) == fromH) {
                    groupHierarchyField.set(g, toH);
                    n++;
                }
                int c = g.getChildCount();
                for (int i = 0; i < c; i++) {
                    View child = g.getChildAt(i);
                    if (child != null) n += swap(child, fromL, toL, fromH, toH);
                }
            }
            return n;
        }

        private void fail(Throwable err) {
            Log.w(TAG, "FONTSIZE_CACHE error: " + err);
            if (failed) return;
            failed = true;
            if (!active) return;
            active = false;
            try {
                layoutField.set(null, oldLayout);
                hierarchyField.set(null, oldHierarchy);
                Log.i(TAG, "FONTSIZE_CACHE restored replaced=" + walkWindows());
            } catch (Throwable again) {
                Log.w(TAG, "FONTSIZE_CACHE restore failed: " + again);
            }
        }
    }

    /* ---------------------------------------------------------------------- */
    /* 2. ReaderPageRelease                                                   */
    /* ---------------------------------------------------------------------- */
    private static final class ReaderPageRelease implements Runnable {
        private static final long PERIOD_MS = 30000;
        private static final String PAGE_OBSERVER = "com.tencent.weread.reader.domain.Page$1";

        private final Application app;
        private final Handler handler;
        private Field holderField, actionRefField, delegateField, observersField, outerField, callbackField, progressField;
        private int failures;
        private long released;

        private ReaderPageRelease(Application app, Handler handler) {
            this.app = app;
            this.handler = handler;
        }

        static void start(Application app) {
            if (new File("/data/local/tmp/kobo-pagefix-disabled").exists()) {
                Log.i(TAG, "PAGE_RELEASE disabled");
                return;
            }
            Looper main = Looper.getMainLooper();
            if (main == null) return;
            Handler h = new Handler(main);
            h.postDelayed(new ReaderPageRelease(app, h), PERIOD_MS);
            Log.i(TAG, "PAGE_RELEASE ready period_ms=" + PERIOD_MS);
        }

        public void run() {
            try {
                prune();
                failures = 0;
            } catch (Throwable err) {
                Log.w(TAG, "PAGE_RELEASE error: " + err);
                if (++failures >= 3) {
                    Log.w(TAG, "PAGE_RELEASE stopped");
                    return;
                }
            }
            handler.postDelayed(this, PERIOD_MS);
        }

        private void pruneObservable(DataSetObservable obs, int[] stats) throws Exception {
            ArrayList<?> list = (ArrayList<?>) observersField.get(obs);
            if (list == null || list.isEmpty()) return;
            Object[] observers;
            synchronized (list) { observers = list.toArray(); }
            for (Object observer : observers) {
                if (observer == null) continue;
                String cn = observer.getClass().getName();
                if (!cn.startsWith("com.tencent.weread.reader.domain.Page$")) continue;
                Field outF;
                try { outF = findField(observer.getClass(), "this$0"); } catch (NoSuchFieldException e) { continue; }
                Object page = outF.get(observer);
                if (page == null) continue;
                if (callbackField == null) {
                    callbackField = findField(page.getClass(), "drawViewCallback");
                    try { progressField = findField(page.getClass(), "mChapterProgress"); } catch (NoSuchFieldException ignored) {}
                }
                if (callbackField.get(page) != null) { stats[1]++; continue; }
                obs.unregisterObserver((DataSetObserver) observer);
                if (progressField != null && progressField.get(page) == obs) progressField.set(page, null);
                stats[0]++;
            }
        }

        private void scanContainer(Object obj, int[] stats) throws Exception {
            if (obj == null) return;
            if (obj instanceof DataSetObservable) {
                pruneObservable((DataSetObservable) obj, stats);
                return;
            }
            if (obj instanceof SparseArray) {
                SparseArray<?> arr = (SparseArray<?>) obj;
                for (int i = 0; i < arr.size(); i++) {
                    Object v = arr.valueAt(i);
                    if (v instanceof DataSetObservable) pruneObservable((DataSetObservable) v, stats);
                }
            }
        }

        private void prune() throws Exception {
            if (observersField == null) {
                ClassLoader loader = app.getClassLoader();
                Class<?> plc = Class.forName("com.tencent.weread.reader.plugin.PluginLifecycle", false, loader);
                try {
                    holderField = findField(plc, "readerHolder");
                    Class<?> rhc = Class.forName("com.tencent.weread.reader.plugin.PluginLifecycle$ReaderHolder", false, loader);
                    actionRefField = findField(rhc, "actionDelegate");
                } catch (NoSuchFieldException fallback) {
                    delegateField = findField(plc, "mActionDelegate");
                }
                observersField = findField(android.database.Observable.class, "mObservers");
            }
            Object delegate = null;
            if (holderField != null) {
                Object holder = holderField.get(null);
                if (holder == null) return;
                Object ref = actionRefField.get(holder);
                if (ref instanceof java.lang.ref.WeakReference) {
                    delegate = ((java.lang.ref.WeakReference<?>) ref).get();
                } else {
                    delegate = ref;
                }
            } else if (delegateField != null) {
                delegate = delegateField.get(null);
            }
            if (delegate == null) return;
            Object fragment;
            try {
                fragment = findField(delegate.getClass(), "this$0").get(delegate);
            } catch (NoSuchFieldException other) {
                return;
            }
            if (fragment == null || !fragment.getClass().getName().endsWith(".BookFragment")) return;
            int[] stats = new int[2]; // [0]=pruned, [1]=kept
            for (Class<?> c = fragment.getClass(); c != null && c.getName().startsWith("com.tencent.weread."); c = c.getSuperclass()) {
                for (Field f : c.getDeclaredFields()) {
                    if ((f.getModifiers() & java.lang.reflect.Modifier.STATIC) != 0) continue;
                    f.setAccessible(true);
                    Object val = f.get(fragment);
                    if (val == null) continue;
                    if (val instanceof DataSetObservable || val instanceof SparseArray) {
                        scanContainer(val, stats);
                    } else if (val.getClass().getName().startsWith("com.tencent.weread.reader.")) {
                        for (Field f2 : val.getClass().getDeclaredFields()) {
                            if ((f2.getModifiers() & java.lang.reflect.Modifier.STATIC) != 0) continue;
                            Class<?> t2 = f2.getType();
                            if (DataSetObservable.class.isAssignableFrom(t2) || SparseArray.class.isAssignableFrom(t2)) {
                                f2.setAccessible(true);
                                scanContainer(f2.get(val), stats);
                            }
                        }
                    }
                }
            }
            if (stats[0] > 0) {
                released += stats[0];
                Log.i(TAG, "PAGE_RELEASE released=" + stats[0] + " on_screen=" + stats[1] + " total=" + released);
            }
        }
    }

    /* ---------------------------------------------------------------------- */
    /* 3. SegDictRelease                                                      */
    /* ---------------------------------------------------------------------- */
    private static final class SegDictRelease implements Runnable {
        private static final String SERVICE = "com.tencent.weread.reader.segment.aidl.SegmentService";
        private final Application app;
        private Field singleton, services, loaded, loading, segmenting;
        private Object lastService;

        private SegDictRelease(Application app) {
            this.app = app;
        }

        static void start(Application app) {
            if (new File("/data/local/tmp/kobo-segdict-disabled").exists()) {
                Log.i(TAG, "SEG_DICT disabled");
                return;
            }
            Thread t = new Thread(new SegDictRelease(app), "kobo-seg-dict");
            t.setDaemon(true);
            t.start();
        }

        private static long heapKb() {
            Runtime rt = Runtime.getRuntime();
            return (rt.totalMemory() - rt.freeMemory()) >> 10;
        }

        private Object currentService() throws Exception {
            Object at = Class.forName("android.app.ActivityThread")
                    .getMethod("currentActivityThread").invoke(null);
            if (at == null) return null;
            if (services == null) services = findField(at.getClass(), "mServices");
            Map<?, ?> m = (Map<?, ?>) services.get(at);
            if (m == null) return null;
            for (Object s : m.values().toArray()) {
                if (s != null && SERVICE.equals(s.getClass().getName())) return s;
            }
            return null;
        }

        private boolean busy(Object service, boolean includeLoaded) throws Exception {
            if (service == null) return false;
            if (segmenting == null) {
                Class<?> c = service.getClass();
                segmenting = findField(c, "segmentingSet");
                loading = findField(c, "loadingSet");
                loaded = findField(c, "segmentLoadedMap");
            }
            if (!((Collection<?>) segmenting.get(service)).isEmpty()
                    || !((Collection<?>) loading.get(service)).isEmpty()) {
                return true;
            }
            return includeLoaded && !((Map<?, ?>) loaded.get(service)).isEmpty();
        }

        private boolean idle() throws Exception {
            Object s = currentService();
            if (s != null) lastService = s;
            if (busy(lastService, false)) return false;
            return s == null || !busy(s, true);
        }

        public void run() {
            try { Thread.sleep(10000); } catch (InterruptedException stop) { return; }
            Log.i(TAG, "SEG_DICT ready");
            int failures = 0, idleChecks = 0;
            boolean wasLoaded = false;
            while (failures < 5) {
                try {
                    Thread.sleep(5000);
                    if (singleton == null) {
                        ClassLoader cl = app.getClassLoader();
                        singleton = findField(Class.forName("moai.ik.dic.Dictionary", false, cl), "singleton");
                        Log.i(TAG, "SEG_DICT field_found");
                    }
                    Object dict = singleton.get(null);
                    if (dict != null && !wasLoaded) {
                        Log.i(TAG, "SEG_DICT loaded heap_kb=" + heapKb() + " rss_kb=" + readSelfRssKb());
                    }
                    wasLoaded = (dict != null);
                    if (dict == null) { idleChecks = 0; continue; }
                    idleChecks = idle() ? (idleChecks + 1) : 0;
                    if (idleChecks < 2) continue;
                    singleton.set(null, null);
                    if (!idle()) {
                        singleton.set(null, dict);
                        idleChecks = 0;
                        Log.i(TAG, "SEG_DICT kept busy");
                        continue;
                    }
                    dict = null;
                    wasLoaded = false;
                    idleChecks = 0;
                    long before = heapKb();
                    int rss = readSelfRssKb();
                    Class<?> vm = Class.forName("dalvik.system.VMRuntime");
                    Object runtime = vm.getMethod("getRuntime").invoke(null);
                    try {
                        Process.setThreadPriority(0);
                        vm.getMethod("concurrentGC").invoke(runtime);
                        vm.getMethod("trimHeap").invoke(runtime);
                    } finally {
                        try { Process.setThreadPriority(8); } catch (Throwable ignored) {}
                    }
                    Log.i(TAG, "SEG_DICT released heap_kb=" + before + "->" + heapKb()
                            + " rss_kb=" + rss + "->" + readSelfRssKb());
                } catch (Throwable err) {
                    failures++;
                    Log.w(TAG, "SEG_DICT error: " + err);
                    if (err instanceof NoSuchFieldException
                            || err instanceof ClassNotFoundException
                            || err instanceof ClassCastException) {
                        break;
                    }
                }
            }
            Log.i(TAG, "SEG_DICT stopped");
        }
    }

    /* ---------------------------------------------------------------------- */
    /* 4. RMonitorStopper                                                     */
    /* ---------------------------------------------------------------------- */
    private static final class RMonitorStopper implements Runnable {
        private final Application app;
        private final Handler handler;
        private int pass;

        private RMonitorStopper(Application app) {
            this.app = app;
            this.handler = new Handler(Looper.getMainLooper());
        }

        static void start(Application app) {
            RMonitorStopper s = new RMonitorStopper(app);
            s.handler.postDelayed(s, 10000);
        }

        public void run() {
            pass++;
            try {
                ClassLoader cl = app.getClassLoader();
                Class<?> rm = Class.forName("com.tencent.rmonitor.RMonitor", false, cl);
                rm.getMethod("abolish").invoke(null);
                Log.i(TAG, "RMON_STOP pass=" + pass + " abolish=ok");
            } catch (Throwable err) {
                Log.w(TAG, "RMON_STOP pass=" + pass + " err=" + err);
            }
            if (pass < 2) {
                handler.postDelayed(this, 25000);
            }
        }
    }

    /* ---------------------------------------------------------------------- */
    /* 5. FontMap (Koboweread: mmap bundled 11.3 MB SourceHanSerifCN OTF)     */
    /* ---------------------------------------------------------------------- */
    private static final class FontMap implements Runnable {
        private static final String ASSET = "fonts/SourceHanSerifCN-Medium_FDK_motify_strip.otf";
        private static final String FILE_PATH = "/data/local/tmp/kobo-fonts/SourceHanSerifCN-Medium_FDK_motify_strip.otf";
        private static final long EXPECTED_BYTES = 11373656L;
        private final Application app;

        private FontMap(Application app) { this.app = app; }

        static void start(Application app) {
            Thread t = new Thread(new FontMap(app), "kobo-font-map");
            t.setDaemon(true);
            t.start();
        }

        @SuppressWarnings("unchecked")
        public void run() {
            try {
                File f = new File(FILE_PATH);
                if (!f.isFile() || f.length() != EXPECTED_BYTES) {
                    Log.i(TAG, "FONT_MAP skipped size=" + (f.isFile() ? f.length() : -1));
                    return;
                }
                AssetManager mgr = app.getAssets();
                Field cf = findField(Typeface.class, "sDynamicTypefaceCache");
                Method uidM = findMethod(Typeface.class, "createAssetUid", AssetManager.class, String.class);
                LruCache<String, Typeface> cache = (LruCache<String, Typeface>) cf.get(null);
                if (cache == null) { Log.i(TAG, "FONT_MAP cache_null"); return; }
                Typeface face = Typeface.createFromFile(f);
                if (face == null) { Log.i(TAG, "FONT_MAP create_failed"); return; }
                for (int tick = 0; tick < 900; tick++) {
                    String key = (String) uidM.invoke(null, mgr, ASSET);
                    if (key == null) return;
                    synchronized (cache) {
                        Typeface old = cache.get(key);
                        if (old == null) {
                            cache.put(key, face);
                            Log.i(TAG, "FONT_MAP mapped key=" + key);
                        } else if (old != face) {
                            Log.i(TAG, "FONT_MAP loaded_from_asset key=" + key);
                            return;
                        }
                    }
                    Thread.sleep(2000);
                }
            } catch (Throwable err) {
                Log.w(TAG, "FONT_MAP err=" + err);
            }
        }
    }

    /* ---------------------------------------------------------------------- */
    /* 6. SyncThrottle (Koboweread: 12h throttle on 3 heavy per-open syncs)   */
    /* ---------------------------------------------------------------------- */
    private static final class SyncThrottle implements Runnable, InvocationHandler {
        private static final long WINDOW_MS = 12L * 3600 * 1000;
        private static final String[][] TARGETS = {
            { "holder:getBookDetailService", "com.tencent.weread.bookdetailservice.model.BaseBookDetailService", "LoadBookLightRead", "0" },
            { "of:com.tencent.weread.bestmarkcontentservice.model.BestMarkContentService", "com.tencent.weread.bestmarkcontentservice.model.BaseBestMarkContentService", "LoadBestBookMarks", "0" },
            { "holder:getBookReviewListService", "com.tencent.weread.bookreviewlistservice.model.BaseBookReviewListService", "LoadBookChapterReviewList", "0,1" },
        };
        private final Application app;
        private final Handler handler;
        private final Map<Object, String[]> targets = new IdentityHashMap<Object, String[]>();
        private final Map<Object, Object> real = new IdentityHashMap<Object, Object>();
        private final Map<String, Long> last = new HashMap<String, Long>();
        private File store;
        private Method emptyMethod;
        private int polls, passed, skipped;

        private SyncThrottle(Application app, Handler h) { this.app = app; this.handler = h; }

        static void start(Application app) {
            Handler h = new Handler(Looper.getMainLooper());
            h.postDelayed(new SyncThrottle(app, h), 500);
        }

        public void run() {
            try {
                if (++polls > 600) return;
                Class<?> atc = Class.forName("android.app.ActivityThread");
                Object at = atc.getMethod("currentActivityThread").invoke(null);
                if (at == null) { handler.postDelayed(this, 100); return; }
                Map<?, ?> acts = (Map<?, ?>) findField(at.getClass(), "mActivities").get(at);
                if (acts == null || acts.isEmpty()) { handler.postDelayed(this, 150); return; }
                install(app.getClassLoader(), new File(app.getFilesDir(), "kobo-sync-throttle"));
            } catch (Throwable err) {
                Log.w(TAG, "SYNC_THROTTLE err=" + err);
            }
        }

        private void install(ClassLoader cl, File file) throws Exception {
            store = file;
            load();
            emptyMethod = Class.forName("rx.Observable", true, cl).getMethod("empty");
            Object holder = Class.forName("com.tencent.weread.serviceholder.ServiceHolder", true, cl).getField("INSTANCE").get(null);
            Object companion = Class.forName("com.tencent.weread.network.WRKotlinService", true, cl).getField("Companion").get(null);
            int wrapped = 0;
            for (String[] row : TARGETS) {
                try {
                    Object service;
                    if (row[0].startsWith("holder:")) {
                        Object fn = holder.getClass().getMethod(row[0].substring(7)).invoke(holder);
                        service = fn.getClass().getMethod("invoke").invoke(fn);
                    } else {
                        service = companion.getClass().getMethod("of", Class.class)
                                .invoke(companion, Class.forName(row[0].substring(3), true, cl));
                    }
                    Class<?> iface = Class.forName(row[1], true, cl);
                    Field d = findField(service.getClass(), "$$delegate_0");
                    Object old = d.get(service);
                    if (old == null || !iface.isInterface() || !iface.isInstance(old)) continue;
                    if (Proxy.isProxyClass(old.getClass()) && Proxy.getInvocationHandler(old) == this) continue;
                    Object proxy = Proxy.newProxyInstance(cl, new Class<?>[] { iface }, this);
                    synchronized (this) { targets.put(proxy, row); real.put(proxy, old); }
                    d.set(service, proxy);
                    if (d.get(service) == proxy) wrapped++;
                } catch (Throwable err) {
                    Log.w(TAG, "SYNC_THROTTLE skip=" + row[2] + " err=" + err);
                }
            }
            Log.i(TAG, "SYNC_THROTTLE ready wrapped=" + wrapped + " known=" + last.size());
        }

        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            if (method.getDeclaringClass() == Object.class) {
                String n = method.getName();
                if ("equals".equals(n)) return proxy == args[0];
                if ("hashCode".equals(n)) return System.identityHashCode(proxy);
                if ("toString".equals(n)) return "SyncThrottle@" + Integer.toHexString(System.identityHashCode(proxy));
            }
            String[] row;
            Object target;
            synchronized (this) { row = targets.get(proxy); target = real.get(proxy); }
            if (target == null) throw new IllegalStateException("SyncThrottle: unknown proxy");
            if (row != null && method.getName().equals(row[2]) && args != null) {
                StringBuilder key = new StringBuilder(row[2]);
                for (String idx : row[3].split(",")) {
                    int k = Integer.parseInt(idx);
                    key.append('/').append(k < args.length ? args[k] : "?");
                }
                String k = key.toString();
                long now = System.currentTimeMillis();
                boolean pass;
                synchronized (this) {
                    Long t = last.get(k);
                    pass = t == null || now - t >= WINDOW_MS || now < t;
                    if (pass) {
                        last.put(k, now);
                        save(now);
                        passed++;
                    } else {
                        skipped++;
                    }
                }
                Log.i(TAG, "SYNC_THROTTLE " + (pass ? "pass " : "skip ") + k + " passed=" + passed + " skipped=" + skipped);
                if (!pass) return emptyMethod.invoke(null);
            }
            try { return method.invoke(target, args); }
            catch (InvocationTargetException e) { throw e.getCause(); }
        }

        private void load() {
            try {
                if (!store.exists()) return;
                byte[] b = new byte[(int) Math.min(store.length(), 1 << 20)];
                FileInputStream in = new FileInputStream(store);
                try {
                    int n = 0, r;
                    while (n < b.length && (r = in.read(b, n, b.length - n)) > 0) n += r;
                } finally { in.close(); }
                for (String line : new String(b, "UTF-8").split("\n")) {
                    int tab = line.indexOf('\t');
                    if (tab > 0) {
                        try {
                            String k = line.substring(tab + 1);
                            if (k.startsWith("LoadBookChapterReviewList/")) {
                                int s1 = k.indexOf('/', 26);
                                int s2 = s1 > 0 ? k.indexOf('/', s1 + 1) : -1;
                                if (s2 > 0) k = k.substring(0, s2);
                            }
                            last.put(k, Long.parseLong(line.substring(0, tab)));
                        } catch (NumberFormatException ignored) {}
                    }
                }
            } catch (Throwable ignored) {}
        }

        private void save(long now) {
            try {
                StringBuilder s = new StringBuilder();
                for (Iterator<Map.Entry<String, Long>> it = last.entrySet().iterator(); it.hasNext();) {
                    Map.Entry<String, Long> e = it.next();
                    if (now - e.getValue() >= WINDOW_MS || now < e.getValue()) { it.remove(); continue; }
                    s.append(e.getValue()).append('\t').append(e.getKey()).append('\n');
                }
                File tmp = new File(store.getPath() + ".tmp");
                FileOutputStream out = new FileOutputStream(tmp);
                try { out.write(s.toString().getBytes("UTF-8")); } finally { out.close(); }
                tmp.renameTo(store);
            } catch (Throwable ignored) {}
        }
    }

    /* ---------------------------------------------------------------------- */
    /* 7. MarkUsersCache (Koboweread: 4000-entry LRU for best-mark user DB)   */
    /* ---------------------------------------------------------------------- */
    private static final class MarkUsersCache implements Runnable, InvocationHandler {
        private static final int MAX = 4000;
        private final Application app;
        private final Handler handler;
        private Field field;
        private Object original;
        private volatile boolean off;
        private int polls;
        private long calls, hits, misses;
        private final LinkedHashMap<Object, Object> cache = new LinkedHashMap<Object, Object>(256, 0.75f, true) {
            protected boolean removeEldestEntry(Map.Entry<Object, Object> e) { return size() > MAX; }
        };
        private final Runnable reporter = new Runnable() {
            public void run() {
                long c, h, m; int sz;
                synchronized (cache) { c = calls; h = hits; m = misses; sz = cache.size(); }
                Log.i(TAG, "MARK_USERS calls=" + c + " hits=" + h + " misses=" + m + " size=" + sz);
            }
        };

        private MarkUsersCache(Application app, Handler h) { this.app = app; this.handler = h; }

        static void start(Application app) {
            Handler h = new Handler(Looper.getMainLooper());
            h.postDelayed(new MarkUsersCache(app, h), 600);
        }

        public void run() {
            try {
                if (++polls > 600) return;
                Class<?> atc = Class.forName("android.app.ActivityThread");
                Object at = atc.getMethod("currentActivityThread").invoke(null);
                if (at == null) { handler.postDelayed(this, 100); return; }
                Map<?, ?> acts = (Map<?, ?>) findField(at.getClass(), "mActivities").get(at);
                if (acts == null || acts.isEmpty()) { handler.postDelayed(this, 150); return; }
                ClassLoader cl = app.getClassLoader();
                Class<?> svc = Class.forName("com.tencent.weread.bestmarkcontentservice.model.BestMarkContentService", true, cl);
                Field f = findField(svc, "getUserById");
                Class<?> iface = f.getType();
                Object old = f.get(null);
                if (!iface.isInterface() || old == null || !iface.isInstance(old)) return;
                original = old;
                field = f;
                Object proxy = Proxy.newProxyInstance(cl, new Class<?>[] { iface }, this);
                f.set(null, proxy);
                Log.i(TAG, "MARK_USERS ready max=" + MAX);
            } catch (Throwable err) {
                Log.w(TAG, "MARK_USERS err=" + err);
            }
        }

        public Object invoke(Object p, Method method, Object[] args) throws Throwable {
            if (method.getDeclaringClass() == Object.class) {
                String n = method.getName();
                if ("equals".equals(n)) return p == args[0];
                if ("hashCode".equals(n)) return System.identityHashCode(p);
                if ("toString".equals(n)) return "MarkUsersCache@" + Integer.toHexString(System.identityHashCode(p));
            }
            if (off || args == null || args.length != 1 || !"invoke".equals(method.getName()) || args[0] == null) {
                return call(method, args);
            }
            Object key = args[0], user;
            synchronized (cache) { user = cache.get(key); calls++; if (user != null) hits++; }
            if (user == null) {
                user = call(method, args);
                synchronized (cache) { misses++; if (user != null) cache.put(key, user); }
            }
            handler.removeCallbacks(reporter);
            handler.postDelayed(reporter, 10000);
            return user;
        }

        private Object call(Method method, Object[] args) throws Throwable {
            try { return method.invoke(original, args); }
            catch (InvocationTargetException e) { throw e.getCause(); }
        }
    }

    /* ---------------------------------------------------------------------- */
    /* 8. ChapterPrefetch (Koboweread: adjacent +-3 & charging whole-book)    */
    /* ---------------------------------------------------------------------- */
    private static final class ChapterPrefetch implements Runnable {
        private static final String BOOK_FRAGMENT = "com.tencent.weread.book.fragment.BookFragment";
        private static final long TICK_MS = 10000, FAST_TICK_MS = 1000;
        private static final long SETTLE_MS = 30000, PENDING_MS = 120000, STAY_MS = 45000, PAGE_QUIET_MS = 25000, BOOK_IDLE_MS = 120000;
        private static final int RANGE = 1;
        private static final int MIN_AVAIL_KB = 130 * 1024;
        private static final String[] POWER_PATHS = {
            "/sys/class/power_supply/mc13892_bat/status",
            "/sys/class/power_supply/battery/status",
            "/sys/class/power_supply/ricoh619-battery/status"
        };

        private final Application app;
        private final Handler handler;
        private Class<?> bookFragmentClass;
        private Method pageContainer, firstCharPos, charChapter, charPosition;
        private Method checkTypeSetting, canReTypeSetting, visibleRealChapter, needTypeSetting, chapters, chapterUid;
        private Field cursorField, preloadSetField, retypingField;
        private Object fragment;
        private long fragmentSince, pendingSince, movedAt, pageAt;
        private final Set<Integer> tried = new HashSet<Integer>();
        private final Set<Integer> prepared = new HashSet<Integer>();
        private int pendingUid, lastAt, startedCnt, doneCnt, bookDone, polls;
        private String lastPage;
        private boolean pendingBook, bookActive, bookComplete, failed;

        private ChapterPrefetch(Application app, Handler h) { this.app = app; this.handler = h; }

        static void start(Application app) {
            Handler h = new Handler(Looper.getMainLooper());
            h.postDelayed(new ChapterPrefetch(app, h), TICK_MS);
        }

        public void run() {
            if (failed) return;
            try { tick(); }
            catch (Throwable err) {
                failed = true;
                Log.w(TAG, "CHAPTER_PREFETCH err=" + err);
                return;
            }
            handler.postDelayed(this, pendingUid != 0 || bookActive ? FAST_TICK_MS : TICK_MS);
        }

        @SuppressWarnings("unchecked")
        private void tick() throws Exception {
            Class<?> atc = Class.forName("android.app.ActivityThread");
            Object at = atc.getMethod("currentActivityThread").invoke(null);
            if (at == null) return;
            if (bookFragmentClass == null) {
                if (++polls > 360) return;
                ClassLoader cl = app.getClassLoader();
                Class<?> bf = Class.forName(BOOK_FRAGMENT, false, cl);
                checkTypeSetting = findMethod(bf, "checkTypeSetting", int.class);
                canReTypeSetting = findMethod(bf, "isChapterCanReTypeSetting", int.class);
                visibleRealChapter = findMethod(bf, "getVisibleRealChapter");
                cursorField = findField(bf, "mReaderCursor");
                preloadSetField = findField(bf, "preloadTypeSettingChapterSet");
                retypingField = findField(bf, "currentRetypeSetting");
                Class<?> cursor = Class.forName("com.tencent.weread.reader.cursor.WRReaderCursor", false, cl);
                needTypeSetting = cursor.getMethod("isChapterNeedTypeSetting", int.class);
                chapters = cursor.getMethod("chapters");
                chapterUid = Class.forName("com.tencent.weread.storage.ChapterIndexInterface", false, cl).getMethod("getId");
                pageContainer = findMethod(bf, "getPageContainer");
                firstCharPos = findMethod(bf, "getFirstVisibleCharPos");
                Class<?> cp = Class.forName("com.tencent.weread.reader.container.pagecontainer.CharPosition", false, cl);
                charChapter = cp.getMethod("getChapterUid");
                charPosition = cp.getMethod("getPosition");
                bookFragmentClass = bf;
                Log.i(TAG, "CHAPTER_PREFETCH ready range=" + RANGE + " power=" + power());
            }
            Object f = findBookFragment(at);
            if (f == null) return;
            if (f != fragment) {
                bookActive = false;
                fragment = f;
                fragmentSince = System.currentTimeMillis();
                tried.clear();
                prepared.clear();
                pendingUid = 0;
                lastAt = 0;
                lastPage = null;
                bookComplete = false;
                bookDone = 0;
            }
            long now = System.currentTimeMillis();
            Object where = pageContainer.invoke(f) == null ? null : firstCharPos.invoke(f);
            if (where != null) {
                String pg = charChapter.invoke(where) + ":" + charPosition.invoke(where);
                if (!pg.equals(lastPage)) {
                    if (lastPage != null && bookActive) bookActive = false;
                    lastPage = pg;
                    pageAt = now;
                }
            }
            if (bookActive && !charging()) bookActive = false;
            if (now - fragmentSince < SETTLE_MS) return;
            Object cursor = cursorField.get(f);
            if (cursor == null) return;
            if (pendingUid != 0) {
                boolean need = (Boolean) needTypeSetting.invoke(cursor, pendingUid);
                long age = now - pendingSince;
                if (need && age < PENDING_MS) return;
                if (!need) {
                    doneCnt++;
                    prepared.add(pendingUid);
                    if (pendingBook) bookDone++;
                }
                Log.i(TAG, "CHAPTER_PREFETCH " + (need ? "timeout" : "done") + " uid=" + pendingUid + " ms=" + age + " mode=" + (pendingBook ? "book" : "near"));
                pendingUid = 0;
            }
            if ((Boolean) retypingField.get(f)) return;
            int[] visible = (int[]) visibleRealChapter.invoke(f);
            if (visible == null || visible.length == 0) return;
            if (visible[0] != lastAt) { lastAt = visible[0]; movedAt = now; }
            if (now - movedAt < STAY_MS) return;
            /* Never launch heavy EPUB unzip/typesetting while the user is actively turning pages or low on RAM. */
            if (now - pageAt < PAGE_QUIET_MS) return;
            int availKb = readMemAvailableKb();
            if (availKb > 0 && availKb < MIN_AVAIL_KB) return;
            List<?> list = (List<?>) chapters.invoke(cursor);
            if (list == null || list.isEmpty()) return;
            List<Integer> uids = new ArrayList<Integer>(list.size());
            for (Object c : list) uids.add((Integer) chapterUid.invoke(c));
            int at0 = uids.indexOf(visible[0]);
            if (at0 < 0) return;
            Collection<Integer> preload = (Collection<Integer>) preloadSetField.get(f);
            if (startNearest(f, cursor, uids, at0, 1, RANGE, preload, false, true)) return;
            if (bookComplete || now - pageAt < BOOK_IDLE_MS || now - movedAt < BOOK_IDLE_MS || !charging()) return;
            if (!bookActive) {
                bookActive = true;
                Log.i(TAG, "BOOK_PREFETCH start chapters=" + uids.size() + " current=" + visible[0]);
            }
            if (startNearest(f, cursor, uids, at0, RANGE + 1, uids.size(), preload, true, false)) return;
            bookActive = false;
            bookComplete = true;
            Log.i(TAG, "BOOK_PREFETCH complete book_done=" + bookDone + " prepared=" + prepared.size());
        }

        private boolean startNearest(Object f, Object cursor, List<Integer> uids, int at0, int from, int to,
                                     Collection<Integer> preload, boolean book, boolean forwardOnly) throws Exception {
            for (int d = from; d <= to; d++) {
                for (int sign = 1; sign >= (forwardOnly ? 1 : -1); sign -= 2) {
                    int i = at0 + sign * d;
                    if (i < 0 || i >= uids.size()) continue;
                    int uid = uids.get(i);
                    if (tried.contains(uid)) continue;
                    tried.add(uid);
                    if (!(Boolean) canReTypeSetting.invoke(f, uid)) continue;
                    if (!(Boolean) needTypeSetting.invoke(cursor, uid)) continue;
                    if (preload != null) preload.add(uid);
                    pendingUid = uid;
                    pendingSince = System.currentTimeMillis();
                    pendingBook = book;
                    startedCnt++;
                    checkTypeSetting.invoke(f, uid);
                    return true;
                }
            }
            return false;
        }

        private static String power() {
            for (String p : POWER_PATHS) {
                BufferedReader in = null;
                try {
                    File f = new File(p);
                    if (!f.canRead()) continue;
                    in = new BufferedReader(new FileReader(f));
                    String l = in.readLine();
                    if (l != null && l.trim().length() > 0) return l.trim();
                } catch (Throwable ignored) {
                } finally {
                    try { if (in != null) in.close(); } catch (Throwable ignored) {}
                }
            }
            return "none";
        }

        private static boolean charging() {
            String p = power();
            return !"none".equals(p) && !"Discharging".equals(p) && !"Unknown".equals(p);
        }

        private Object findBookFragment(Object at) throws Exception {
            Map<?, ?> acts = (Map<?, ?>) findField(at.getClass(), "mActivities").get(at);
            if (acts == null) return null;
            for (Object record : acts.values()) {
                Object activity = findField(record.getClass(), "activity").get(record);
                if (activity == null) continue;
                Method fm;
                try { fm = activity.getClass().getMethod("getSupportFragmentManager"); }
                catch (NoSuchMethodException none) { continue; }
                Object found = search(fm.invoke(activity), 0);
                if (found != null) return found;
            }
            return null;
        }

        private Object search(Object manager, int depth) throws Exception {
            if (manager == null || depth > 4) return null;
            List<?> list = (List<?>) manager.getClass().getMethod("getFragments").invoke(manager);
            if (list == null) return null;
            for (Object fr : list) {
                if (fr == null) continue;
                if (bookFragmentClass.isInstance(fr)) {
                    if ((Boolean) fr.getClass().getMethod("isResumed").invoke(fr)) return fr;
                    continue;
                }
                Object child;
                try { child = fr.getClass().getMethod("getChildFragmentManager").invoke(fr); }
                catch (Throwable ignored) { continue; }
                Object found = search(child, depth + 1);
                if (found != null) return found;
            }
            return null;
        }
    }

    /* ---------------------------------------------------------------------- */
    /* 9. MemoryTrim (Koboweread: 160MB heap trim / 120MB TRIM_MEMORY_CRIT)   */
    /* ---------------------------------------------------------------------- */
    private static final class MemoryTrim implements Runnable {
        private static final long PERIOD_MS = 30000;
        private static final long HEAP_EVERY_MS = 120000;
        private static final long APP_EVERY_MS = 300000;
        private static final int HEAP_BELOW_KB = 110 * 1024;
        private static final int APP_BELOW_KB = 85 * 1024;
        private static final int TRIM_MEMORY_RUNNING_CRITICAL = 15;

        private final boolean mainProc;
        private long lastHeap, lastApp;
        private int failures;

        private MemoryTrim(boolean mainProc) { this.mainProc = mainProc; }

        static void start(boolean mainProc) {
            Thread t = new Thread(new MemoryTrim(mainProc), "kobo-mem-trim");
            t.setDaemon(true);
            t.setPriority(Thread.MIN_PRIORITY);
            t.start();
        }

        public void run() {
            try { Thread.sleep(PERIOD_MS); } catch (InterruptedException stop) { return; }
            Log.i(TAG, "MEM_TRIM ready proc=" + (mainProc ? "main" : "seg"));
            while (failures < 3) {
                try {
                    Thread.sleep(PERIOD_MS);
                    int avail = readMemAvailableKb();
                    long now = SystemClock.uptimeMillis();
                    if (avail > 0 && avail < HEAP_BELOW_KB && now - lastHeap >= HEAP_EVERY_MS) {
                        lastHeap = now;
                        int before = readSelfRssKb();
                        Class<?> vm = Class.forName("dalvik.system.VMRuntime");
                        Object rt = vm.getMethod("getRuntime").invoke(null);
                        try {
                            /* Never run a stop-the-world GC at nice 19 (Thread.MIN_PRIORITY) on single-core Cortex-A9! */
                            Process.setThreadPriority(0);
                            vm.getMethod("concurrentGC").invoke(rt);
                            vm.getMethod("trimHeap").invoke(rt);
                        } finally {
                            try { Process.setThreadPriority(mainProc ? 19 : 8); } catch (Throwable ignored) {}
                        }
                        Log.i(TAG, "MEM_TRIM heap proc=" + (mainProc ? "main" : "seg")
                                + " avail_kb=" + avail + " rss_kb=" + before + "->" + readSelfRssKb());
                    }
                    if (mainProc && avail > 0 && avail < APP_BELOW_KB && now - lastApp >= APP_EVERY_MS) {
                        lastApp = now;
                        final Class<?> atc = Class.forName("android.app.ActivityThread");
                        final Object at = atc.getMethod("currentActivityThread").invoke(null);
                        if (at != null && Looper.getMainLooper() != null) {
                            final Method handle = findMethod(atc, "handleTrimMemory", int.class);
                            final int a = avail;
                            new Handler(Looper.getMainLooper()).post(new Runnable() {
                                public void run() {
                                    try {
                                        int before = readSelfRssKb();
                                        handle.invoke(at, TRIM_MEMORY_RUNNING_CRITICAL);
                                        Log.i(TAG, "MEM_TRIM app level=15 avail_kb=" + a
                                                + " rss_kb=" + before + "->" + readSelfRssKb());
                                    } catch (Throwable err) {
                                        Log.w(TAG, "MEM_TRIM app err=" + err);
                                    }
                                }
                            });
                        }
                    }
                } catch (InterruptedException stop) {
                    return;
                } catch (Throwable err) {
                    failures++;
                    Log.w(TAG, "MEM_TRIM err=" + err);
                }
            }
        }
    }
}
