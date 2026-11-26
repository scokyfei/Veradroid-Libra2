// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * vdbtkeys: Bluetooth input bridge for VeraDroid (host side, runs on the Kindle).
 *
 * Kindle's own Bluetooth stack (btmanagerd / acsbtfd, a Bluedroid fork) keeps the radio. When a Bluetooth HID device
 * (page turner, keyboard, Kindle Remote) connects, its HID host creates a kernel input device through /dev/uhid
 * (bus BUS_BLUETOOTH) — or, on 5.20+, input_manager re-emits the Kindle Remote on the virtual "kindle-input-pt".
 * Android runs in a container with a private /dev, so it never sees those late nodes. This bridge:
 *
 *   - creates one persistent uinput device "veradroid-btkeys" at start (bound into the container as an input node),
 *     with page-turn / navigation / media keys only (NOT alphabetic, so Android keeps showing the soft keyboard);
 *   - watches /dev/input with inotify (no polling, no timers -> no wakeups while idle);
 *   - page turners (BT device without letter keys, or kindle-input-pt): EVIOCGRAB, remap forward/back keys
 *     (--map volume|page|dpad|raw; volume = KEY_VOLUMEDOWN/UP which WeRead/most readers page with), emit on btkeys;
 *   - keyboards (BT device with letter keys): EVIOCGRAB, create a per-device uinput clone "veradroid-btkbd" and
 *     mknod its node into the container (/proc/<pid>/root/dev/input), so Android hot-plugs it; removed on disconnect;
 *   - SIGUSR1 = release (back in the Kindle UI: ungrab so Kindle's own page turning works), SIGUSR2 = grab again;
 *   - while a --drop-flag file exists (Android frozen behind the screensaver) events are dropped, not queued.
 *
 * Usage: vdbtkeys <log> [--map volume|page|dpad|raw] [--swap] [--conf settings.conf (SIGHUP re-reads)] [--pidfile FILE (container init pid)]
 *                       [--drop-flag FILE]... [--action SCRIPT] [--name-match NAME]... [--state FILE] [--no-kindle-pt]
 *   --state FILE   : rewritten on every connect / disconnect, one "kind<TAB>name" line per bridged device (status.sh reads it)
 *   --no-kindle-pt : leave kindle-input-pt alone (only real Bluetooth devices are bridged)
 *   A keyboard that connects before the container exists is published into the container as soon as its init appears
 *   (poll wakes every 2 s only while such a keyboard is pending; otherwise poll blocks forever).
 * Build: arm-linux-gnueabihf-gcc -O2 -static -o vdbtkeys vdbtkeys.c
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAXDEV 16
#define BITS_PER_LONG (sizeof(long) * 8)
#define NLONGS(x) (((x) + BITS_PER_LONG - 1) / BITS_PER_LONG)
#define TESTBIT(b, a) ((a[(b) / BITS_PER_LONG] >> ((b) % BITS_PER_LONG)) & 1)

struct dev {
    int fd;            /* source evdev */
    int kbd;           /* 1 = keyboard clone, 0 = page turner */
    int ufd;           /* keyboard clone uinput fd (kbd only) */
    char path[64], name[128], clone_node[160];
    int grabbed;
    int pending;       /* keyboard clone not yet visible in the container (no container pid yet) */
};

static FILE *logf_;
static struct dev devs[MAXDEV];
static int btkeys = -1;
static const char *map = "volume";
static int swap_dir;
static const char *pidfile, *action;
static const char *drops[4]; static int ndrops;
static const char *names[4]; static int nnames;
static const char *statefile; static int no_kindle_pt;
static volatile sig_atomic_t want_release, want_grab, want_quit, want_conf;
static const char *conf;
static char mapbuf[16];
static int released;

static void lg(const char *fmt, ...) {
    if (!logf_) return;
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    fprintf(logf_, "[%02d:%02d:%02d] ", tm.tm_hour, tm.tm_min, tm.tm_sec);
    va_list ap; va_start(ap, fmt); vfprintf(logf_, fmt, ap); va_end(ap);
    fputc('\n', logf_); fflush(logf_);
}

static void on_sig(int s) { if (s == SIGUSR1) want_release = 1; else if (s == SIGUSR2) want_grab = 1; else if (s == SIGHUP) want_conf = 1; else want_quit = 1; }

/* --conf FILE: BT_PT_MAP=volume|page|dpad|raw and BT_PT_SWAP=0|1 lines (VeraDroid settings.conf); re-read on SIGHUP */
static void read_conf(void) {
    if (!conf) return;
    FILE *f = fopen(conf, "r"); if (!f) return;
    char l[256];
    while (fgets(l, sizeof l, f)) {
        l[strcspn(l, "\r\n")] = 0;
        if (!strncmp(l, "BT_PT_MAP=", 10)) {
            const char *v = l + 10;
            if (!strcmp(v, "volume") || !strcmp(v, "page") || !strcmp(v, "dpad") || !strcmp(v, "raw")) { snprintf(mapbuf, sizeof mapbuf, "%s", v); map = mapbuf; }
        } else if (!strncmp(l, "BT_PT_SWAP=", 11)) swap_dir = l[11] == '1';
    }
    fclose(f);
    lg("conf: map=%s swap=%d", map, swap_dir);
}

static const int pt_keys[] = { KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_PAGEUP, KEY_PAGEDOWN, KEY_UP, KEY_DOWN, KEY_LEFT,
    KEY_RIGHT, KEY_ENTER, KEY_SPACE, KEY_NEXTSONG, KEY_PREVIOUSSONG, KEY_PLAYPAUSE, KEY_BACK, KEY_ESC, KEY_MENU };

static int uinput_open(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) fd = open("/dev/input/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    return fd;
}

static int uinput_create(int fd, const char *name, unsigned short vendor, unsigned short product) {
    struct uinput_user_dev u; memset(&u, 0, sizeof u);
    snprintf(u.name, sizeof u.name, "%s", name);
    u.id.bustype = BUS_VIRTUAL; u.id.vendor = vendor; u.id.product = product; u.id.version = 1;
    if (write(fd, &u, sizeof u) != sizeof u) return -1;
    return ioctl(fd, UI_DEV_CREATE);
}

static int make_btkeys(void) {
    int fd = uinput_open();
    if (fd < 0) { lg("uinput open failed: %s", strerror(errno)); return -1; }
    ioctl(fd, UI_SET_EVBIT, EV_KEY); ioctl(fd, UI_SET_EVBIT, EV_SYN);
    for (size_t i = 0; i < sizeof pt_keys / sizeof pt_keys[0]; i++) ioctl(fd, UI_SET_KEYBIT, pt_keys[i]);
    if (uinput_create(fd, "veradroid-btkeys", 0x5644, 0x0b74) < 0) { lg("btkeys create failed: %s", strerror(errno)); close(fd); return -1; }
    lg("created veradroid-btkeys");
    return fd;
}

static void emit(int fd, int type, int code, int value) {
    struct input_event e; memset(&e, 0, sizeof e);
    e.type = type; e.code = code; e.value = value;
    if (write(fd, &e, sizeof e) < 0) lg("emit failed: %s", strerror(errno));
}

static int dropping(void) {
    struct stat st;
    for (int i = 0; i < ndrops; i++) if (stat(drops[i], &st) == 0) return 1;
    return 0;
}

/* forward = 1, back = -1, other = 0 */
static int direction(int code) {
    switch (code) {
    case KEY_PAGEDOWN: case KEY_RIGHT: case KEY_DOWN: case KEY_VOLUMEDOWN: case KEY_NEXTSONG: case KEY_SPACE:
    case KEY_ENTER: return 1;
    case KEY_PAGEUP: case KEY_LEFT: case KEY_UP: case KEY_VOLUMEUP: case KEY_PREVIOUSSONG: return -1;
    }
    return 0;
}

static int remap(int code) {
    if (!strcmp(map, "raw")) return code;
    int d = direction(code);
    if (!d) return code;
    if (swap_dir) d = -d;
    if (!strcmp(map, "page")) return d > 0 ? KEY_PAGEDOWN : KEY_PAGEUP;
    if (!strcmp(map, "dpad")) return d > 0 ? KEY_RIGHT : KEY_LEFT;
    return d > 0 ? KEY_VOLUMEDOWN : KEY_VOLUMEUP;   /* volume (default) */
}

/*
 * 翻页动画的方向（显示桥的 KFB_ANIM_MODE=1 “跟随手势”）：方向只从显示桥收到的 DIR 来，以前只有触摸前端
 * （veradroid-input：左划 / 点右半边 = 2，右划 / 点左半边 = 3）会发，翻页器的按键从来不发，所以按“上一页”时
 * 动画还是上一次触摸留下的方向（多半是从右往左）。按下翻页键时和触摸前端一样先发一个方向提示：
 * 下一页 2（从右往左滑入），上一页 3。只是提示，不强制动画；显示桥不在时什么都不做。
 */
static void epd_dir(int d) {
    int fd = open("/tmp/veradroid/kfb/epd.fifo", O_WRONLY | O_NONBLOCK);
    if (fd < 0) fd = open("/dev/shm/veradroid/kfb/epd.fifo", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return;
    char b[16];
    int n = snprintf(b, sizeof b, "DIR %d\n", d > 0 ? 2 : 3);
    if (write(fd, b, n) < 0) { /* bridge not reading */ }
    close(fd);
}

static void run_action(const char *a, const char *arg) {
    if (!action) return;
    pid_t p = fork();
    if (p == 0) { setsid(); execl("/bin/sh", "sh", action, a, arg, (char *)NULL); _exit(127); }
}

static int container_pid(void) {
    if (!pidfile) return 0;
    FILE *f = fopen(pidfile, "r"); int p = 0;
    if (f) { if (fscanf(f, "%d", &p) != 1) p = 0; fclose(f); }
    if (p > 0 && kill(p, 0) == 0) return p;
    return 0;
}

/* find eventN of the newest input device with this name (fallback when UI_GET_SYSNAME is missing) */
static int find_event_by_name(const char *name, char *out, size_t n) {
    DIR *d = opendir("/sys/class/input"); if (!d) return -1;
    struct dirent *e; int best = -1;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "event", 5)) continue;
        char p[256], nm[160] = ""; snprintf(p, sizeof p, "/sys/class/input/%s/device/name", e->d_name);
        FILE *f = fopen(p, "r"); if (!f) continue;
        if (fgets(nm, sizeof nm, f)) nm[strcspn(nm, "\n")] = 0;
        fclose(f);
        if (!strcmp(nm, name)) { int k = atoi(e->d_name + 5); if (k > best) best = k; }
    }
    closedir(d);
    if (best < 0) return -1;
    snprintf(out, n, "event%d", best);
    return 0;
}

/* eventN of a uinput device we created: UI_GET_SYSNAME (inputN) -> its eventN child in sysfs */
static int uinput_event(int ufd, const char *name, char *out, size_t n) {
#ifdef UI_GET_SYSNAME
    char sys[64] = "";
    if (ioctl(ufd, UI_GET_SYSNAME(sizeof sys), sys) >= 0) {
        char p[128]; snprintf(p, sizeof p, "/sys/class/input/%s", sys);
        for (int i = 0; i < 20; i++) {
            DIR *d = opendir(p); struct dirent *e;
            if (d) {
                while ((e = readdir(d))) if (!strncmp(e->d_name, "event", 5)) { snprintf(out, n, "%s", e->d_name); closedir(d); return 0; }
                closedir(d);
            }
            usleep(50000);
        }
    }
#endif
    for (int i = 0; i < 20; i++) { if (find_event_by_name(name, out, n) == 0) return 0; usleep(50000); }
    return -1;
}

/* make the keyboard clone visible to Android: mknod its char device inside the container's /dev/input.
 * The device number comes from sysfs, so this also works on kernels without devtmpfs. */
static void clone_publish(struct dev *dv) {
    char ev[32], p[128], num[32] = "";
    if (uinput_event(dv->ufd, "veradroid-btkbd", ev, sizeof ev) < 0) { lg("btkbd node not found"); dv->pending = 0; return; }
    snprintf(p, sizeof p, "/sys/class/input/%s/dev", ev);
    FILE *f = fopen(p, "r"); if (f) { if (!fgets(num, sizeof num, f)) num[0] = 0; fclose(f); }
    unsigned ma, mi;
    if (sscanf(num, "%u:%u", &ma, &mi) != 2) { lg("%s: no device number", p); dv->pending = 0; return; }
    snprintf(p, sizeof p, "/dev/input/%s", ev); chmod(p, 0666);
    int pid = container_pid();
    char root[96]; struct stat st_host, st_ct;
    snprintf(root, sizeof root, "/proc/%d/root/system/build.prop", pid);
    /* Not before Android's root is in place: before pivot_root /proc/<pid>/root/dev/input is the host's devtmpfs,
     * and unlinking "our" node there would delete a real host node. */
    if (!pid || access(root, F_OK) < 0) {
        if (!dv->pending) lg("keyboard %s: container not running yet, will publish when it is", dv->name);
        dv->pending = 1; return;
    }
    snprintf(root, sizeof root, "/proc/%d/root/dev/input", pid);
    if (stat(root, &st_ct) < 0) { dv->pending = 1; return; }
    if (stat("/dev/input", &st_host) == 0 && st_host.st_dev == st_ct.st_dev) {
        /* container shares the host's /dev (chroot mode on old kernels): the node is already visible there */
        dv->pending = 0; lg("keyboard %s -> %s (shared /dev)", dv->name, ev); return;
    }
    snprintf(dv->clone_node, sizeof dv->clone_node, "/proc/%d/root/dev/input/%s", pid, ev);
    unlink(dv->clone_node);
    if (mknod(dv->clone_node, S_IFCHR | 0666, makedev(ma, mi)) < 0) {
        /* container's /dev/input not there yet (init still setting up): try again later */
        if (!dv->pending) lg("mknod %s: %s (will retry)", dv->clone_node, strerror(errno));
        dv->clone_node[0] = 0; dv->pending = 1; return;
    }
    chmod(dv->clone_node, 0666);
    dv->pending = 0;
    lg("keyboard %s -> %s (%u:%u) in container", dv->name, dv->clone_node, ma, mi);
}

static void write_state(void) {
    if (!statefile) return;
    char tmp[256]; snprintf(tmp, sizeof tmp, "%s.tmp", statefile);
    FILE *f = fopen(tmp, "w"); if (!f) return;
    for (int i = 0; i < MAXDEV; i++)
        if (devs[i].fd >= 0) fprintf(f, "%s\t%s\n", devs[i].kbd ? "keyboard" : "pageturner", devs[i].name);
    fclose(f); rename(tmp, statefile);
}

static int make_clone(struct dev *dv) {
    int fd = uinput_open(); if (fd < 0) return -1;
    unsigned long ev[NLONGS(EV_CNT)] = {0}, keys[NLONGS(KEY_CNT)] = {0};
    ioctl(dv->fd, EVIOCGBIT(0, sizeof ev), ev);
    ioctl(dv->fd, EVIOCGBIT(EV_KEY, sizeof keys), keys);
    ioctl(fd, UI_SET_EVBIT, EV_KEY); ioctl(fd, UI_SET_EVBIT, EV_SYN);
    if (TESTBIT(EV_REP, ev)) ioctl(fd, UI_SET_EVBIT, EV_REP);
    if (TESTBIT(EV_LED, ev)) { ioctl(fd, UI_SET_EVBIT, EV_LED); for (int l = 0; l < LED_CNT; l++) ioctl(fd, UI_SET_LEDBIT, l); }
    for (int k = 1; k < KEY_CNT; k++) if (TESTBIT(k, keys)) ioctl(fd, UI_SET_KEYBIT, k);
    if (uinput_create(fd, "veradroid-btkbd", 0x5644, 0x0b75) < 0) { close(fd); return -1; }
    dv->ufd = fd;
    clone_publish(dv);
    return 0;
}

static void dev_close(struct dev *dv, const char *why) {
    lg("drop %s (%s): %s", dv->path, dv->name, why);
    if (dv->clone_node[0]) { unlink(dv->clone_node); dv->clone_node[0] = 0; }
    if (dv->ufd >= 0) { ioctl(dv->ufd, UI_DEV_DESTROY); close(dv->ufd); }
    close(dv->fd);
    memset(dv, 0, sizeof *dv); dv->fd = -1; dv->ufd = -1;
    write_state();
}

static int sysattr(const char *ev, const char *attr, char *out, size_t n) {
    char p[256]; snprintf(p, sizeof p, "/sys/class/input/%s/device/%s", ev, attr);
    FILE *f = fopen(p, "r"); if (!f) return -1;
    if (!fgets(out, n, f)) out[0] = 0;
    out[strcspn(out, "\n")] = 0; fclose(f); return 0;
}

static void try_add(const char *ev) {
    if (strncmp(ev, "event", 5)) return;
    char path[64]; snprintf(path, sizeof path, "/dev/input/%s", ev);
    for (int i = 0; i < MAXDEV; i++) if (devs[i].fd >= 0 && !strcmp(devs[i].path, path)) return;
    char name[128] = "", bus[16] = "";
    if (sysattr(ev, "name", name, sizeof name) < 0) return;
    sysattr(ev, "id/bustype", bus, sizeof bus);
    if (!strncmp(name, "veradroid-", 10)) return;
    int ispt = !no_kindle_pt && !strcmp(name, "kindle-input-pt");
    int isbt = strtol(bus, NULL, 16) == BUS_BLUETOOTH;
    int named = 0;
    for (int i = 0; i < nnames; i++) if (!strcmp(name, names[i])) named = 1;
    if (!ispt && !isbt && !named) return;
    int slot = -1;
    for (int i = 0; i < MAXDEV; i++) if (devs[i].fd < 0) { slot = i; break; }
    if (slot < 0) { lg("too many devices, ignoring %s", name); return; }
    int fd = -1;
    for (int i = 0; i < 10 && fd < 0; i++) { fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC); if (fd < 0) usleep(100000); }
    if (fd < 0) { lg("open %s (%s): %s", path, name, strerror(errno)); return; }
    struct dev *dv = &devs[slot];
    dv->fd = fd; dv->ufd = -1; dv->clone_node[0] = 0;
    snprintf(dv->path, sizeof dv->path, "%s", path); snprintf(dv->name, sizeof dv->name, "%s", name);
    unsigned long keys[NLONGS(KEY_CNT)] = {0};
    ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keys), keys);
    int letters = 0;
    for (int k = KEY_Q; k <= KEY_M; k++) if (TESTBIT(k, keys)) letters++;
    dv->kbd = !ispt && letters >= 20;
    if (!released) {
        if (ioctl(fd, EVIOCGRAB, 1) < 0) {
            /* 5.20+: input_manager already holds the raw Kindle Remote; we get it via kindle-input-pt instead */
            lg("grab %s (%s) failed: %s -> leave it to its owner", path, name, strerror(errno));
            close(fd); dv->fd = -1; return;
        }
        dv->grabbed = 1;
    }
    lg("add %s name=\"%s\" bus=%s %s", path, name, bus, dv->kbd ? "keyboard" : "page-turner");
    if (dv->kbd && make_clone(dv) < 0) lg("keyboard clone failed: %s", strerror(errno));
    write_state();
}

static void scan_all(void) {
    DIR *d = opendir("/dev/input"); if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) try_add(e->d_name);
    closedir(d);
}

static void handle(struct dev *dv) {
    struct input_event e[32];
    for (;;) {
        ssize_t r = read(dv->fd, e, sizeof e);
        if (r < 0) { if (errno == EAGAIN) return; dev_close(dv, strerror(errno)); return; }
        if (r == 0) { dev_close(dv, "eof"); return; }
        if (released || dropping()) continue;     /* Kindle UI in front, or Android frozen: never queue */
        int n = r / sizeof e[0];
        for (int i = 0; i < n; i++) {
            if (dv->kbd) { if (dv->ufd >= 0 && write(dv->ufd, &e[i], sizeof e[i]) < 0) lg("kbd write: %s", strerror(errno)); continue; }
            if (e[i].type != EV_KEY) continue;
            int c = e[i].code, v = e[i].value;
            if (c == KEY_BRIGHTNESSUP || c == KEY_BRIGHTNESSDOWN) { if (v) run_action("light", c == KEY_BRIGHTNESSUP ? "+" : "-"); continue; }
            if (c == KEY_POWER) continue;               /* Kindle Remote "sleep": Kindle's powerd owns sleep */
            int m = remap(c);
            if (v == 1) { int d = direction(c); if (d) epd_dir(swap_dir ? -d : d); }   /* before Android draws the new page */
            emit(btkeys, EV_KEY, m, v); emit(btkeys, EV_SYN, SYN_REPORT, 0);
            if (v == 1) lg("key %d -> %d", c, m);
        }
    }
}

static void set_grab(int on) {
    for (int i = 0; i < MAXDEV; i++) {
        if (devs[i].fd < 0) continue;
        if (ioctl(devs[i].fd, EVIOCGRAB, on ? 1 : 0) == 0) devs[i].grabbed = on;
    }
    released = !on;
    lg(on ? "grab (android in front)" : "release (kindle in front)");
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: vdbtkeys <log> [--map volume|page|dpad|raw] [--swap] [--conf F] [--pidfile F] [--drop-flag F] [--action S] [--name-match N] [--state F] [--no-kindle-pt]\n"); return 2; }
    logf_ = fopen(argv[1], "a");
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--map") && i + 1 < argc) map = argv[++i];
        else if (!strcmp(argv[i], "--swap")) swap_dir = 1;
        else if (!strcmp(argv[i], "--conf") && i + 1 < argc) conf = argv[++i];
        else if (!strcmp(argv[i], "--pidfile") && i + 1 < argc) pidfile = argv[++i];
        else if (!strcmp(argv[i], "--drop-flag") && i + 1 < argc && ndrops < 4) drops[ndrops++] = argv[++i];
        else if (!strcmp(argv[i], "--action") && i + 1 < argc) action = argv[++i];
        else if (!strcmp(argv[i], "--name-match") && i + 1 < argc && nnames < 4) names[nnames++] = argv[++i];
        else if (!strcmp(argv[i], "--state") && i + 1 < argc) statefile = argv[++i];
        else if (!strcmp(argv[i], "--no-kindle-pt")) no_kindle_pt = 1;
    }
    for (int i = 0; i < MAXDEV; i++) { devs[i].fd = -1; devs[i].ufd = -1; }
    signal(SIGCHLD, SIG_IGN);
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_handler = on_sig;
    sigaction(SIGUSR1, &sa, NULL); sigaction(SIGUSR2, &sa, NULL); sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL); sigaction(SIGHUP, &sa, NULL);
    read_conf();
    btkeys = make_btkeys();
    if (btkeys < 0) return 1;
    int in = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (in < 0 || inotify_add_watch(in, "/dev/input", IN_CREATE | IN_ATTRIB | IN_MOVED_TO) < 0) lg("inotify: %s", strerror(errno));
    lg("start map=%s swap=%d", map, swap_dir);
    write_state();
    scan_all();
    while (!want_quit) {
        if (want_release) { want_release = 0; set_grab(0); }
        if (want_grab) { want_grab = 0; set_grab(1); }
        if (want_conf) { want_conf = 0; read_conf(); }
        struct pollfd p[MAXDEV + 1]; int idx[MAXDEV + 1], n = 0;
        p[n].fd = in; p[n].events = POLLIN; idx[n++] = -1;
        for (int i = 0; i < MAXDEV; i++) if (devs[i].fd >= 0) { p[n].fd = devs[i].fd; p[n].events = POLLIN; idx[n++] = i; }
        int pend = 0;
        for (int i = 0; i < MAXDEV; i++) if (devs[i].fd >= 0 && devs[i].pending) pend = 1;
        int r = poll(p, n, pend ? 2000 : -1);         /* block forever unless a keyboard waits for the container */
        if (pend) for (int i = 0; i < MAXDEV; i++) if (devs[i].fd >= 0 && devs[i].pending && devs[i].ufd >= 0) clone_publish(&devs[i]);
        if (r < 0) { if (errno == EINTR) continue; break; }
        for (int j = 0; j < n; j++) {
            if (!p[j].revents) continue;
            if (idx[j] < 0) {
                char buf[4096]; ssize_t len;
                while ((len = read(in, buf, sizeof buf)) > 0) {
                    for (char *q = buf; q < buf + len;) {
                        struct inotify_event *ie = (struct inotify_event *)q;
                        if (ie->len) { usleep(150000); try_add(ie->name); }
                        q += sizeof *ie + ie->len;
                    }
                }
            } else if (p[j].revents & (POLLERR | POLLHUP | POLLNVAL)) dev_close(&devs[idx[j]], "hangup");
            else handle(&devs[idx[j]]);
        }
    }
    for (int i = 0; i < MAXDEV; i++) if (devs[i].fd >= 0) dev_close(&devs[i], "quit");
    ioctl(btkeys, UI_DEV_DESTROY);
    if (statefile) unlink(statefile);
    lg("quit");
    return 0;
}
