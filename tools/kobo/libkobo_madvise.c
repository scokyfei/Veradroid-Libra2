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
