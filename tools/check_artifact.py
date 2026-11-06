#!/usr/bin/env python3
"""Read-only post-build checks for an HTFG Clean Kernel artifact.

Usage:
  python tools/check_artifact.py <artifact.zip> \
      --boot <merged boot-new.img> \
      --stock-boot <stock boot.img>

The script verifies the artifact zip, the Image embedded config/kheaders,
the AnyKernel3 device guard, and (optionally) that the merged boot image
contains exactly the same kernel Image and the stock ramdisk/header.

Exit code 0 = all checks passed; 1 = at least one failure.
Console messages are ASCII-only on purpose (Windows consoles).
"""

import argparse
import gzip
import hashlib
import io
import lzma
import re
import struct
import sys
import tarfile
import zipfile

DEFAULT_RELEASE = "5.10.236-android12-9-o-g38e2c85bc7af"
DEFAULT_BUILD_TIME = "Mon Jan 12 09:35:58 UTC 2026"
EXPECTED_COMPILER = "Android (7284624, based on r416183b) clang version 12.0.5"

STRONG_MARKERS = re.compile(
    rb"kernelsu|bakasu|ksu_htfg|ksu_susfs|htfg_prctl|config_ksu|config_kpm|config_susfs",
    re.I,
)
KHEADERS_MARKERS = re.compile(
    rb"kernelsu|bakasu|susfs|ksu_htfg|ksu_susfs|config_ksu|config_kpm|config_susfs|ksu_"
    rb"|(?<![a-z0-9_])ksu(?![a-z0-9_])|(?<![a-z0-9_])kpm(?![a-z0-9_])",
    re.I,
)
FORBIDDEN_CONFIG = re.compile(
    rb"^(CONFIG_HTFG|CONFIG_KSU|CONFIG_SUSFS|CONFIG_KPM|CONFIG_BBG)", re.M
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def align_page(size, page=4096):
    return (size + page - 1) // page * page


class Report:
    def __init__(self):
        self.failures = 0
        self.warnings = 0

    def ok(self, msg):
        print("OK: " + msg)

    def warn(self, msg):
        print("WARN: " + msg)
        self.warnings += 1

    def fail(self, msg):
        print("FAIL: " + msg)
        self.failures += 1

    def printable(self, data, limit=20):
        lines = data.splitlines()
        for line in lines[:limit]:
            print("  " + line.decode("latin1", "replace")[:200])


def read_pin(path):
    pins = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                pins[key.strip()] = value.strip()
    except OSError as exc:
        return None, str(exc)
    return pins, None


def check_zip(z, r):
    bad = z.testzip()
    if bad is not None:
        r.fail("zip integrity: first bad member is %s" % bad)
        return False
    r.ok("zip integrity")

    names = set(z.namelist())
    missing = [n for n in ("Image", "anykernel.sh", "htfg-build-info.txt") if n not in names]
    if missing:
        r.fail("missing required member(s): %s" % ", ".join(missing))
        return False
    r.ok("required members present")

    # AnyKernel3 template tools.  They are packaging helpers, not part of
    # the kernel Image; the Violet merge path only uses Image.
    for name in ("tools/magiskboot", "tools/magiskpolicy"):
        if name in names:
            r.ok("AK3 tool present: %s" % name)
        else:
            r.warn("AK3 tool missing: %s (zip may not be AK3-flashable)" % name)
    return True


def check_build_info(z, img, pin, args, r):
    try:
        text = z.read("htfg-build-info.txt").decode("utf-8", "replace")
    except KeyError:
        r.fail("cannot read htfg-build-info.txt")
        return False, False

    info = {}
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            info[key.strip()] = value.strip()

    for key in ("build_mode", "kernel_source_sha", "kernel_release", "image_sha256", "build_time"):
        if key not in info:
            r.fail("build-info missing %s" % key)

    stock_mode = info.get("build_mode") == "stock"
    if info.get("build_mode") == "stock":
        r.ok("build_mode=stock")
    else:
        r.warn("build_mode=%r (not stock; exact stock checks are relaxed)" % info.get("build_mode"))

    if info.get("kernel_source_sha") == args.pin_sha:
        r.ok("kernel_source_sha matches pinned source")
    else:
        r.fail(
            "kernel_source_sha=%r does not match pin %r"
            % (info.get("kernel_source_sha"), args.pin_sha)
        )

    if info.get("kernel_release") == args.release:
        r.ok("kernel_release=%s" % args.release)
    else:
        r.fail("kernel_release=%r, expected %r" % (info.get("kernel_release"), args.release))

    if info.get("build_time") == args.build_time:
        r.ok("build_time matches stock")
    else:
        r.fail("build_time=%r, expected %r" % (info.get("build_time"), args.build_time))

    actual = sha256(img)
    if info.get("image_sha256") == actual:
        r.ok("Image sha256 matches build-info")
    else:
        r.fail(
            "Image sha256=%s does not match build-info %r"
            % (actual, info.get("image_sha256"))
        )
    return True, stock_mode


def check_anykernel(z, r):
    try:
        text = z.read("anykernel.sh").decode("utf-8", "replace")
    except KeyError:
        r.fail("cannot read anykernel.sh")
        return
    lines = [line.strip() for line in text.splitlines()]
    for expected in ("do.devicecheck=1", "device.name1=OP5911", "device.name2=PGZ110"):
        if expected in lines:
            r.ok("anykernel: %s" % expected)
        else:
            r.fail("anykernel missing %s" % expected)
    extra = [line for line in lines if re.match(r"device\.name[3-9]=", line)]
    if extra:
        r.fail("anykernel has extra device names: %s" % ", ".join(extra))
    else:
        r.ok("anykernel has no device.name3..9")
    for expected in ("do.modules=0", "do.systemless=0"):
        if expected in lines:
            r.ok("anykernel: %s" % expected)
        else:
            r.warn("anykernel missing %s" % expected)


def check_image_strings(img, args, r):
    runs = re.findall(rb"[ -~]{4,}", img)
    blob = b"\n".join(runs)
    banner = ("Linux version %s (build-user@build-host)" % args.release).encode()
    date = ("#1 SMP PREEMPT %s" % args.build_time).encode()

    for label, needle in (
        ("stock banner", banner),
        ("stock compiler string", EXPECTED_COMPILER.encode()),
        ("stock build date", date),
    ):
        if needle in blob:
            r.ok("Image contains %s" % label)
        else:
            r.fail("Image missing %s" % label)

    if b"runner@" in blob:
        r.fail("Image contains runner@ (build host leaked)")
    else:
        r.ok("Image has no runner@")

    hits = [line for line in runs if STRONG_MARKERS.search(line)]
    if hits:
        r.fail("Image contains KSU/SUSFS/KPM/BakaSU strong markers")
        for line in hits[:20]:
            print("  " + line.decode("latin1", "replace")[:200])
    else:
        r.ok("Image has no KSU/SUSFS/KPM/BakaSU strong markers")

    for marker in (b"CONFIG_HTFG", b"CONFIG_KSU", b"CONFIG_SUSFS", b"CONFIG_KPM", b"CONFIG_BBG"):
        if marker in blob:
            r.fail("Image strings contain %s" % marker.decode())
        else:
            r.ok("Image strings do not contain %s" % marker.decode())


def check_ikconfig(img, args, stock_mode, r):
    start = img.find(b"IKCFG_ST")
    if start < 0:
        r.fail("Image has no IKCFG_ST")
        return
    end = img.find(b"IKCFG_ED", start + 8)
    if end < 0:
        r.fail("Image has no IKCFG_ED")
        return
    try:
        cfg = gzip.decompress(img[start + 8:end])
    except (OSError, EOFError) as exc:
        r.fail("Image IKCONFIG gzip decompress failed: %s" % exc)
        return

    r.ok(
        "Image embedded config: %d bytes, %d lines, sha256=%s"
        % (len(cfg), len(cfg.splitlines()), sha256(cfg))
    )

    try:
        with open(args.baseline_config, "rb") as fh:
            baseline = gzip.decompress(fh.read())
    except OSError as exc:
        r.fail("cannot read baseline config %s: %s" % (args.baseline_config, exc))
        baseline = None

    if baseline is not None:
        if stock_mode:
            if cfg == baseline:
                r.ok("Image embedded config is byte-identical to the stock baseline")
            else:
                r.fail("Image embedded config differs from the stock baseline")
                import difflib
                diff = list(
                    difflib.unified_diff(
                        baseline.decode("utf-8", "replace").splitlines(),
                        cfg.decode("utf-8", "replace").splitlines(),
                        fromfile="stock",
                        tofile="image",
                        n=0,
                    )
                )
                for line in diff[:25]:
                    print("  " + line)
        else:
            r.warn("fast mode: skipped exact stock config comparison")

    bad = [(i + 1, line) for i, line in enumerate(cfg.splitlines()) if FORBIDDEN_CONFIG.match(line)]
    if bad:
        r.fail("embedded config contains forbidden root/HTFG lines")
        for lineno, line in bad[:20]:
            print("  %d: %s" % (lineno, line.decode("latin1", "replace")))
    else:
        r.ok("embedded config has no HTFG/KSU/SUSFS/KPM/BBG lines")

    oplus = cfg.count(b"CONFIG_MTK_OPLUS_THERMAL")
    realme = cfg.count(b"CONFIG_MTK_REALME_THERMAL")
    if stock_mode:
        if oplus == 0 and realme == 1:
            r.ok("embedded config reports the stock thermal symbol set (OPLUS=0, REALME=1)")
        else:
            r.fail("embedded config thermal symbols: OPLUS=%d, REALME=%d" % (oplus, realme))
    else:
        r.warn("embedded config thermal symbols: OPLUS=%d, REALME=%d" % (oplus, realme))


def check_kheaders(img, args, stock_mode, r):
    end = img.find(b"IKCFG_ED")
    off = img.find(b"\xfd7zXZ\x00", end)
    if off < 0:
        r.fail("Image has no kheaders xz stream after IKCFG")
        return
    dec = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
    try:
        tar = dec.decompress(img[off:])
    except (lzma.LZMAError, EOFError) as exc:
        r.fail("kheaders xz decompress failed: %s" % exc)
        return
    if not dec.eof:
        r.fail("kheaders xz stream did not reach EOF")
        return
    consumed = len(img) - off - len(dec.unused_data)
    r.ok("kheaders xz: %d compressed bytes, %d tar bytes" % (consumed, len(tar)))

    try:
        tf = tarfile.open(fileobj=io.BytesIO(tar), mode="r:")
        names = tf.getnames()
    except (tarfile.TarError, OSError) as exc:
        r.fail("kheaders tar parse failed: %s" % exc)
        return

    bad_names = [name for name in names if "htfg" in name.lower()]
    if bad_names:
        r.fail("kheaders has HTFG member name(s): %s" % ", ".join(bad_names[:10]))
    else:
        r.ok("kheaders has %d members and no HTFG member name" % len(names))

    if b"CONFIG_HTFG" in tar:
        r.fail("kheaders content contains CONFIG_HTFG")
    else:
        r.ok("kheaders content has no CONFIG_HTFG")

    hits = list(KHEADERS_MARKERS.finditer(tar))
    if hits:
        r.fail("kheaders content contains root-scheme markers")
        for hit in hits[:20]:
            lo = max(0, hit.start() - 40)
            hi = min(len(tar), hit.end() + 40)
            print("  " + tar[lo:hi].decode("latin1", "replace").replace("\n", "\\n")[:200])
    else:
        r.ok("kheaders content has no root-scheme markers")

    oplus = tar.count(b"CONFIG_MTK_OPLUS_THERMAL")
    realme = tar.count(b"CONFIG_MTK_REALME_THERMAL")
    if stock_mode:
        if oplus == 0 and realme == 1:
            r.ok("kheaders reports the stock thermal symbol set (OPLUS=0, REALME=1)")
        else:
            r.fail("kheaders thermal symbols: OPLUS=%d, REALME=%d" % (oplus, realme))
    else:
        r.warn("kheaders thermal symbols: OPLUS=%d, REALME=%d" % (oplus, realme))


def parse_boot(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 4096 + 8:
        raise ValueError("file too small")
    if data[:8] != b"ANDROID!":
        raise ValueError("bad ANDROID! magic")
    kernel_size, ramdisk_size, os_version, header_size = struct.unpack_from("<IIII", data, 8)
    header_version = struct.unpack_from("<I", data, 40)[0]
    if header_version != 4 or header_size != 1584:
        raise ValueError("expected Android boot header v4/1584, got v%d/%d" % (header_version, header_size))
    header = data[:header_size]
    kernel = data[4096:4096 + kernel_size]
    if len(kernel) != kernel_size:
        raise ValueError("truncated kernel payload")
    if kernel[:2] != b"\x1f\x8b":
        raise ValueError("kernel payload is not gzip")
    raw = gzip.decompress(kernel)
    ramdisk_off = 4096 + align_page(kernel_size)
    ramdisk = data[ramdisk_off:ramdisk_off + ramdisk_size]
    if len(ramdisk) != ramdisk_size:
        raise ValueError("truncated ramdisk payload")
    return {
        "path": path,
        "size": len(data),
        "kernel_size": kernel_size,
        "ramdisk_size": ramdisk_size,
        "os_version": os_version,
        "header_size": header_size,
        "header_version": header_version,
        "header": header,
        "kernel": kernel,
        "raw": raw,
        "ramdisk": ramdisk,
    }


def check_boot(path, stock_path, image_sha, r):
    try:
        boot = parse_boot(path)
    except (OSError, ValueError, EOFError, gzip.BadGzipFile) as exc:
        r.fail("cannot parse boot image %s: %s" % (path, exc))
        return
    r.ok(
        "boot: %d bytes, header v%d/%d, kernel=%d, ramdisk=%d"
        % (
            boot["size"],
            boot["header_version"],
            boot["header_size"],
            boot["kernel_size"],
            boot["ramdisk_size"],
        )
    )
    if boot["size"] != 64 * 1024 * 1024:
        r.warn("boot image is not 64 MiB (%d bytes)" % boot["size"])

    raw_sha = sha256(boot["raw"])
    if raw_sha == image_sha:
        r.ok("boot kernel decompresses to the artifact Image (sha256=%s)" % raw_sha)
    else:
        r.fail("boot kernel sha256=%s does not match artifact Image %s" % (raw_sha, image_sha))

    if not stock_path:
        return
    try:
        stock = parse_boot(stock_path)
    except (OSError, ValueError, EOFError, gzip.BadGzipFile) as exc:
        r.fail("cannot parse stock boot image %s: %s" % (stock_path, exc))
        return

    masked_boot = boot["header"][:8] + b"\x00" * 4 + boot["header"][12:]
    masked_stock = stock["header"][:8] + b"\x00" * 4 + stock["header"][12:]
    if masked_boot == masked_stock:
        r.ok("boot header is identical to stock except kernel_size")
    else:
        diffs = [i for i in range(min(len(masked_boot), len(masked_stock))) if masked_boot[i] != masked_stock[i]]
        r.fail("boot header differs from stock outside kernel_size at offsets: %s" % diffs[:20])

    if boot["ramdisk"] == stock["ramdisk"]:
        r.ok("boot ramdisk is byte-identical to stock")
    else:
        r.fail("boot ramdisk differs from stock (new sha256=%s)" % sha256(boot["ramdisk"]))

    if boot["os_version"] != stock["os_version"]:
        r.fail("boot os_version differs from stock")
    else:
        r.ok("boot os_version matches stock")

    print(
        "  kernel size: stock=%d new=%d; ramdisk size: stock=%d new=%d"
        % (stock["kernel_size"], boot["kernel_size"], stock["ramdisk_size"], boot["ramdisk_size"])
    )


def main():
    ap = argparse.ArgumentParser(description="Read-only checks for an HTFG Clean Kernel artifact.")
    ap.add_argument("artifact", help="AnyKernel3 zip produced by the workflow")
    ap.add_argument("--boot", help="merged boot-new.img (optional)")
    ap.add_argument("--stock-boot", help="stock boot.img for header/ramdisk comparison")
    ap.add_argument("--baseline-config", default="baseline/stock.config.gz")
    ap.add_argument("--pinned-sources", default="manifest/pinned-sources.txt")
    ap.add_argument("--release", default=DEFAULT_RELEASE)
    ap.add_argument("--build-time", default=DEFAULT_BUILD_TIME)
    args = ap.parse_args()

    r = Report()
    pins, pin_err = read_pin(args.pinned_sources)
    if pins is None:
        r.fail("cannot read pinned sources %s: %s" % (args.pinned_sources, pin_err))
        args.pin_sha = None
    else:
        args.pin_sha = pins.get("KERNEL_SHA")
        if not args.pin_sha:
            r.fail("pinned sources has no KERNEL_SHA")

    try:
        z = zipfile.ZipFile(args.artifact)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print("FAIL: cannot open artifact %s: %s" % (args.artifact, exc))
        return 1

    with z:
        if not check_zip(z, r):
            print("RESULT: FAIL (%d failure(s))" % r.failures)
            return 1
        try:
            img = z.read("Image")
        except KeyError:
            r.fail("cannot read Image")
            print("RESULT: FAIL (%d failure(s))" % r.failures)
            return 1
        r.ok("Image: %d bytes, sha256=%s" % (len(img), sha256(img)))

        info_ok, stock_mode = check_build_info(z, img, pins, args, r)
        if not info_ok:
            print("RESULT: FAIL (%d failure(s))" % r.failures)
            return 1

        check_anykernel(z, r)
        check_image_strings(img, args, r)
        check_ikconfig(img, args, stock_mode, r)
        check_kheaders(img, args, stock_mode, r)

        if args.boot:
            check_boot(args.boot, args.stock_boot, sha256(img), r)
        else:
            r.warn("no --boot image supplied; skipped merged boot checks")

    if r.failures:
        print("RESULT: FAIL (%d failure(s), %d warning(s))" % (r.failures, r.warnings))
        return 1
    print("RESULT: PASS (%d warning(s))" % r.warnings)
    return 0


if __name__ == "__main__":
    sys.exit(main())
