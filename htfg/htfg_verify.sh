#!/usr/bin/env bash
# ============================================================================
# HTFG clean-kernel verification
#
# Run after the kernel build and before packaging AnyKernel3:
#
#   HTFG_OUT_DIR=kernel_workspace/kernel_platform/out \
#   BUILD_MODE=stock \
#   bash "$RUNNER_TEMP/htfg/htfg_verify.sh"
#
# Environment:
#   HTFG_OUT_DIR        optional; auto-detected from out/.config
#   HTFG_SEARCH_ROOT    optional; default kernel_workspace/kernel_platform
#   HTFG_EXPECT_RELEASE default 5.10.236-android12-9-o-g38e2c85bc7af
#   BUILD_MODE          stock (default) or fast (explicit fallback)
#   HTFG_ALLOW_TOOL_UID 0 (default, production) or 1 (debug)
#   HTFG_FAKE_CONFIG    1 (default) or 0
#   HTFG_STOCK_CONFIG   optional baseline/stock.config.gz; if set, the built
#                       .config must match it except for CONFIG_HTFG* lines
#
# Green here means: HTFG is compiled in, the stock banner/config is preserved,
# and no KSU/SUSFS/KPM/BBG or HTFG header leak was found.  It does not prove
# vendor-module ABI/CRC compatibility; that is tested on the device.
#
# Console messages are ASCII/English on purpose (Windows consoles).
# ============================================================================
set -euo pipefail

EXPECT_RELEASE="${HTFG_EXPECT_RELEASE:-5.10.236-android12-9-o-g38e2c85bc7af}"
EXPECT_BANNER_PREFIX="Linux version ${EXPECT_RELEASE} (build-user@build-host)"
EXPECT_COMPILER="Android (7284624, based on r416183b) clang version 12.0.5"
EXPECT_DATE="#1 SMP PREEMPT Mon Jan 12 09:35:58 UTC 2026"
BUILD_MODE="${BUILD_MODE:-stock}"
ALLOW_TOOL_UID="${HTFG_ALLOW_TOOL_UID:-0}"
FAKE_CONFIG="${HTFG_FAKE_CONFIG:-1}"
STOCK_CONFIG="${HTFG_STOCK_CONFIG:-}"
SEARCH_ROOT="${HTFG_SEARCH_ROOT:-kernel_workspace/kernel_platform}"

die() {
    echo "HTFG verify: ERROR: $*" >&2
    exit 1
}

warn() {
    echo "HTFG verify: WARN: $*"
}

find_first() {
    # Prune large/irrelevant trees so the repeated lookups stay fast.
    find "$SEARCH_ROOT" -maxdepth 12 \
        \( -name .git -o -path '*/prebuilts*' -o -path '*/.repo*' \) -prune -o \
        "$@" -print 2>/dev/null | head -n 1 || true
}

# python3 is used to extract the IKCONFIG blob embedded in Image.
PYTHON="${PYTHON:-}"
if [ -z "$PYTHON" ]; then
    if command -v python3 >/dev/null 2>&1; then
        PYTHON=python3
    elif command -v python >/dev/null 2>&1; then
        PYTHON=python
    fi
fi
[ -n "$PYTHON" ] || die "python3/python not found (needed for the Image IKCONFIG check)"

decompress_config() {  # $1=source (gzip or plain) $2=destination
    if gzip -t "$1" 2>/dev/null; then
        gzip -dc "$1" > "$2"
    else
        cp "$1" "$2"
    fi
}

# ---- locate the output directory -----------------------------------------
OUT="${HTFG_OUT_DIR:-}"
if [ -z "$OUT" ]; then
    __cfg="$(find_first -name .config)"
    if [ -n "$__cfg" ]; then
        OUT="$(dirname "$__cfg")"
    fi
fi
[ -n "$OUT" ] || die "output directory not found; set HTFG_OUT_DIR"

CFG="$OUT/.config"
[ -f "$CFG" ] || CFG="$(find_first -name .config)"
[ -n "$CFG" ] && [ -f "$CFG" ] || die ".config not found under $OUT"

SMAP="$OUT/System.map"
[ -f "$SMAP" ] || SMAP="$(find_first -name System.map)"
VMLINUX="$OUT/vmlinux"
[ -f "$VMLINUX" ] || VMLINUX="$(find_first -name vmlinux)"
IMG="$OUT/arch/arm64/boot/Image"
[ -f "$IMG" ] || IMG="$(find_first -name Image)"
UTS="$OUT/include/generated/utsrelease.h"
[ -f "$UTS" ] || UTS="$(find_first -name utsrelease.h)"
OBJ="$OUT/drivers/htfg/htfg.o"
[ -f "$OBJ" ] || OBJ="$(find_first -path '*/drivers/htfg/htfg.o')"
MB="$OUT/modules.builtin"
[ -f "$MB" ] || MB="$(find_first -name modules.builtin)"
KH="$OUT/kernel/kheaders_data.tar.xz"
[ -f "$KH" ] || KH="$(find_first -name kheaders_data.tar.xz)"
[ -f "$KH" ] || KH="$(find_first -name kheaders.tar.xz)"

echo "HTFG verify: OUT=$OUT"
echo "HTFG verify: CFG=$CFG"
echo "HTFG verify: IMG=${IMG:-<not found>}"
echo "HTFG verify: kernel source sha = ${KERNEL_SRC_SHA:-unknown}"

[ -n "$IMG" ] && [ -f "$IMG" ] || die "Image not found under $OUT"

# ---- stock .config checks ------------------------------------------------
need_y() {
    grep -qx "CONFIG_$1=y" "$CFG" || die "config: CONFIG_$1=y required"
}

need_not_y() {
    if grep -qx "CONFIG_$1=y" "$CFG"; then
        die "config: CONFIG_$1=y must not be set"
    fi
}

need_y HTFG
need_y INPUT
need_y CRYPTO_SHA256
need_y IKCONFIG
need_y IKCONFIG_PROC
need_y MODULES
need_y MODVERSIONS
need_y STACKPROTECTOR_STRONG

if [ "$ALLOW_TOOL_UID" = "1" ]; then
    need_y HTFG_ALLOW_TOOL_UID
else
    need_not_y HTFG_ALLOW_TOOL_UID
fi

need_not_y KSU
need_not_y KPM
need_not_y BBG
if grep -qE '^CONFIG_(KSU|SUSFS|KPM)' "$CFG"; then
    die "config still contains KSU/SUSFS/KPM options"
fi

# Stock LTO / TMPFS fidelity.  fast mode is an explicit fallback and may
# differ; it must still be reported, never silently accepted.
if ! grep -qx 'CONFIG_LTO_CLANG_FULL=y' "$CFG"; then
    if [ "$BUILD_MODE" = "fast" ]; then
        warn "CONFIG_LTO_CLANG_FULL is not y (fast fallback; differs from stock)"
    else
        die "config: CONFIG_LTO_CLANG_FULL=y required (stock)"
    fi
fi
if grep -qx 'CONFIG_LTO_CLANG_THIN=y' "$CFG"; then
    if [ "$BUILD_MODE" = "fast" ]; then
        warn "CONFIG_LTO_CLANG_THIN=y (fast fallback; differs from stock)"
    else
        die "config: CONFIG_LTO_CLANG_THIN=y is not the stock LTO mode"
    fi
fi
if grep -qx 'CONFIG_TMPFS_XATTR=y' "$CFG" || grep -qx 'CONFIG_TMPFS_POSIX_ACL=y' "$CFG"; then
    if [ "$BUILD_MODE" = "fast" ]; then
        warn "TMPFS_XATTR/POSIX_ACL=y (fast fallback; differs from stock)"
    else
        die "config: TMPFS_XATTR/POSIX_ACL must not be y (stock)"
    fi
fi

grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$CFG" && \
    die "config: CONFIG_DEBUG_INFO_BTF=y (stock has BTF disabled)"

grep -qF "$EXPECT_COMPILER" "$CFG" || \
    die "config: compiler string does not match stock ($EXPECT_COMPILER)"

if ! grep -qx 'CONFIG_IKHEADERS=y' "$CFG"; then
    warn "CONFIG_IKHEADERS is not y; kheaders leak check will be limited"
fi
if ! grep -qx 'CONFIG_KALLSYMS_ALL=y' "$CFG"; then
    warn "CONFIG_KALLSYMS_ALL is not y; stock has it enabled"
fi
if ! grep -qx 'CONFIG_KASAN=y' "$CFG"; then
    warn "CONFIG_KASAN is not y; build differs from stock"
fi
if ! grep -qx 'CONFIG_CFI_CLANG=y' "$CFG"; then
    warn "CONFIG_CFI_CLANG is not y; build differs from stock"
fi
if ! grep -qx 'CONFIG_STACKPROTECTOR_STRONG=y' "$CFG"; then
    die "config: CONFIG_STACKPROTECTOR_STRONG=y required"
fi

# ---- fake /proc/config.gz ------------------------------------------------
verify_fake_config() {
    local cfgz cfgd tmp tmp_stock linecnt
    local bad_re
    bad_re='^(CONFIG_KSU|# CONFIG_KSU|CONFIG_KSU_SUSFS|# CONFIG_KSU_SUSFS|CONFIG_SUSFS|# CONFIG_SUSFS|CONFIG_KPM|# CONFIG_KPM|CONFIG_BBG|# CONFIG_BBG|CONFIG_HTFG|# CONFIG_HTFG)'

    cfgz="$OUT/kernel/config_data.gz"
    [ -f "$cfgz" ] || cfgz="$(find_first -name config_data.gz)"
    cfgd=""
    [ -n "$cfgz" ] || cfgd="$(find_first -name config_data)"
    if [ -z "$cfgz" ] && [ -z "$cfgd" ]; then
        die "fake config: config_data.gz/config_data not found"
    fi

    tmp="$(mktemp)"
    if [ -n "$cfgz" ]; then
        gzip -t "$cfgz" 2>/dev/null || { rm -f "$tmp"; die "fake config: $cfgz is not valid gzip"; }
        gzip -dc "$cfgz" > "$tmp"
    else
        cat "$cfgd" > "$tmp"
    fi

    linecnt="$(wc -l < "$tmp")"
    if [ "$linecnt" -lt 100 ]; then
        rm -f "$tmp"
        die "fake config: only $linecnt lines (truncated/empty)"
    fi

    if grep -qE "$bad_re" "$tmp"; then
        echo "fake config still contains root/HTFG lines:" >&2
        grep -nE "$bad_re" "$tmp" | sed -n '1,20p' >&2 || true
        rm -f "$tmp"
        die "fake config is not clean"
    fi

    if ! grep -qx 'CONFIG_IKCONFIG=y' "$tmp" || ! grep -qx 'CONFIG_IKCONFIG_PROC=y' "$tmp"; then
        rm -f "$tmp"
        die "fake config missing IKCONFIG/IKCONFIG_PROC"
    fi

    if grep -q 'CONFIG_NETFILTER_XT_TARGET_CHECKSUM' "$CFG" && \
       ! grep -q 'CONFIG_NETFILTER_XT_TARGET_CHECKSUM' "$tmp"; then
        rm -f "$tmp"
        die "fake config over-deleted CHECKSUM (bare HTFG/KSU pattern?)"
    fi

    # The reported blob must be byte-identical to the stock one (stock mode
    # only; fast mode has a different .config and skips this).
    if [ "$BUILD_MODE" = "stock" ]; then
        if [ -z "$STOCK_CONFIG" ]; then
            warn "HTFG_STOCK_CONFIG not set; skipped exact fake config comparison"
        elif [ ! -f "$STOCK_CONFIG" ]; then
            rm -f "$tmp"
            die "stock config baseline not found: $STOCK_CONFIG"
        else
            tmp_stock="$(mktemp)"
            decompress_config "$STOCK_CONFIG" "$tmp_stock"
            if ! cmp -s "$tmp_stock" "$tmp"; then
                echo "fake config differs from the stock baseline:" >&2
                diff -u "$tmp_stock" "$tmp" | sed -n '1,25p' >&2 || true
                rm -f "$tmp" "$tmp_stock"
                die "fake /proc/config.gz is not byte-identical to the stock baseline"
            fi
            rm -f "$tmp_stock"
            echo "OK: fake /proc/config.gz is byte-identical to the stock baseline"
        fi
    else
        echo "fast mode: skipped exact fake config comparison"
    fi

    rm -f "$tmp"
    echo "OK: fake /proc/config.gz is clean"
}

if [ "$FAKE_CONFIG" = "1" ]; then
    verify_fake_config
else
    warn "HTFG_FAKE_CONFIG=0; skipped /proc/config.gz check"
fi

# ---- config blob embedded in the final Image -----------------------------
verify_image_ikconfig() {
    local tmp tmp_stock
    tmp="$(mktemp)"
    if ! "$PYTHON" - "$IMG" "$tmp" <<'PY'
import gzip
import sys

data = open(sys.argv[1], "rb").read()
start = data.find(b"IKCFG_ST")
if start < 0:
    sys.exit("IKCFG_ST not found")
end = data.find(b"IKCFG_ED", start + 8)
if end < 0:
    sys.exit("IKCFG_ED not found")
try:
    blob = gzip.decompress(data[start + 8:end])
except Exception as exc:
    sys.exit("IKCFG gzip decompress failed: %s" % exc)
open(sys.argv[2], "wb").write(blob)
PY
    then
        rm -f "$tmp"
        die "cannot extract the embedded IKCONFIG from $IMG"
    fi

    if [ "$FAKE_CONFIG" != "1" ]; then
        warn "HTFG_FAKE_CONFIG=0; skipped Image IKCONFIG content check"
    elif [ "$BUILD_MODE" = "stock" ]; then
        if [ -z "$STOCK_CONFIG" ]; then
            warn "HTFG_STOCK_CONFIG not set; skipped exact Image config comparison"
        elif [ ! -f "$STOCK_CONFIG" ]; then
            rm -f "$tmp"
            die "stock config baseline not found: $STOCK_CONFIG"
        else
            tmp_stock="$(mktemp)"
            decompress_config "$STOCK_CONFIG" "$tmp_stock"
            if ! cmp -s "$tmp_stock" "$tmp"; then
                echo "Image embedded config differs from the stock baseline:" >&2
                diff -u "$tmp_stock" "$tmp" | sed -n '1,25p' >&2 || true
                rm -f "$tmp" "$tmp_stock"
                die "Image embedded IKCONFIG is not byte-identical to the stock baseline"
            fi
            rm -f "$tmp_stock"
            echo "OK: Image embedded IKCONFIG is byte-identical to the stock baseline"
        fi
    else
        if grep -q '^CONFIG_HTFG' "$tmp"; then
            rm -f "$tmp"
            die "Image embedded IKCONFIG still contains CONFIG_HTFG"
        fi
        echo "OK: Image embedded IKCONFIG has no CONFIG_HTFG (fast mode)"
    fi

    rm -f "$tmp"
}

verify_image_ikconfig

# ---- full config diff against the stock baseline -------------------------
check_config_diff() {
    local stock="$1" tmp_stock tmp_build diffout
    [ -n "$stock" ] || { warn "HTFG_STOCK_CONFIG not set; skipped full config diff"; return; }
    [ -f "$stock" ] || die "stock config baseline not found: $stock"

    tmp_stock="$(mktemp)"
    tmp_build="$(mktemp)"
    if gzip -t "$stock" 2>/dev/null; then
        gzip -dc "$stock" > "$tmp_stock"
    else
        cp "$stock" "$tmp_stock"
    fi
    sort "$CFG" > "$tmp_build"

    # Ignore only HTFG lines (the one intentional config delta).  Everything
    # else -- LTO mode, TMPFS, BTF, KSU/BBG, debug options -- must match stock.
    diffout="$(diff -u <(sort "$tmp_stock") "$tmp_build" \
        | grep -E '^[+-][^+-]' \
        | grep -vE '^[+-](# )?CONFIG_HTFG' || true)"

    rm -f "$tmp_stock" "$tmp_build"

    if [ -n "$diffout" ]; then
        # Known source drift: the stock image was built from the vendor tree
        # with CONFIG_MTK_REALME_THERMAL=m.  The public
        # oneplus/mt6895_v_15.0.0_ace_race branch renamed that driver to
        # CONFIG_MTK_OPLUS_THERMAL=m and does not publish the realme driver.
        # Allow exactly this pair; any other difference still fails.
        drift="$(printf '%s\n' "$diffout" \
            | grep -Fvx -e '+CONFIG_MTK_OPLUS_THERMAL=m' \
                        -e '-CONFIG_MTK_REALME_THERMAL=m' || true)"
        if [ -z "$drift" ] \
            && printf '%s\n' "$diffout" | grep -Fqx '+CONFIG_MTK_OPLUS_THERMAL=m' \
            && printf '%s\n' "$diffout" | grep -Fqx -- '-CONFIG_MTK_REALME_THERMAL=m'; then
            warn "known public-branch drift: MTK_OPLUS_THERMAL replaces the stock vendor tree's MTK_REALME_THERMAL"
        else
            echo "HTFG verify: unexpected config differences (stock vs build):" >&2
            printf '%s\n' "$diffout" | sed -n '1,80p' >&2
            die "built .config differs from the stock baseline beyond HTFG"
        fi
    fi
    echo "OK: .config matches stock except CONFIG_HTFG* and the documented thermal-name drift"
}

if [ "$BUILD_MODE" = "stock" ]; then
    check_config_diff "$STOCK_CONFIG"
else
    warn "fast mode: skipped full stock config diff (OPLUS fragments are not applied by direct make)"
fi

# ---- UTS release ---------------------------------------------------------
if [ -n "$UTS" ] && [ -f "$UTS" ]; then
    REL="$(sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' "$UTS" | head -n 1)"
else
    REL=""
fi
if [ -z "$REL" ]; then
    warn "utsrelease.h not found; cannot check UTS_RELEASE"
else
    [ "$REL" = "$EXPECT_RELEASE" ] || \
        die "UTS_RELEASE=$REL (expected $EXPECT_RELEASE)"
    case "$REL" in
        *+*|-dirty*) die "UTS_RELEASE contains + or -dirty: $REL" ;;
    esac
    echo "OK: UTS_RELEASE=$REL"
fi

# ---- symbols / artifacts ------------------------------------------------
if [ -n "$SMAP" ] && [ -f "$SMAP" ]; then
    grep -qE '[[:space:]]htfg_kernel_entry(\.|$)' "$SMAP" || \
        die "System.map has no htfg_kernel_entry"
    if grep -q 'ksu_' "$SMAP"; then
        die "System.map still contains ksu_ symbols"
    fi
    echo "OK: System.map has htfg_kernel_entry, no ksu_"
elif [ -n "$VMLINUX" ] && [ -f "$VMLINUX" ]; then
    nm "$VMLINUX" 2>/dev/null | grep -qE '[[:space:]]htfg_kernel_entry$' || \
        die "vmlinux has no htfg_kernel_entry"
    if nm "$VMLINUX" 2>/dev/null | grep -q 'ksu_'; then
        die "vmlinux still contains ksu_ symbols"
    fi
    echo "OK: vmlinux has htfg_kernel_entry, no ksu_"
elif [ -n "$OBJ" ] && [ -f "$OBJ" ]; then
    warn "no System.map/vmlinux; falling back to htfg.o existence"
else
    die "cannot find System.map/vmlinux/htfg.o"
fi

if [ -n "$OBJ" ] && [ -f "$OBJ" ]; then
    echo "OK: drivers/htfg/htfg.o exists"
fi

if [ -n "$MB" ] && [ -f "$MB" ]; then
    if grep -q 'htfg' "$MB"; then
        die "modules.builtin contains htfg (should be a built-in bool, not a module)"
    fi
    echo "OK: modules.builtin has no htfg"
fi

# ---- Image strings ------------------------------------------------------
STRINGS="$(strings -a "$IMG")"
echo "$STRINGS" | grep -F "$EXPECT_BANNER_PREFIX" >/dev/null || \
    die "Image banner missing: $EXPECT_BANNER_PREFIX"
echo "$STRINGS" | grep -F "$EXPECT_COMPILER" >/dev/null || \
    die "Image compiler string missing: $EXPECT_COMPILER"
echo "$STRINGS" | grep -F "$EXPECT_DATE" >/dev/null || \
    die "Image build date missing: $EXPECT_DATE"

if echo "$STRINGS" | grep -F 'runner@' >/dev/null; then
    die "Image contains runner@ (GitHub Actions build host leaked)"
fi
# Scan only distinctive markers in the raw Image.  The Image embeds gzip/xz
# blobs (config_data, kheaders) whose compressed bytes are random noise; a
# standalone three-letter "ksu"/"kpm" can appear there by chance.  Short-word
# checks belong on the decompressed content below, not on this stream.
# Do not use a bare "ksu" pattern either: CHECKSUM contains the substring "KSU".
hits="$(printf '%s\n' "$STRINGS" | grep -iE 'kernelsu|bakasu|ksu_htfg|ksu_susfs|htfg_prctl|config_ksu|config_kpm|config_susfs' || true)"
if [ -n "$hits" ]; then
    echo "Image string hits:" >&2
    printf '%s\n' "$hits" | sed -n '1,20p' >&2
    die "Image contains KSU/SUSFS/KPM/BakaSU strings"
fi
echo "OK: Image banner/compiler/date match stock; no runner@/KSU strings"

# ---- kheaders / BTF -----------------------------------------------------
if grep -qx 'CONFIG_IKHEADERS=y' "$CFG"; then
    if [ -n "$KH" ] && [ -f "$KH" ]; then
        # Decompress/list once into temp files.  Piping tar/xz into grep -q
        # under "set -o pipefail" can return SIGPIPE (141) when grep exits
        # early, which would silently turn a real hit into a pass.
        kh_list="$(mktemp)"
        if ! tar -tJf "$KH" > "$kh_list" 2>/dev/null; then
            rm -f "$kh_list"
            die "cannot list $KH"
        fi
        if grep -qi 'htfg' "$kh_list"; then
            rm -f "$kh_list"
            die "kheaders archive still has an HTFG member name"
        fi
        rm -f "$kh_list"

        kh_tmp="$(mktemp)"
        if ! xz -dc "$KH" > "$kh_tmp" 2>/dev/null; then
            rm -f "$kh_tmp"
            die "cannot decompress $KH"
        fi
        if grep -aq 'CONFIG_HTFG' "$kh_tmp"; then
            rm -f "$kh_tmp"
            die "kheaders archive still contains CONFIG_HTFG"
        fi
        # Short words are safe to check here: this is decompressed text, not
        # the random compressed bytes that "strings" sees in the Image.
        kh_hits="$(grep -aiE 'kernelsu|bakasu|susfs|ksu_htfg|ksu_susfs|config_ksu|config_kpm|config_susfs|ksu_|(^|[^a-z0-9_])ksu([^a-z0-9_]|$)|(^|[^a-z0-9_])kpm([^a-z0-9_]|$)' "$kh_tmp" || true)"
        if [ -n "$kh_hits" ]; then
            echo "kheaders content hits:" >&2
            printf '%s\n' "$kh_hits" | sed -n '1,20p' >&2
            rm -f "$kh_tmp"
            die "kheaders archive contains KSU/SUSFS/KPM/BakaSU markers"
        fi
        if [ "$BUILD_MODE" = "stock" ]; then
            if grep -aq 'CONFIG_MTK_OPLUS_THERMAL' "$kh_tmp"; then
                rm -f "$kh_tmp"
                die "kheaders archive still reports CONFIG_MTK_OPLUS_THERMAL"
            fi
            echo "OK: kheaders reports the stock thermal symbol set"
        fi
        rm -f "$kh_tmp"
        echo "OK: kheaders archive has no HTFG"
    else
        warn "kheaders.tar.xz not found; cannot check header leak"
    fi
fi

if grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$CFG"; then
    die "CONFIG_DEBUG_INFO_BTF=y; stock has BTF disabled"
fi
echo "OK: BTF is disabled (stock)"

# ---- summary ------------------------------------------------------------
echo "HTFG verify: PASS"
echo "HTFG verify: Image sha256 = $(sha256sum "$IMG" | cut -d' ' -f1)"
