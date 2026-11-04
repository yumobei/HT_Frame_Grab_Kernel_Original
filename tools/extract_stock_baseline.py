#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Read a stock Android boot image and print its kernel banner and key config.

This tool is intentionally read-only: it never writes files.  It is used to
regenerate the checked-in baseline files when a new stock boot image is
available:

    python tools/extract_stock_baseline.py 原厂镜像/boot.img

The boot image is expected to be an Android bootimg v3/v4 with a gzip kernel
(the OnePlus stock image is).  The embedded config is the standard
IKCFG_ST ... IKCFG_ED gzip block inside the decompressed kernel.

Console output is ASCII/English on purpose.
"""

import argparse
import gzip
import io
import struct
import sys
import zlib

BOOT_MAGIC = b"ANDROID!"
IKCFG_ST = b"IKCFG_ST"
IKCFG_ED = b"IKCFG_ED"


def parse_boot_header(data):
    if len(data) < 44 or data[:8] != BOOT_MAGIC:
        raise ValueError("not an Android boot image (magic ANDROID! missing)")
    kernel_size, ramdisk_size = struct.unpack_from("<II", data, 8)
    os_version, header_size, _reserved = struct.unpack_from("<III", data, 16)
    header_version = struct.unpack_from("<I", data, 40)[0]
    page_size = 4096
    return {
        "kernel_size": kernel_size,
        "ramdisk_size": ramdisk_size,
        "os_version": os_version,
        "header_size": header_size,
        "header_version": header_version,
        "page_size": page_size,
    }


def kernel_bytes(data, header):
    # bootimg v2+ puts the kernel at one page offset.  v0/v1 use a smaller
    # header, but this device is v4; fail loudly rather than guess.
    if header["header_version"] < 2:
        raise ValueError("boot header v%d is not supported by this tool"
                         % header["header_version"])
    start = header["page_size"]
    end = start + header["kernel_size"]
    if end > len(data):
        raise ValueError("kernel_size exceeds boot image length")
    return data[start:end]


def decompress_kernel(raw):
    if raw[:2] != b"\x1f\x8b":
        raise ValueError("kernel is not gzip-compressed")
    return gzip.decompress(raw)


def extract_config(kernel):
    start = kernel.find(IKCFG_ST)
    if start < 0:
        raise ValueError("IKCFG_ST not found in kernel")
    end = kernel.find(IKCFG_ED, start + len(IKCFG_ST))
    if end < 0:
        raise ValueError("IKCFG_ED not found in kernel")
    payload = kernel[start + len(IKCFG_ST):end]
    # Find the gzip magic; normally it is immediately after IKCFG_ST, but the
    # stock image may pad the marker block.
    gz = payload.find(b"\x1f\x8b\x08")
    if gz < 0:
        raise ValueError("gzip config payload not found after IKCFG_ST")
    payload = payload[gz:]
    dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
    config = dec.decompress(payload)
    if not dec.eof:
        raise ValueError("config gzip stream is truncated")
    return config


def find_banner(kernel):
    idx = kernel.find(b"Linux version 5.10.236")
    if idx < 0:
        raise ValueError("Linux version banner not found")
    end = kernel.find(b"\0", idx)
    if end < 0:
        end = len(kernel)
    return kernel[idx:end]


def main():
    ap = argparse.ArgumentParser(description="Inspect a stock Android boot image")
    ap.add_argument("boot_img", help="path to boot.img")
    ap.add_argument("--full-config", action="store_true",
                    help="print the complete decoded config")
    ap.add_argument("--config-out", default=None,
                    help="optional path to write the decoded config (explicit opt-in)")
    args = ap.parse_args()

    with open(args.boot_img, "rb") as f:
        data = f.read()

    header = parse_boot_header(data)
    kernel = decompress_kernel(kernel_bytes(data, header))
    banner = find_banner(kernel).decode("latin1")
    config = extract_config(kernel).decode("latin1")

    out = io.StringIO()
    out.write("boot image: %s\n" % args.boot_img)
    out.write("image size: %d bytes\n" % len(data))
    out.write("kernel: raw=%d decompressed=%d header_version=%d\n" % (
        header["kernel_size"], len(kernel), header["header_version"]))
    out.write("\nbanner:\n%s\n\n" % banner)

    keys = [
        "CONFIG_LOCALVERSION", "CONFIG_LOCALVERSION_AUTO",
        "CONFIG_IKCONFIG", "CONFIG_IKCONFIG_PROC", "CONFIG_IKHEADERS",
        "CONFIG_KALLSYMS", "CONFIG_KALLSYMS_ALL",
        "CONFIG_CRYPTO_SHA256", "CONFIG_MODVERSIONS", "CONFIG_MODULES",
        "CONFIG_INPUT", "CONFIG_LTO_CLANG", "CONFIG_LTO_CLANG_FULL",
        "CONFIG_LTO_CLANG_THIN", "CONFIG_TMPFS_XATTR",
        "CONFIG_TMPFS_POSIX_ACL", "CONFIG_STACKPROTECTOR_STRONG",
        "CONFIG_DEBUG_INFO_BTF", "CONFIG_KASAN", "CONFIG_KFENCE",
        "CONFIG_UBSAN", "CONFIG_CFI_CLANG", "CONFIG_SHADOW_CALL_STACK",
        "CONFIG_KSU", "CONFIG_KSU_SUSFS", "CONFIG_SUSFS", "CONFIG_KPM",
        "CONFIG_BBG", "CONFIG_HTFG", "CONFIG_HTFG_ALLOW_TOOL_UID",
    ]
    out.write("key config:\n")
    lines = config.splitlines()
    for key in keys:
        matched = [ln for ln in lines
                   if ln == key or ln.startswith(key + "=")
                   or ln.startswith("# " + key + " ")]
        if matched:
            for ln in matched:
                out.write("  %s\n" % ln)
        else:
            out.write("  %s: <absent>\n" % key)

    if args.full_config:
        out.write("\nfull config:\n")
        out.write(config)
        if not config.endswith("\n"):
            out.write("\n")

    sys.stdout.buffer.write(out.getvalue().encode("utf-8", "replace"))

    if args.config_out:
        # Explicit opt-in; the default path is read-only.
        with open(args.config_out, "wb") as f:
            f.write(config.encode("latin1"))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        sys.stderr.write("extract_stock_baseline: ERROR: %s\n" % exc)
        sys.exit(1)
