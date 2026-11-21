#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
Build ethernet-service-wifi.jar from VeraDroid's hostnet ethernet-service.odex / classes.dex:
  1. NetworkInfo type: ConnectivityManager.TYPE_ETHERNET (9) -> ConnectivityManager.TYPE_WIFI (1)
  2. NetworkCapabilities transport: add NetworkCapabilities.TRANSPORT_WIFI (1) alongside TRANSPORT_ETHERNET (3)
So apps on shared hostnet wlan0 (e.g. WeRead offline book download) detect Wi-Fi as connected.
"""
import hashlib
import struct
import sys
import zipfile
import zlib


def extract_dex(raw: bytes) -> bytearray:
    idx = raw.find(b"dex\n037\x00")
    if idx < 0:
        idx = raw.find(b"dex\n035\x00")
    if idx < 0:
        raise ValueError("No embedded DEX found")
    size = struct.unpack_from("<I", raw, idx + 32)[0]
    return bytearray(raw[idx : idx + size])


def patch_dex(d: bytearray) -> bytearray:
    # 1. TYPE_ETHERNET (9) -> TYPE_WIFI (1) in <init>, stopTrackingInterface, stop
    for off in (0x246A, 0x2986, 0x2F82):
        if d[off : off + 4] == bytes.fromhex("13030900"):
            d[off : off + 4] = bytes.fromhex("13030100")
        elif d[off : off + 4] != bytes.fromhex("13030100"):
            raise ValueError(f"Unexpected bytes at 0x{off:x}: {d[off:off+4].hex()}")

    # 2. Replace redundant addCapability(13) in initNetworkCapabilities with addTransportType(1 = TRANSPORT_WIFI)
    off = 0x24D6
    if d[off : off + 10] == bytes.fromhex("13010d006e201f001000"):
        d[off : off + 10] = bytes.fromhex("130101006e2020001000")
    elif d[off : off + 10] != bytes.fromhex("130101006e2020001000"):
        raise ValueError(f"Unexpected bytes at 0x{off:x}: {d[off:off+10].hex()}")

    # 3. Recompute DEX SHA-1 signature and Adler32 checksum
    d[12:32] = hashlib.sha1(d[32:]).digest()
    chk = zlib.adler32(d[12:]) & 0xFFFFFFFF
    struct.pack_into("<I", d, 8, chk)
    return d


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.odex|classes.dex> <output.jar>", file=sys.stderr)
        sys.exit(1)
    raw = open(sys.argv[1], "rb").read()
    dex = patch_dex(extract_dex(raw))
    with zipfile.ZipFile(sys.argv[2], "w", compression=zipfile.ZIP_STORED) as zf:
        zf.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\nCreated-By: 1.8.0 (VeraDroid Kobo)\r\n\r\n")
        zf.writestr("classes.dex", bytes(dex))


if __name__ == "__main__":
    main()
