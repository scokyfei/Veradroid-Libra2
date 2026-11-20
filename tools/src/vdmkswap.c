// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * vdmkswap <block-device>
 * Write a Linux v1 swap header ("SWAPSPACE2") onto a block device (e.g. /dev/zram0)
 * for embedded Linux hosts like Kobo whose BusyBox ships swapon/swapoff without mkswap.
 */
#include <fcntl.h>
#include <linux/fs.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: %s <block-device>\n", argv[0]);
        return 2;
    }
    int fd = open(argv[1], O_WRONLY | O_CLOEXEC);
    if (fd < 0) { perror("vdmkswap: open"); return 3; }

    uint64_t bytes = 0;
    if (ioctl(fd, BLKGETSIZE64, &bytes) < 0) { perror("vdmkswap: BLKGETSIZE64"); close(fd); return 4; }

    long pg = sysconf(_SC_PAGESIZE);
    if (pg < 4096 || pg > 65536) { fprintf(stderr, "vdmkswap: unsupported page size %ld\n", pg); close(fd); return 5; }

    uint64_t pages = bytes / (uint64_t)pg;
    if (pages < 10) { fprintf(stderr, "vdmkswap: device too small\n"); close(fd); return 5; }

    unsigned char hdr[65536];
    memset(hdr, 0, (size_t)pg);
    uint32_t meta[3] = { 1u, (uint32_t)(pages - 1u), 0u };
    memcpy(hdr + 1024, meta, sizeof(meta));
    memcpy(hdr + (size_t)pg - 10, "SWAPSPACE2", 10);

    if (pwrite(fd, hdr, (size_t)pg, 0) != pg || fsync(fd) < 0) {
        perror("vdmkswap: write");
        close(fd);
        return 6;
    }
    close(fd);
    return 0;
}
