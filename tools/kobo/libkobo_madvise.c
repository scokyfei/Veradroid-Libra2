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

extern long syscall(long, ...);
extern int open(const char *, int, ...);
extern int close(int);
extern long read(int, void *, size_t);
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
            str_starts(comm, "WRNetworkPool") ||
            str_starts(comm, "WRLowPriorityPo") ||
            str_starts(comm, "BUGLY_ASYNC") ||
            str_starts(comm, "Bugly") ||
            str_starts(comm, "RMonitor_") ||
            str_starts(comm, "OssLog") ||
            str_starts(comm, "RxIoScheduler") ||
            str_starts(comm, "RxComputationSc") ||
            str_starts(comm, "glide-")) {
            setpriority(PRIO_PROCESS, tid, 19);
        } else if (str_starts(comm, "TypeSetting")) {
            setpriority(PRIO_PROCESS, tid, -2);
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

static void lower_all_threads_nice19(void)
{
    void *d = opendir("/proc/self/task");
    if (!d) return;
    struct kobo_dirent *ent;
    while ((ent = (struct kobo_dirent *)readdir(d)) != NULL) {
        if (ent->d_name[0] < '1' || ent->d_name[0] > '9')
            continue;
        unsigned int tid = (unsigned int)parse_uint(ent->d_name);
        if (tid > 0) setpriority(PRIO_PROCESS, tid, 19);
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
    int last_trim = -90;
    for (;;) {
        lower_all_threads_nice19();
        int step = (ticks < 20) ? 2 : 10;
        usleep((unsigned int)step * 1000000u);
        ticks += step;
        if (env && (ticks - last_trim) >= 90 && (ticks % 30) < step) {
            int avail = read_mem_available_kb();
            if (avail < 160000) {
                int before = read_self_rss_kb();
                jni_trim_heap(env);
                last_trim = ticks;
                if (say) say(4, "KoboWeRead", "SEG_TRIM avail_kb=%d rss_kb=%d->%d", avail, before, read_self_rss_kb());
            }
        }
    }
    return NULL;
}

static void *weread_opt_thread(void *unused)
{
    (void)unused;
    void *log = dlopen("liblog.so", RTLD_LAZY);
    int (*say)(int, const char *, const char *, ...) =
        log ? (int (*)(int, const char *, const char *, ...))dlsym(log, "__android_log_print") : NULL;

    /* 1. Raise Skia software glyph cache to 16 MB / 16384 glyphs */
    void *skia = dlopen("libskia.so", RTLD_LAZY);
    if (skia) {
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

    /* 3. Background thread-pool priority loop + low-memory concurrentGC()+trimHeap() */
    int ticks = 0;
    int last_trim = -90;
    for (;;) {
        tune_weread_threads();
        int step = (ticks < 30) ? 2 : 15;
        usleep((unsigned int)step * 1000000u);
        ticks += step;
        if (env && (ticks - last_trim) >= 90 && (ticks % 30) < step) {
            int avail = read_mem_available_kb();
            if (avail < 160000) {
                int before = read_self_rss_kb();
                jni_trim_heap(env);
                last_trim = ticks;
                if (say) say(4, "KoboWeRead", "MEM_TRIM avail_kb=%d rss_kb=%d->%d", avail, before, read_self_rss_kb());
            }
        }
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
