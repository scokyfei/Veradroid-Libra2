// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * vdsqueeze — Push cold anonymous memory (e.g. SIGSTOP'd KOReader/Nickel host
 * processes) into ZRAM once at VeraDroid startup on Kobo Libra 2 (Linux 4.1.15).
 *
 * Kobo's 4.1.15 kernel lacks memory cgroups and swaps anonymous pages only when
 * inactive file cache runs low, which otherwise happens right during the user's
 * first book open. Touching MB of temporary anonymous pages in 4 MB chunks with
 * swappiness=100 forces the kernel to reclaim the least-recently-used anonymous
 * pages into ZRAM upfront, then immediately returns the temporary memory on exit.
 * Stops early if MemAvailable < 24 MB and SwapFree < 8 MB.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>

static long read_meminfo_kb(const char *key)
{
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return -1;
    char line[128];
    long val = -1;
    size_t n = strlen(key);
    while (fgets(line, sizeof(line), f)) {
        if (!strncmp(line, key, n) && line[n] == ':') {
            val = atol(line + n + 1);
            break;
        }
    }
    fclose(f);
    return val;
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    long mb = atol(argv[1]);
    if (mb < 1 || mb > 256) return 2;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    long swap0 = read_meminfo_kb("SwapTotal") - read_meminfo_kb("SwapFree");
    long cached0 = read_meminfo_kb("Cached");
    size_t step = 4u << 20;
    long done = 0;

    for (long i = 0; i < mb; i += 4) {
        if (read_meminfo_kb("MemAvailable") < 24 * 1024 &&
            read_meminfo_kb("SwapFree") < 8 * 1024)
            break;
        char *p = (char *)mmap(NULL, step, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) break;
        for (size_t o = 0; o < step; o += 4096)
            p[o] = (char)((o >> 12) | 1);
        done += 4;
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    long swap1 = read_meminfo_kb("SwapTotal") - read_meminfo_kb("SwapFree");
    double sec = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("vdsqueeze: touched=%ldMB swap=%ld->%ldkB cached=%ld->%ldkB (%.2fs)\n",
           done, swap0, swap1, cached0, read_meminfo_kb("Cached"), sec);
    return 0;
}
