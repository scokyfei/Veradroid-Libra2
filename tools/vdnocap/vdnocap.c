/*
 * vdnocap: start an Android daemon without the two capabilities that let it keep the device awake.
 *
 * Why (fix/standby-drain, 2026-11-20): Android's healthd puts its battery uevent socket and its periodic
 * timerfd into an epoll set with EPOLLWAKEUP, and arms that timerfd on CLOCK_BOOTTIME_ALARM.  While Android
 * is frozen (screensaver / deep sleep), the next uevent / timer expiry activates a kernel wakeup source
 * or RTC alarm that interrupts suspend every 10 minutes.
 *
 * Without CAP_BLOCK_SUSPEND the kernel silently drops EPOLLWAKEUP (fs/eventpoll.c ep_take_care_of_epollwakeup),
 * and without CAP_WAKE_ALARM timerfd_create(CLOCK_*_ALARM) fails, so healthd keeps working off uevents only.
 * (Dropping them for the whole container is not an option: zygote capset()s CAP_BLOCK_SUSPEND for
 * system_server and aborts when that fails.)
 *
 * Use: the host bind-mounts this binary over /sbin/<name> and the original over /dev/vdlib/<name>.real
 * (host/kobo/boot/lib/container.sh nocap_mount).  Called as <name>, it drops the two capabilities from its
 * bounding set and execs /dev/vdlib/<name>.real with the same argv; the exec of a root process then gets a
 * permitted set without them.  Called as "vdnocap PROG ARGS..." it does the same for PROG (tests).
 * Errors dropping a capability the kernel does not know (EINVAL, e.g. CAP_BLOCK_SUSPEND before 3.5) are ignored.
 *
 * Build: tools/kobo/build-kobo-bin.sh (static armhf, no libc features beyond prctl / execv).
 */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#ifndef PR_CAPBSET_DROP
#define PR_CAPBSET_DROP 24
#endif
#define VD_CAP_WAKE_ALARM 35
#define VD_CAP_BLOCK_SUSPEND 36

static void drop(int cap)
{
    if (prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0 && errno != EINVAL)
        fprintf(stderr, "vdnocap: PR_CAPBSET_DROP %d: %s\n", cap, strerror(errno));
}

int main(int argc, char **argv)
{
    const char *name = argc > 0 && argv[0] ? argv[0] : "";
    const char *base = strrchr(name, '/');
    char real[256];

    base = base ? base + 1 : name;
    drop(VD_CAP_BLOCK_SUSPEND);
    drop(VD_CAP_WAKE_ALARM);
    if (strcmp(base, "vdnocap") == 0) {
        if (argc < 2) {
            fprintf(stderr, "usage: vdnocap PROG [ARGS...]\n");
            return 2;
        }
        execv(argv[1], argv + 1);
        fprintf(stderr, "vdnocap: exec %s: %s\n", argv[1], strerror(errno));
        return 127;
    }
    if (snprintf(real, sizeof real, "/dev/vdlib/%s.real", base) >= (int)sizeof real)
        return 127;
    execv(real, argv);
    fprintf(stderr, "vdnocap: exec %s: %s\n", real, strerror(errno));
    return 127;
}
