/* SPDX-License-Identifier: GPL-3.0-or-later
 * Zero-FUSE bind-mount replacement for Android /system/bin/sdcard on kernels
 * built without CONFIG_FUSE_FS (e.g. Kobo Libra 2 stock Linux 4.1.15).
 *
 * Android 7.1 vold spawns:
 *   /system/bin/sdcard -u 1023 -g 1023 -m -w /data/media emulated
 * and polls stat("/mnt/runtime/default/<label>").st_dev every 50 ms until it
 * differs from /mnt/runtime/default. Without /dev/fuse the stock FUSE daemon
 * exits immediately, leaving vold wedged forever in "Waiting for FUSE to spin up..."
 * and blocking every app's getExternalFilesDir() for 60s timeouts (e.g. WeRead).
 *
 * Bind-mounting <src> onto /mnt/runtime/{default,read,write}/<label> satisfies
 * vold immediately with native ext4 speed and zero FUSE / CPU spin overhead.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

static volatile sig_atomic_t stop_flag = 0;

static void on_term(int sig)
{
    (void)sig;
    stop_flag = 1;
}

static void bind_one(const char *src, const char *dst)
{
    mkdir(dst, 0755);
    if (mount(src, dst, NULL, MS_BIND | MS_REC, NULL) != 0) {
        if (mount(src, dst, NULL, MS_BIND, NULL) != 0) {
            fprintf(stderr, "kobo-sdcard: mount --bind %s -> %s failed: %s\n",
                    src, dst, strerror(errno));
        }
    }
}

int main(int argc, char **argv)
{
    const char *pos[4] = {0};
    int npos = 0;
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-') {
            if (argv[i][1] && strchr("ugUtl", argv[i][1]) && !argv[i][2] && i + 1 < argc)
                i++;
            continue;
        }
        if (npos < 4) pos[npos++] = argv[i];
    }

    const char *src = (npos >= 2) ? pos[0] : "/data/media";
    const char *label = (npos >= 2) ? pos[1] : "emulated";

    chmod(src, 0777);
    char sub0[256];
    snprintf(sub0, sizeof(sub0), "%s/0", src);
    mkdir(sub0, 0777);
    chmod(sub0, 0777);

    const char *views[3] = { "default", "read", "write" };
    for (int i = 0; i < 3; i++) {
        char dst[256];
        snprintf(dst, sizeof(dst), "/mnt/runtime/%s/%s", views[i], label);
        bind_one(src, dst);
    }

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    while (!stop_flag) pause();
    return 0;
}
