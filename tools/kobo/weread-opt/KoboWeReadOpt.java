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
import android.app.Application;
import android.content.Context;
import android.database.DataSetObservable;
import android.database.DataSetObserver;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;
import android.util.SparseArray;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Map;

public final class KoboWeReadOpt {
    private static final String TAG = "KoboWeRead";
    private static volatile boolean started;

    public static void init(Application app, String procName) {
        if (started || app == null || procName == null) return;
        started = true;
        if ("com.tencent.weread.eink".equals(procName)) {
            Log.i(TAG, "OPT_INIT proc=main");
            FontSizeCache.start(app);
            ReaderPageRelease.start(app);
        } else if ("com.tencent.weread.eink:seg".equals(procName)) {
            Log.i(TAG, "OPT_INIT proc=seg");
            SegDictRelease.start(app);
        }
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
            Object progress = findField(fragment.getClass(), "mBookProgress").get(fragment);
            if (progress == null) return;
            Object chapters = findField(progress.getClass(), "mChapterProgress").get(progress);
            if (!(chapters instanceof SparseArray)) return;
            SparseArray<?> adapters = (SparseArray<?>) chapters;
            int pruned = 0, kept = 0;
            for (int i = 0; i < adapters.size(); i++) {
                Object adapter = adapters.valueAt(i);
                if (!(adapter instanceof DataSetObservable)) continue;
                ArrayList<?> list = (ArrayList<?>) observersField.get(adapter);
                Object[] observers;
                synchronized (list) { observers = list.toArray(); }
                for (Object observer : observers) {
                    if (observer == null || !PAGE_OBSERVER.equals(observer.getClass().getName())) continue;
                    if (outerField == null) outerField = findField(observer.getClass(), "this$0");
                    Object page = outerField.get(observer);
                    if (page == null) continue;
                    if (callbackField == null) {
                        callbackField = findField(page.getClass(), "drawViewCallback");
                        progressField = findField(page.getClass(), "mChapterProgress");
                    }
                    if (callbackField.get(page) != null) { kept++; continue; }
                    ((DataSetObservable) adapter).unregisterObserver((DataSetObserver) observer);
                    if (progressField.get(page) == adapter) progressField.set(page, null);
                    pruned++;
                }
            }
            if (pruned > 0) {
                released += pruned;
                Log.i(TAG, "PAGE_RELEASE released=" + pruned + " on_screen=" + kept + " total=" + released);
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
                    vm.getMethod("concurrentGC").invoke(runtime);
                    vm.getMethod("trimHeap").invoke(runtime);
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
}
