// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * libkobo_madvise.so — Bionic LD_PRELOAD shim for Kobo Libra 2 (Linux 4.1.15).
 *
 * Kobo's stock 4.1.15 kernel is compiled without CONFIG_ADVISE_SYSCALLS, so
 * madvise(2) returns -1/ENOSYS, causing ART (RosAlloc) to abort during
 * zygote/patchoat startup. When madvise(2) returns ENOSYS, this shim forwards
 * MADV_DONTNEED and sequential/random hints to /dev/kobo_madvise (provided by
 * kobo_madvise.ko), and closes the fd immediately so zygote never inherits it.
 */
#include <stdint.h>
#include <stddef.h>
#ifdef __ARM_NEON
#include <arm_neon.h>
#endif

extern long syscall(long, ...);
extern int open(const char *, int, ...);
extern int close(int);
extern long read(int, void *, size_t);
extern long readlink(const char *, char *, size_t);
extern int ioctl(int, unsigned long, ...);
extern int *__errno(void);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern int getpid(void);
extern unsigned int getuid(void);
extern int usleep(unsigned int);
extern int setpriority(int, unsigned int, int);
extern int pthread_create(long *, const void *, void *(*)(void *), void *);
extern int pthread_detach(long);
extern void *opendir(const char *);
extern void *readdir(void *);
extern int closedir(void *);

#define RTLD_LAZY       1
#define PRIO_PROCESS    0
#define ARM_NR_MADVISE  220L
#define ERR_ENOSYS      38
#define O_RDWR_CLOEXEC  (2 | 02000000)

#define KOBO_IOCTL_DISCARD 0x40084b41UL  /* _IOW('K', 0x41, {u32 start, u32 len}) */
#define KOBO_IOCTL_HINT    0x400c4b42UL  /* _IOW('K', 0x42, {u32 start, u32 len, u32 advice}) */

struct kobo_madv_req {
    uint32_t start;
    uint32_t length;
    uint32_t advice;
};

static void maybe_init_weread_opt(void);
static int is_weread_proc(void);

int madvise(void *addr, size_t length, int advice)
{
    maybe_init_weread_opt();
    int saved_errno = *__errno();
    int rc = (int)syscall(ARM_NR_MADVISE, addr, length, advice);
    if (rc == 0 || *__errno() != ERR_ENOSYS) {
        return rc;
    }

    if (advice == 4 || (advice >= 0 && advice <= 2)) {
        struct kobo_madv_req req;
        req.start = (uint32_t)(uintptr_t)addr;
        req.length = (uint32_t)length;
        req.advice = (uint32_t)advice;

        int fd = open("/dev/kobo_madvise", O_RDWR_CLOEXEC);
        if (fd < 0) {
            return -1;
        }
        rc = ioctl(fd, advice == 4 ? KOBO_IOCTL_DISCARD : KOBO_IOCTL_HINT, &req);
        int ioctl_errno = *__errno();
        close(fd);
        *__errno() = (rc == 0) ? saved_errno : ioctl_errno;
        return rc;
    }

    /* Non-destructive advisory hints (e.g. MADV_WILLNEED=3, MADV_MERGEABLE=12) */
    *__errno() = saved_errno;
    return 0;
}

/*
 * Intercept SSL_write to neutralize WeRead's mandatory self-update check
 * (GET https://weread.qq.com/test-flight/query?...) without modifying WeRead's
 * APK or disrupting HTTP/1.1 / HTTP/2 TLS connection pooling.
 *
 * In both plain ASCII ("/test-flight/quer" -> "/test-flight/quel") and RFC 7541
 * HPACK Huffman (96-bit "/test-flight/quer" ending in 0x6b ['r', 6 bits] ->
 * 0x68 ['l', 6 bits]), replacing 'r' with 'l' preserves exact byte & bit length
 * while causing weread.qq.com to reply 404 Not Found.
 */
typedef int (*ssl_write_fn)(void *, const void *, int);
static ssl_write_fn real_ssl_write;

static int match_bytes(const unsigned char *hay, int hlen,
                       const unsigned char *needle, int nlen)
{
    int i, j;
    for (i = 0; i <= hlen - nlen; i++) {
        for (j = 0; j < nlen; j++) {
            if (hay[i + j] != needle[j])
                break;
        }
        if (j == nlen)
            return i;
    }
    return -1;
}

int SSL_write(void *ssl, const void *buf, int num)
{
    static const unsigned char ascii_pat[17] = {
        '/', 't', 'e', 's', 't', '-', 'f', 'l', 'i', 'g', 'h', 't',
        '/', 'q', 'u', 'e', 'r'
    };
    static const unsigned char hpack_pat[12] = {
        0x61, 0x25, 0x42, 0x56, 0x96, 0x83, 0x4d, 0x3a, 0x58, 0xed, 0x69, 0x6c
    };

    if (!real_ssl_write) {
        void *h = dlopen("/system/lib/libssl.so", RTLD_LAZY);
        if (!h)
            h = dlopen("libssl.so", RTLD_LAZY);
        if (h) {
            void *fn = dlsym(h, "SSL_write");
            if (fn && fn != (void *)SSL_write)
                real_ssl_write = (ssl_write_fn)fn;
        }
        if (!real_ssl_write)
            return -1;
    }

    if (buf && num >= 12 && num <= 4096) {
        const unsigned char *p = (const unsigned char *)buf;
        int pos = match_bytes(p, num, hpack_pat, 12);
        int apos = (pos < 0 && num >= 17) ? match_bytes(p, num, ascii_pat, 17) : -1;
        /* Fallback for OSS telemetry if HTTPDNS ever connects to oss.weread.qq.com by IP */
        static const unsigned char oss_pat[17] = {
            '/', 'w', 'r', 'b', 'u', 's', '/', 'r', 'e', 'p', 'o', 'r', 't', '/', 'o', 's', 's'
        };
        int opos = (pos < 0 && apos < 0 && num >= 17 && is_weread_proc())
                 ? match_bytes(p, num, oss_pat, 17) : -1;
        if (pos >= 0 || apos >= 0 || opos >= 0) {
            unsigned char tmp[4096];
            int i;
            for (i = 0; i < num; i++)
                tmp[i] = p[i];
            if (pos >= 0)
                tmp[pos + 11] = 0x68;
            if (apos >= 0)
                tmp[apos + 16] = 'l';
            if (opos >= 0)
                tmp[opos + 16] = 'x';
            return real_ssl_write(ssl, tmp, num);
        }
    }

    return real_ssl_write(ssl, buf, num);
}

/*
 * Zero-DNS / Zero-TLS telemetry blocker strictly scoped to WeRead processes
 * (com.tencent.weread.eink and :seg). Blocks verified pure analytics, crash
 * upload, and APM telemetry hosts before any DNS query, TCP SYN, TLS handshake,
 * or Wi-Fi LPS wakeup occurs. Core WeRead APIs (i.weread.qq.com, s.weread.qq.com,
 * res.weread.qq.com, download.weread.qq.com, cdn.*, weread.qq.com, weixin login)
 * are never touched.
 */
#define BIONIC_EAI_NONAME 8

typedef int (*gai_fn)(const char *, const char *, const void *, void **);
typedef int (*gai_net_fn)(const char *, const char *, const void *, unsigned int, unsigned int, void **);
typedef int (*gai_ctx_fn)(const char *, const char *, const void *, const void *, void **);
typedef int (*log_print_fn)(int, const char *, const char *, ...);

static gai_fn     real_getaddrinfo;
static gai_net_fn real_android_getaddrinfofornet;
static gai_ctx_fn real_android_getaddrinfofornetcontext;
static log_print_fn dns_log_fn;
static volatile unsigned int dns_block_cnt;

static int str_ieq(const char *a, const char *b)
{
    while (*a && *b) {
        unsigned char ca = (unsigned char)*a++;
        unsigned char cb = (unsigned char)*b++;
        if (ca >= 'A' && ca <= 'Z') ca += ('a' - 'A');
        if (cb >= 'A' && cb <= 'Z') cb += ('a' - 'A');
        if (ca != cb) return 0;
    }
    return *a == 0 && *b == 0;
}

static int is_blocked_telemetry_host(const char *host)
{
    static const char *const kHosts[] = {
        "android.bugly.qq.com",
        "bugly.qq.com",
        "astat.bugly.qcloud.com",
        "android.rqd.qq.com",
        "rmonitor.qq.com",
        "otheve.beacon.qq.com",
        "othstr.beacon.qq.com",
        "oth.eve.mdt.qq.com",
        "oth.str.mdt.qq.com",
        "h.trace.qq.com",
        "pingmid.qq.com",
        "oss.weread.qq.com",
        "oss.mail.qq.com",
    };
    if (!host || !*host)
        return 0;
    for (size_t i = 0; i < sizeof(kHosts) / sizeof(kHosts[0]); i++) {
        if (str_ieq(host, kHosts[i]))
            return 1;
    }
    return 0;
}

static void log_dns_block(const char *host)
{
    unsigned int n = __sync_add_and_fetch(&dns_block_cnt, 1);
    if (n <= 12 || (n % 50) == 0) {
        if (!dns_log_fn) {
            void *lh = dlopen("/system/lib/liblog.so", RTLD_LAZY);
            if (!lh) lh = dlopen("liblog.so", RTLD_LAZY);
            if (lh) dns_log_fn = (log_print_fn)dlsym(lh, "__android_log_print");
        }
        if (dns_log_fn)
            dns_log_fn(4, "KoboWeRead", "DNS_BLOCK host=%s count=%u", host, n);
    }
}

static void *resolve_libc_sym(const char *name, void *self)
{
    void *h = dlopen("/system/lib/libc.so", RTLD_LAZY);
    if (!h) h = dlopen("libc.so", RTLD_LAZY);
    if (!h) return NULL;
    void *fn = dlsym(h, name);
    return (fn && fn != self) ? fn : NULL;
}

int getaddrinfo(const char *node, const char *service, const void *hints, void **res)
{
    if (node && is_weread_proc() && is_blocked_telemetry_host(node)) {
        log_dns_block(node);
        if (res) *res = NULL;
        return BIONIC_EAI_NONAME;
    }
    if (!real_getaddrinfo)
        real_getaddrinfo = (gai_fn)resolve_libc_sym("getaddrinfo", (void *)getaddrinfo);
    if (!real_getaddrinfo)
        return BIONIC_EAI_NONAME;
    return real_getaddrinfo(node, service, hints, res);
}

int android_getaddrinfofornet(const char *hostname, const char *servname,
                              const void *hints, unsigned int netid,
                              unsigned int mark, void **res)
{
    if (hostname && is_weread_proc() && is_blocked_telemetry_host(hostname)) {
        log_dns_block(hostname);
        if (res) *res = NULL;
        return BIONIC_EAI_NONAME;
    }
    if (!real_android_getaddrinfofornet)
        real_android_getaddrinfofornet = (gai_net_fn)resolve_libc_sym(
            "android_getaddrinfofornet", (void *)android_getaddrinfofornet);
    if (!real_android_getaddrinfofornet)
        return BIONIC_EAI_NONAME;
    return real_android_getaddrinfofornet(hostname, servname, hints, netid, mark, res);
}

int android_getaddrinfofornetcontext(const char *hostname, const char *servname,
                                     const void *hints, const void *netcontext,
                                     void **res)
{
    if (hostname && is_weread_proc() && is_blocked_telemetry_host(hostname)) {
        log_dns_block(hostname);
        if (res) *res = NULL;
        return BIONIC_EAI_NONAME;
    }
    if (!real_android_getaddrinfofornetcontext)
        real_android_getaddrinfofornetcontext = (gai_ctx_fn)resolve_libc_sym(
            "android_getaddrinfofornetcontext", (void *)android_getaddrinfofornetcontext);
    if (!real_android_getaddrinfofornetcontext)
        return BIONIC_EAI_NONAME;
    return real_android_getaddrinfofornetcontext(hostname, servname, hints, netcontext, res);
}

/*
 * WeRead 1.9.7 runtime optimizations (inspired by Koboweread, zero APK edits):
 *  1. Raise Skia software glyph cache to 16 MB / 16384 glyphs so CJK text is
 *     not constantly evicted and re-rasterized on page turns.
 *  2. Defer WRWebViewPool.preInit (sets isInited=true via JNI before home
 *     activity) to avoid loading ~27 MB libwebviewchromium on startup.
 *  3. Deprioritize heavy background pools (WRCommonPool, WRNetworkPool,
 *     WRLowPriorityPo, BUGLY_ASYNC, RxIo/Computation, glide) to nice 19 and
 *     boost TypeSetting to nice -2 so page turns & typesetting never starve.
 *  4. Call VMRuntime.trimHeap() when MemAvailable < 150 MB to keep long
 *     reading sessions snappy on 512 MB RAM.
 */
struct kobo_dirent {
    uint64_t d_ino;
    int64_t  d_off;
    uint16_t d_reclen;
    uint8_t  d_type;
    char     d_name[256];
};

static int str_eq(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return *a == 0 && *b == 0;
}

static int str_starts(const char *s, const char *pfx)
{
    while (*pfx) {
        if (*s++ != *pfx++) return 0;
    }
    return 1;
}

static int read_small_file(const char *path, char *buf, int sz)
{
    int fd = open(path, 0);
    if (fd < 0) return -1;
    long n = read(fd, buf, (size_t)(sz - 1));
    close(fd);
    if (n < 0) n = 0;
    buf[n] = 0;
    return (int)n;
}

static int parse_uint(const char *s)
{
    int v = 0;
    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (*s - '0');
        s++;
    }
    return v;
}

static int read_mem_available_kb(void)
{
    char buf[1024];
    int n = read_small_file("/proc/meminfo", buf, sizeof(buf));
    if (n <= 0) return 999999;
    const char *p = buf;
    while (*p) {
        if (str_starts(p, "MemAvailable:")) {
            p += 13;
            while (*p == ' ' || *p == '\t') p++;
            return parse_uint(p);
        }
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
    }
    return 999999;
}

static void tune_weread_threads(void)
{
    void *d = opendir("/proc/self/task");
    if (!d) return;
    struct kobo_dirent *ent;
    char path[64], comm[32];
    while ((ent = (struct kobo_dirent *)readdir(d)) != NULL) {
        if (ent->d_name[0] < '1' || ent->d_name[0] > '9')
            continue;
        int k = 0;
        const char *a = "/proc/self/task/";
        while (*a) path[k++] = *a++;
        for (const char *s = ent->d_name; *s && k < 48; ) path[k++] = *s++;
        a = "/comm";
        while (*a) path[k++] = *a++;
        path[k] = 0;
        if (read_small_file(path, comm, sizeof(comm)) <= 0)
            continue;
        unsigned int tid = (unsigned int)parse_uint(ent->d_name);
        if (tid == 0) continue;
        if (str_starts(comm, "WRCommonPool") ||
            str_starts(comm, "WRNetworkPool")) {
            /* Match Koboweread PoolPriority.java: put ONLY WRCommonPool & WRNetworkPool
               at nice 19 so they yield completely to UI/page-turns after book open,
               while NEVER touching Bugly-ThreadMonitor0 (avoids MessageQueue lock inversion). */
            setpriority(PRIO_PROCESS, tid, 19);
        } else if (str_starts(comm, "TypeSetting")) {
            /* Give chapter typesetting near-UI priority (-6) so TOC chapter jumps
               win the single Cortex-A9 core over background pools. */
            setpriority(PRIO_PROCESS, tid, -6);
        }
    }
    closedir(d);
}

/* Minimal JNI 1.1+ vtable helpers (ABI-fixed slot indices, zero external headers). */
typedef void *jobj;
typedef void ***JNIEnvPtr;
typedef void ***JavaVMPtr;

static void jni_clear_exc(JNIEnvPtr e)
{
    uint8_t (*exc_chk)(JNIEnvPtr) = (uint8_t (*)(JNIEnvPtr))((*e)[228]);
    void (*exc_clr)(JNIEnvPtr) = (void (*)(JNIEnvPtr))((*e)[17]);
    if (exc_chk(e)) exc_clr(e);
}

static const char *defer_webview_pool(JNIEnvPtr e, jobj app)
{
    jobj (*find_cls)(JNIEnvPtr, const char *) = (jobj (*)(JNIEnvPtr, const char *))((*e)[6]);
    jobj (*get_mid)(JNIEnvPtr, jobj, const char *, const char *) = (jobj (*)(JNIEnvPtr, jobj, const char *, const char *))((*e)[33]);
    jobj (*call_obj)(JNIEnvPtr, jobj, jobj, ...) = (jobj (*)(JNIEnvPtr, jobj, jobj, ...))((*e)[34]);
    jobj (*get_sfid)(JNIEnvPtr, jobj, const char *, const char *) = (jobj (*)(JNIEnvPtr, jobj, const char *, const char *))((*e)[144]);
    uint8_t (*get_sbool)(JNIEnvPtr, jobj, jobj) = (uint8_t (*)(JNIEnvPtr, jobj, jobj))((*e)[146]);
    void (*set_sbool)(JNIEnvPtr, jobj, jobj, uint8_t) = (void (*)(JNIEnvPtr, jobj, jobj, uint8_t))((*e)[155]);
    jobj (*new_str)(JNIEnvPtr, const char *) = (jobj (*)(JNIEnvPtr, const char *))((*e)[167]);

    jobj ctx = find_cls(e, "android/content/Context");
    jobj m_cl = ctx ? get_mid(e, ctx, "getClassLoader", "()Ljava/lang/ClassLoader;") : NULL;
    if (!m_cl) return "no_get_cl";
    jobj cl = call_obj(e, app, m_cl);
    jni_clear_exc(e);
    if (!cl) return "cl_null";

    jobj cl_cls = find_cls(e, "java/lang/ClassLoader");
    jobj m_load = cl_cls ? get_mid(e, cl_cls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") : NULL;
    if (!m_load) return "no_load_cls";
    jobj s_name = new_str(e, "com.tencent.weread.WRWebViewPool");
    if (!s_name) return "no_str";
    jobj pool = call_obj(e, cl, m_load, s_name);
    jni_clear_exc(e);
    if (!pool) return "pool_missing";

    jobj f_inited = get_sfid(e, pool, "isInited", "Z");
    jni_clear_exc(e);
    if (!f_inited) return "no_isInited";
    if (get_sbool(e, pool, f_inited)) return "too_late";
    set_sbool(e, pool, f_inited, 1);
    return "deferred";
}

static int read_self_rss_kb(void)
{
    char buf[1024];
    int n = read_small_file("/proc/self/status", buf, sizeof(buf));
    if (n <= 0) return -1;
    const char *p = buf;
    while (*p) {
        if (str_starts(p, "VmRSS:")) {
            p += 6;
            while (*p == ' ' || *p == '\t') p++;
            return parse_uint(p);
        }
        while (*p && *p != '\n') p++;
        if (*p == '\n') p++;
    }
    return -1;
}

static void lower_all_threads_nice8(void)
{
    void *d = opendir("/proc/self/task");
    if (!d) return;
    struct kobo_dirent *ent;
    while ((ent = (struct kobo_dirent *)readdir(d)) != NULL) {
        if (ent->d_name[0] < '1' || ent->d_name[0] > '9')
            continue;
        unsigned int tid = (unsigned int)parse_uint(ent->d_name);
        /* Mild nice 8 (not 19): keeps :seg out of the way of main (-10) and TypeSetting (-6)
           without starving :seg GC safepoints (was 499ms pause) or Binder calls. */
        if (tid > 0) setpriority(PRIO_PROCESS, tid, 8);
    }
    closedir(d);
}

static void jni_trim_heap(JNIEnvPtr e)
{
    jobj (*find_cls)(JNIEnvPtr, const char *) = (jobj (*)(JNIEnvPtr, const char *))((*e)[6]);
    jobj (*get_smid)(JNIEnvPtr, jobj, const char *, const char *) = (jobj (*)(JNIEnvPtr, jobj, const char *, const char *))((*e)[113]);
    jobj (*call_sobj)(JNIEnvPtr, jobj, jobj, ...) = (jobj (*)(JNIEnvPtr, jobj, jobj, ...))((*e)[114]);
    jobj (*get_mid)(JNIEnvPtr, jobj, const char *, const char *) = (jobj (*)(JNIEnvPtr, jobj, const char *, const char *))((*e)[33]);
    void (*call_void)(JNIEnvPtr, jobj, jobj, ...) = (void (*)(JNIEnvPtr, jobj, jobj, ...))((*e)[61]);

    jobj vmr = find_cls(e, "dalvik/system/VMRuntime");
    if (!vmr) { jni_clear_exc(e); return; }
    jobj m_get = get_smid(e, vmr, "getRuntime", "()Ldalvik/system/VMRuntime;");
    jobj m_gc = get_mid(e, vmr, "concurrentGC", "()V");
    jobj m_trim = get_mid(e, vmr, "trimHeap", "()V");
    if (!m_get || !m_trim) { jni_clear_exc(e); return; }
    jobj rt = call_sobj(e, vmr, m_get);
    jni_clear_exc(e);
    if (rt) {
        if (m_gc) {
            call_void(e, rt, m_gc);
            jni_clear_exc(e);
        }
        call_void(e, rt, m_trim);
        jni_clear_exc(e);
    }
}

static const char *load_weread_opt_jar(JNIEnvPtr e, jobj app, const char *proc_name)
{
    jobj (*find_cls)(JNIEnvPtr, const char *) = (jobj (*)(JNIEnvPtr, const char *))((*e)[6]);
    jobj (*new_obj)(JNIEnvPtr, jobj, jobj, ...) = (jobj (*)(JNIEnvPtr, jobj, jobj, ...))((*e)[28]);
    jobj (*get_mid)(JNIEnvPtr, jobj, const char *, const char *) = (jobj (*)(JNIEnvPtr, jobj, const char *, const char *))((*e)[33]);
    jobj (*call_obj)(JNIEnvPtr, jobj, jobj, ...) = (jobj (*)(JNIEnvPtr, jobj, jobj, ...))((*e)[34]);
    jobj (*get_smid)(JNIEnvPtr, jobj, const char *, const char *) = (jobj (*)(JNIEnvPtr, jobj, const char *, const char *))((*e)[113]);
    void (*call_svoid)(JNIEnvPtr, jobj, jobj, ...) = (void (*)(JNIEnvPtr, jobj, jobj, ...))((*e)[141]);
    jobj (*new_str)(JNIEnvPtr, const char *) = (jobj (*)(JNIEnvPtr, const char *))((*e)[167]);

    int fd = open("/system/framework/kobo-weread-opt.jar", 0);
    if (fd < 0) return "jar_missing";
    close(fd);

    jobj ctx = find_cls(e, "android/content/Context");
    jobj m_cl = ctx ? get_mid(e, ctx, "getClassLoader", "()Ljava/lang/ClassLoader;") : NULL;
    jobj m_cc = ctx ? get_mid(e, ctx, "getCodeCacheDir", "()Ljava/io/File;") : NULL;
    if (!m_cl || !m_cc) { jni_clear_exc(e); return "no_ctx_methods"; }
    jobj parent_cl = call_obj(e, app, m_cl);
    jobj cc_dir = call_obj(e, app, m_cc);
    jni_clear_exc(e);
    if (!parent_cl || !cc_dir) return "null_cl_or_cc";

    jobj file_cls = find_cls(e, "java/io/File");
    jobj m_path = file_cls ? get_mid(e, file_cls, "getAbsolutePath", "()Ljava/lang/String;") : NULL;
    if (!m_path) { jni_clear_exc(e); return "no_file_path"; }
    jobj opt_dir = call_obj(e, cc_dir, m_path);
    jni_clear_exc(e);
    if (!opt_dir) return "null_opt_dir";

    jobj dcl_cls = find_cls(e, "dalvik/system/DexClassLoader");
    jobj dcl_init = dcl_cls ? get_mid(e, dcl_cls, "<init>", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V") : NULL;
    jobj dcl_load = dcl_cls ? get_mid(e, dcl_cls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") : NULL;
    if (!dcl_init || !dcl_load) { jni_clear_exc(e); return "no_dcl"; }

    jobj s_jar = new_str(e, "/system/framework/kobo-weread-opt.jar");
    jobj dcl = new_obj(e, dcl_cls, dcl_init, s_jar, opt_dir, NULL, parent_cl);
    jni_clear_exc(e);
    if (!dcl) return "dcl_failed";

    jobj s_cls = new_str(e, "KoboWeReadOpt");
    jobj opt_cls = call_obj(e, dcl, dcl_load, s_cls);
    jni_clear_exc(e);
    if (!opt_cls) return "cls_missing";

    jobj m_init = get_smid(e, opt_cls, "init", "(Landroid/app/Application;Ljava/lang/String;)V");
    jni_clear_exc(e);
    if (!m_init) return "no_init_method";

    jobj s_proc = new_str(e, proc_name);
    call_svoid(e, opt_cls, m_init, app, s_proc);
    jni_clear_exc(e);
    return "loaded";
}

static void *weread_seg_opt_thread(void *unused)
{
    (void)unused;
    void *log = dlopen("liblog.so", RTLD_LAZY);
    int (*say)(int, const char *, const char *, ...) =
        log ? (int (*)(int, const char *, const char *, ...))dlsym(log, "__android_log_print") : NULL;

    int (*get_vms)(JavaVMPtr *, int, int *) =
        (int (*)(JavaVMPtr *, int, int *))dlsym((void *)-2L, "JNI_GetCreatedJavaVMs");
    if (!get_vms) {
        void *art = dlopen("/system/lib/libart.so", RTLD_LAZY);
        if (!art) art = dlopen("libart.so", RTLD_LAZY);
        if (art) get_vms = (int (*)(JavaVMPtr *, int, int *))dlsym(art, "JNI_GetCreatedJavaVMs");
    }
    JavaVMPtr vm = NULL;
    JNIEnvPtr env = NULL;
    int nvms = 0;
    if (get_vms && get_vms(&vm, 1, &nvms) == 0 && nvms >= 1 && vm) {
        int (*attach)(JavaVMPtr, void **, void *) = (int (*)(JavaVMPtr, void **, void *))((*vm)[7]);
        if (attach(vm, (void **)&env, NULL) == 0 && env) {
            jobj (*find_cls)(JNIEnvPtr, const char *) = (jobj (*)(JNIEnvPtr, const char *))((*env)[6]);
            jobj (*get_smid)(JNIEnvPtr, jobj, const char *, const char *) = (jobj (*)(JNIEnvPtr, jobj, const char *, const char *))((*env)[113]);
            jobj (*call_sobj)(JNIEnvPtr, jobj, jobj, ...) = (jobj (*)(JNIEnvPtr, jobj, jobj, ...))((*env)[114]);
            jobj at = find_cls(env, "android/app/ActivityThread");
            jobj m_cur = at ? get_smid(env, at, "currentApplication", "()Landroid/app/Application;") : NULL;
            jobj app = NULL;
            for (int i = 0; m_cur && i < 400 && !app; i++) {
                app = call_sobj(env, at, m_cur);
                jni_clear_exc(env);
                if (!app) usleep(15000);
            }
            if (app) {
                const char *r = load_weread_opt_jar(env, app, "com.tencent.weread.eink:seg");
                if (say) say(4, "KoboWeRead", "SEG_OPT_JAR result=%s", r);
            }
        }
    }
    if (say) say(4, "KoboWeRead", "SEG_OPT ready env=%p", (void *)env);

    int ticks = 0;
    for (;;) {
        lower_all_threads_nice8();
        int step = (ticks < 20) ? 2 : 10;
        usleep((unsigned int)step * 1000000u);
        ticks += step;
    }
    return NULL;
}

/* ---- Koboweread: ARM NEON Skia glyph & solid-color row blitters + log fsync skip ---- */
#ifdef __ARM_NEON
typedef void (*kobo_blit_mask_fn)(uint32_t *, size_t, const uint8_t *, size_t, uint32_t, int, int);
static kobo_blit_mask_fn orig_blit_mask = NULL;
static uint32_t (*sk_premultiply)(uint32_t) = NULL;
static int sk_alpha_lane = 3;

static inline uint8x8_t k_mul255(uint8x8_t x, uint8x8_t y)
{
    return vshrn_n_u16(vaddw_u8(vmull_u8(x, y), x), 8);
}

static inline uint8_t k_mul255s(uint8_t x, uint8_t y)
{
    return (uint8_t)((x * y + x) >> 8);
}

static void neon_blit_mask(uint32_t *dst, size_t dstRB, const uint8_t *mask, size_t maskRB,
                           uint32_t color, int w, int h)
{
    int mode = (color == 0xFF000000u) ? 0 : ((color >> 24) == 0xFFu) ? 1 : 2;
    uint32_t pm = sk_premultiply(color);
    uint8_t s[4];
    for (int k = 0; k < 4; k++) s[k] = (uint8_t)(pm >> (8 * k));
    const uint8x8_t ff = vdup_n_u8(255);
    for (; h > 0; h--, dst = (uint32_t *)((char *)dst + dstRB), mask += maskRB) {
        int x = 0;
        for (; x + 8 <= w; x += 8) {
            uint8x8x4_t d = vld4_u8((const uint8_t *)(dst + x));
            uint8x8_t aa = vld1_u8(mask + x);
            if (mode == 0) {
                uint8x8_t inv = vsub_u8(ff, aa);
                for (int k = 0; k < 4; k++) d.val[k] = k_mul255(d.val[k], inv);
                d.val[sk_alpha_lane] = vadd_u8(d.val[sk_alpha_lane], aa);
            } else {
                uint8x8_t left[4], inv;
                for (int k = 0; k < 4; k++) left[k] = k_mul255(vdup_n_u8(s[k]), aa);
                inv = vsub_u8(ff, mode == 1 ? aa : left[sk_alpha_lane]);
                for (int k = 0; k < 4; k++) d.val[k] = vadd_u8(left[k], k_mul255(d.val[k], inv));
            }
            vst4_u8((uint8_t *)(dst + x), d);
        }
        for (; x < w; x++) {
            uint8_t *p = (uint8_t *)(dst + x), aa = mask[x], inv, left[4];
            if (mode == 0) {
                inv = (uint8_t)(255 - aa);
                for (int k = 0; k < 4; k++) p[k] = k_mul255s(p[k], inv);
                p[sk_alpha_lane] = (uint8_t)(p[sk_alpha_lane] + aa);
                continue;
            }
            for (int k = 0; k < 4; k++) left[k] = k_mul255s(s[k], aa);
            inv = (uint8_t)(255 - (mode == 1 ? aa : left[sk_alpha_lane]));
            for (int k = 0; k < 4; k++) p[k] = (uint8_t)(left[k] + k_mul255s(p[k], inv));
        }
    }
}

static int neon_blit_matches(void)
{
    static uint32_t a[3 * 40], b[3 * 40];
    static uint8_t m[3 * 41];
    static const uint32_t colors[] = {
        0xFF000000u, 0xFF333333u, 0xFF8A5A2Bu, 0x80405060u, 0x20FFFFFFu, 0xFFFFFFFFu
    };
    uint32_t seed = 12345u;
    for (unsigned c = 0; c < sizeof(colors) / sizeof(*colors); c++) {
        for (unsigned i = 0; i < 3 * 41; i++) {
            seed = seed * 1103515245u + 12345u;
            m[i] = (uint8_t)(i % 5 == 0 ? 0 : i % 7 == 0 ? 255 : (seed >> 16));
        }
        for (unsigned i = 0; i < 3 * 40; i++) {
            seed = seed * 1103515245u + 12345u;
            uint8_t al = (uint8_t)(i % 3 ? 255 : (seed >> 24));
            uint8_t r = (uint8_t)((((seed >> 8) & 255u) * (al + 1u)) >> 8);
            uint8_t g = (uint8_t)((((seed >> 16) & 255u) * (al + 1u)) >> 8);
            uint8_t bl = (uint8_t)(((seed & 255u) * (al + 1u)) >> 8);
            uint8_t px[4] = { r, g, bl, r };
            px[sk_alpha_lane] = al;
            a[i] = b[i] = (uint32_t)px[0] | ((uint32_t)px[1] << 8) | ((uint32_t)px[2] << 16) | ((uint32_t)px[3] << 24);
        }
        orig_blit_mask(a, 40 * 4, m, 41, colors[c], 37, 3);
        neon_blit_mask(b, 40 * 4, m, 41, colors[c], 37, 3);
        for (unsigned i = 0; i < 3 * 40; i++)
            if (a[i] != b[i]) return -(int)(c + 1);
    }
    return 1;
}

static void install_neon_blit(void *skia, int (*say)(int, const char *, const char *, ...))
{
    kobo_blit_mask_fn *slot = (kobo_blit_mask_fn *)dlsym(skia, "_ZN6SkOpts16blit_mask_d32_a8E");
    sk_premultiply = (uint32_t (*)(uint32_t))dlsym(skia, "_Z18SkPreMultiplyColorj");
    if (!slot || !*slot || !sk_premultiply) {
        if (say) say(4, "KoboWeRead", "NEON_BLIT missing_symbols");
        return;
    }
    uint32_t black = sk_premultiply(0xFF000000u);
    for (sk_alpha_lane = 0; sk_alpha_lane < 4 && ((black >> (8 * sk_alpha_lane)) & 0xFFu) != 0xFFu; sk_alpha_lane++);
    if (sk_alpha_lane == 4) {
        if (say) say(4, "KoboWeRead", "NEON_BLIT no_alpha_lane");
        return;
    }
    orig_blit_mask = *slot;
    int ok = neon_blit_matches();
    if (ok == 1) *slot = neon_blit_mask;
    if (say) say(4, "KoboWeRead", "NEON_BLIT %s alpha_lane=%d", ok == 1 ? "installed" : "mismatch", sk_alpha_lane);
}

typedef void (*kobo_row_color_fn)(uint32_t *, const uint32_t *, int, uint32_t);
static kobo_row_color_fn orig_row_color = NULL;

static void neon_row_color(uint32_t *dst, const uint32_t *src, int count, uint32_t color)
{
    unsigned inv = 255u - (color >> 24);
    inv += inv >> 7;
    const uint8_t a = (uint8_t)inv;
    uint8_t c[16];
    for (int k = 0; k < 16; k++) c[k] = (uint8_t)(color >> (8 * (k & 3)));
    const uint8x16_t cv = vld1q_u8(c);
    const uint8x8_t av = vdup_n_u8(a);
    const uint16x8_t rnd = vdupq_n_u16(128);
    const uint16x8_t add_lo = vaddq_u16(vshll_n_u8(vget_low_u8(cv), 8), rnd);
    const uint16x8_t add_hi = vaddq_u16(vshll_n_u8(vget_high_u8(cv), 8), rnd);
    const uint8_t *s8 = (const uint8_t *)src;
    uint8_t *d8 = (uint8_t *)dst;
    int n = count * 4, i = 0;
    for (; i + 16 <= n; i += 16) {
        uint8x16_t x = vld1q_u8(s8 + i);
        uint16x8_t lo = vaddq_u16(vmull_u8(vget_low_u8(x), av), add_lo);
        uint16x8_t hi = vaddq_u16(vmull_u8(vget_high_u8(x), av), add_hi);
        vst1q_u8(d8 + i, vcombine_u8(vshrn_n_u16(lo, 8), vshrn_n_u16(hi, 8)));
    }
    for (; i < n; i++) d8[i] = (uint8_t)((uint16_t)(s8[i] * a + (c[i & 3] << 8) + 128) >> 8);
}

static int neon_color_matches(void)
{
    static uint32_t s[40], a[40], b[40];
    uint32_t seed = 54321u;
    for (unsigned al = 0; al < 256; al++) {
        seed = seed * 1103515245u + 12345u;
        uint32_t color = (al << 24) | ((seed >> 8) & 0xFFFFFFu);
        for (unsigned i = 0; i < 40; i++) {
            seed = seed * 1103515245u + 12345u;
            s[i] = seed ^ (seed << 7);
            a[i] = b[i] = s[i];
        }
        orig_row_color(a, s, 37, color);
        neon_row_color(b, s, 37, color);
        for (unsigned i = 0; i < 40; i++)
            if (a[i] != b[i]) return -(int)(al + 1);
        orig_row_color(a, a, 37, color);
        neon_row_color(b, b, 37, color);
        for (unsigned i = 0; i < 40; i++)
            if (a[i] != b[i]) return -(int)(al + 1) - 1000;
    }
    return 1;
}

static void install_neon_color(void *skia, int (*say)(int, const char *, const char *, ...))
{
    kobo_row_color_fn *slot = (kobo_row_color_fn *)dlsym(skia, "_ZN6SkOpts16blit_row_color32E");
    if (!slot || !*slot) {
        if (say) say(4, "KoboWeRead", "NEON_COLOR missing_symbols");
        return;
    }
    orig_row_color = *slot;
    int ok = neon_color_matches();
    if (ok == 1) *slot = neon_row_color;
    if (say) say(4, "KoboWeRead", "NEON_COLOR %s", ok == 1 ? "installed" : "mismatch");
}
#endif

/* Skip fsync/fdatasync ONLY on WeRead's own log files (wr-*.log, wr.log.*, /log/, /logs/, /BusReport/);
   SQLite, LevelDB, and SharedPreferences still sync normally. Eliminates 2-4s autoflush stalls on book close. */
static int str_has(const char *s, const char *w)
{
    for (; *s; s++) {
        int k = 0;
        while (w[k] && s[k] == w[k]) k++;
        if (!w[k]) return 1;
    }
    return 0;
}

static int skip_weread_log_sync(int fd)
{
    if (!is_weread_proc() || fd < 0) return 0;
    char p[40], l[256];
    int k = 0;
    const char *pre = "/proc/self/fd/";
    while (*pre) p[k++] = *pre++;
    char dig[16];
    int dn = 0, v = fd;
    if (v == 0) dig[dn++] = '0';
    else while (v > 0 && dn < 12) { dig[dn++] = (char)('0' + (v % 10)); v /= 10; }
    while (dn > 0) p[k++] = dig[--dn];
    p[k] = 0;
    long n = readlink(p, l, sizeof(l) - 1);
    if (n <= 0) return 0;
    l[n] = 0;
    const char *base = l;
    for (const char *c = l; *c; c++) if (*c == '/') base = c + 1;
    return str_has(l, "/log/") || str_has(l, "/logs/") || str_has(l, "/BusReport/") ||
           (base[0] == 'w' && base[1] == 'r' && (base[2] == '-' || str_has(base, "wr.log.")));
}

int fsync(int fd)
{
    if (skip_weread_log_sync(fd)) return 0;
    return (int)syscall(118L, fd);
}

int fdatasync(int fd)
{
    if (skip_weread_log_sync(fd)) return 0;
    return (int)syscall(148L, fd);
}

static void *weread_opt_thread(void *unused)
{
    (void)unused;
    void *log = dlopen("liblog.so", RTLD_LAZY);
    int (*say)(int, const char *, const char *, ...) =
        log ? (int (*)(int, const char *, const char *, ...))dlsym(log, "__android_log_print") : NULL;

    /* 1. Install NEON Skia blitters (byte-for-byte self-verified) + 16 MB Skia glyph cache */
    void *skia = dlopen("libskia.so", RTLD_LAZY);
    if (skia) {
#ifdef __ARM_NEON
        install_neon_blit(skia, say);
        install_neon_color(skia, say);
#endif
        unsigned (*set_lim)(unsigned) = (unsigned (*)(unsigned))dlsym(skia, "_ZN10SkGraphics17SetFontCacheLimitEj");
        int (*set_cnt)(int) = (int (*)(int))dlsym(skia, "_ZN10SkGraphics22SetFontCacheCountLimitEi");
        unsigned (*get_lim)(void) = (unsigned (*)(void))dlsym(skia, "_ZN10SkGraphics17GetFontCacheLimitEv");
        int (*get_cnt)(void) = (int (*)(void))dlsym(skia, "_ZN10SkGraphics22GetFontCacheCountLimitEv");
        if (set_lim) set_lim(16u << 20);
        if (set_cnt) set_cnt(16384);
        if (say && get_lim && get_cnt)
            say(4, "KoboWeRead", "SKIA_FONT_CACHE limit=%u count_limit=%d", get_lim(), get_cnt());
    }

    /* 2. Attach daemon thread to ART and defer WRWebViewPool.preInit */
    int (*get_vms)(JavaVMPtr *, int, int *) =
        (int (*)(JavaVMPtr *, int, int *))dlsym((void *)-2L, "JNI_GetCreatedJavaVMs");
    if (!get_vms) {
        void *art = dlopen("/system/lib/libart.so", RTLD_LAZY);
        if (!art) art = dlopen("libart.so", RTLD_LAZY);
        if (art) get_vms = (int (*)(JavaVMPtr *, int, int *))dlsym(art, "JNI_GetCreatedJavaVMs");
    }
    JavaVMPtr vm = NULL;
    JNIEnvPtr env = NULL;
    int nvms = 0;
    if (get_vms && get_vms(&vm, 1, &nvms) == 0 && nvms >= 1 && vm) {
        int (*attach)(JavaVMPtr, void **, void *) = (int (*)(JavaVMPtr, void **, void *))((*vm)[7]);
        if (attach(vm, (void **)&env, NULL) == 0 && env) {
            jobj (*find_cls)(JNIEnvPtr, const char *) = (jobj (*)(JNIEnvPtr, const char *))((*env)[6]);
            jobj (*get_smid)(JNIEnvPtr, jobj, const char *, const char *) = (jobj (*)(JNIEnvPtr, jobj, const char *, const char *))((*env)[113]);
            jobj (*call_sobj)(JNIEnvPtr, jobj, jobj, ...) = (jobj (*)(JNIEnvPtr, jobj, jobj, ...))((*env)[114]);
            jobj at = find_cls(env, "android/app/ActivityThread");
            jobj m_cur = at ? get_smid(env, at, "currentApplication", "()Landroid/app/Application;") : NULL;
            jobj app = NULL;
            for (int i = 0; m_cur && i < 400 && !app; i++) {
                app = call_sobj(env, at, m_cur);
                jni_clear_exc(env);
                if (!app) usleep(15000);
            }
            if (app) {
                const char *res = defer_webview_pool(env, app);
                if (say) say(4, "KoboWeRead", "WEBVIEW_POOL result=%s", res);
                const char *ores = load_weread_opt_jar(env, app, "com.tencent.weread.eink");
                if (say) say(4, "KoboWeRead", "MAIN_OPT_JAR result=%s", ores);
            } else if (say) {
                say(4, "KoboWeRead", "WEBVIEW_POOL skipped=no_app");
            }
        }
    } else if (say) {
        say(4, "KoboWeRead", "WEBVIEW_POOL skipped=no_vm get_vms=%p nvms=%d", (void *)get_vms, nvms);
    }

    /* 3. Background thread-pool priority loop (memory trimming handled by Java MemoryTrim) */
    int ticks = 0;
    for (;;) {
        tune_weread_threads();
        int step = (ticks < 30) ? 2 : 3;
        usleep((unsigned int)step * 1000000u);
        ticks += step;
    }
    return NULL;
}

static volatile int init_pid = 0;
static volatile int weread_pid = 0;
static volatile int weread_flag = 0;

static int is_weread_proc(void)
{
    int pid = getpid();
    if (__builtin_expect(weread_pid == pid, 1))
        return weread_flag;
    if (getuid() < 10000)
        return 0;
    char cmd[64];
    if (read_small_file("/proc/self/cmdline", cmd, sizeof(cmd)) <= 0)
        return 0;
    if (str_starts(cmd, "zygote") || str_starts(cmd, "<pre-initialized>"))
        return 0;
    int match = str_starts(cmd, "com.tencent.weread.eink");
    weread_flag = match;
    __sync_synchronize();
    weread_pid = pid;
    return match;
}

static void maybe_init_weread_opt(void)
{
    int pid = getpid();
    if (__builtin_expect(init_pid == pid, 1))
        return;
    if (getuid() < 10000)
        return;
    char cmd[64];
    if (read_small_file("/proc/self/cmdline", cmd, sizeof(cmd)) <= 0)
        return;
    if (str_starts(cmd, "zygote") || str_starts(cmd, "<pre-initialized>"))
        return;
    if (__sync_lock_test_and_set(&init_pid, pid) == pid)
        return;
    if (str_eq(cmd, "com.tencent.weread.eink")) {
        long tid = 0;
        if (pthread_create(&tid, NULL, weread_opt_thread, NULL) == 0)
            pthread_detach(tid);
    } else if (str_eq(cmd, "com.tencent.weread.eink:seg")) {
        long tid = 0;
        if (pthread_create(&tid, NULL, weread_seg_opt_thread, NULL) == 0)
            pthread_detach(tid);
    }
}
