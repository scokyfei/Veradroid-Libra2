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
extern int ioctl(int, unsigned long, ...);
extern int *__errno(void);
extern void *dlsym(void *, const char *);

#define RTLD_NEXT       ((void *)-1L)
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

int madvise(void *addr, size_t length, int advice)
{
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
        0x61, 0x25, 0x42, 0x56, 0x66, 0x83, 0x34, 0xda, 0x58, 0xef, 0x69, 0x6b
    };

    if (!real_ssl_write) {
        real_ssl_write = (ssl_write_fn)dlsym(RTLD_NEXT, "SSL_write");
        if (!real_ssl_write)
            return -1;
    }

    if (buf && num >= 12 && num <= 4096) {
        const unsigned char *p = (const unsigned char *)buf;
        int pos = match_bytes(p, num, hpack_pat, 12);
        int apos = (pos < 0 && num >= 17) ? match_bytes(p, num, ascii_pat, 17) : -1;
        if (pos >= 0 || apos >= 0) {
            unsigned char tmp[4096];
            int i;
            for (i = 0; i < num; i++)
                tmp[i] = p[i];
            if (pos >= 0)
                tmp[pos + 11] = 0x68;
            if (apos >= 0)
                tmp[apos + 16] = 'l';
            return real_ssl_write(ssl, tmp, num);
        }
    }

    return real_ssl_write(ssl, buf, num);
}
