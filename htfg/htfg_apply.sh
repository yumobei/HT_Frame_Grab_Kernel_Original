#!/usr/bin/env bash
# ============================================================================
# HTFG clean-kernel injection script
#
# This is the standalone (no Action-Build, no KSU/SUSFS/KPM) version.
# It is run from the kernel source tree after `repo sync`:
#
#   HTFG_SRC_DIR=$RUNNER_TEMP/htfg \
#   HTFG_KERNEL_TREE=$GITHUB_WORKSPACE/kernel_workspace/kernel_platform/common \
#   bash "$RUNNER_TEMP/htfg/htfg_apply.sh"
#
# Optional:
#   HTFG_DEFCONFIG=arch/arm64/configs/gki_defconfig
#   HTFG_FAKE_CONFIG=0|1          (default 1: filter /proc/config.gz)
#   HTFG_KHEADERS_FILTER=0|1      (default 1: remove HTFG from kheaders)
#   HTFG_ALLOW_TOOL_UID=0|1       (default 0: production, APK cert only)
#   HTFG_REV=<commit>             (optional log only)
#
# Console messages are ASCII/English on purpose (Windows consoles).
# ============================================================================
set -euo pipefail

die() {
    echo "HTFG: ERROR: $*" >&2
    exit 1
}

chk() {  # $1=description $2=expected $3=actual
    if [ "$2" = "$3" ]; then
        echo "  OK: $1 = $3"
    else
        echo "  FAIL: $1 = $3 (expected $2)"
        FAIL=1
    fi
}

# ---- 0) locate the source tree -------------------------------------------
if [ -n "${HTFG_KERNEL_TREE:-}" ]; then
    cd "$HTFG_KERNEL_TREE"
elif [ -f kernel/sys.c ]; then
    :
elif [ -f kernel_workspace/kernel_platform/common/kernel/sys.c ]; then
    cd kernel_workspace/kernel_platform/common
else
    die "kernel tree not found (kernel/sys.c); set HTFG_KERNEL_TREE"
fi

if [ -z "${HTFG_SRC_DIR:-}" ]; then
    HTFG_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
HTFG_SRC_DIR="$(cd "$HTFG_SRC_DIR" && pwd)"
echo "HTFG inject: tree=$(pwd) src=$HTFG_SRC_DIR rev=${HTFG_REV:-unknown}"

for f in htfg.c htfg.h Kconfig Makefile patch_sysc.py; do
    [ -s "$HTFG_SRC_DIR/$f" ] || die "missing or empty source file: $HTFG_SRC_DIR/$f"
done

# ---- 1) copy the five kernel-side files ----------------------------------
mkdir -p drivers/htfg
cp -f "$HTFG_SRC_DIR/htfg.c"   drivers/htfg/htfg.c
cp -f "$HTFG_SRC_DIR/Kconfig"  drivers/htfg/Kconfig
cp -f "$HTFG_SRC_DIR/Makefile" drivers/htfg/Makefile
cp -f "$HTFG_SRC_DIR/htfg.h"   include/linux/htfg.h

# ---- 2) hook into the build tree -----------------------------------------
grep -q 'drivers/htfg/Kconfig' drivers/Kconfig || \
    sed -i '/endmenu/i source "drivers/htfg/Kconfig"' drivers/Kconfig
grep -qF 'obj-$(CONFIG_HTFG) += htfg/' drivers/Makefile || \
    sed -i '$a obj-$(CONFIG_HTFG) += htfg/' drivers/Makefile

# ---- 3) enable the driver in the requested defconfig ---------------------
HTFG_DEFCONFIG="${HTFG_DEFCONFIG:-arch/arm64/configs/gki_defconfig}"
[ -f "$HTFG_DEFCONFIG" ] || die "defconfig not found: $HTFG_DEFCONFIG (set HTFG_DEFCONFIG)"
grep -q '^CONFIG_HTFG=y' "$HTFG_DEFCONFIG" || echo 'CONFIG_HTFG=y' >> "$HTFG_DEFCONFIG"

if [ "${HTFG_ALLOW_TOOL_UID:-0}" = "1" ]; then
    grep -q '^CONFIG_HTFG_ALLOW_TOOL_UID=y' "$HTFG_DEFCONFIG" || \
        echo 'CONFIG_HTFG_ALLOW_TOOL_UID=y' >> "$HTFG_DEFCONFIG"
else
    if grep -q '^CONFIG_HTFG_ALLOW_TOOL_UID=y' "$HTFG_DEFCONFIG"; then
        die "HTFG_ALLOW_TOOL_UID is not 1 but the defconfig enables it"
    fi
fi

if grep -qE '^CONFIG_(KSU|SUSFS|KPM)' "$HTFG_DEFCONFIG"; then
    die "defconfig still contains KSU/SUSFS/KPM options"
fi

# ---- 4) install the prctl() hook -----------------------------------------
if [ -z "${PYTHON:-}" ]; then
    if command -v python3 >/dev/null 2>&1; then
        PYTHON=python3
    elif command -v python >/dev/null 2>&1; then
        PYTHON=python
    else
        die "python3/python not found"
    fi
fi
"$PYTHON" "$HTFG_SRC_DIR/patch_sysc.py" kernel/sys.c

# ---- 5) filter /proc/config.gz (fake config_data) ------------------------
install_fake_config_filter() {
    local kmake="kernel/Makefile"
    [ -f "$kmake" ] || die "missing $kmake"

    "$PYTHON" - "$kmake" <<'PY'
import io
import sys

path = sys.argv[1]
text = io.open(path, "r", encoding="utf-8", errors="surrogateescape", newline="").read()

# Only HTFG.  The ^CONFIG_HTFG / ^# CONFIG_HTFG prefixes also cover
# CONFIG_HTFG_ALLOW_TOOL_UID.
EXPRS = (" -e '/^CONFIG_HTFG/d'"
         " -e '/^# CONFIG_HTFG/d'")
MARKER = "# --- HTFG fake config filter ---"
UPSTREAM = "# --- fake_config injector ---"

def die(msg):
    sys.stderr.write("HTFG fake config: FAILED: %s\n" % msg)
    sys.exit(1)

lines = text.splitlines(keepends=True)

def find_line(pred, start=0):
    for i in range(start, len(lines)):
        if pred(lines[i]):
            return i
    return -1

def find_rule(start):
    ridx = find_line(lambda l: l.strip().startswith("$(obj)/config_data:"), start)
    if ridx < 0:
        return -1, -1
    for i in range(ridx + 1, min(ridx + 5, len(lines))):
        if "sed" in lines[i] and "$(KCONFIG_CONFIG) > $@" in lines[i]:
            return ridx, i
    return ridx, -1

up = find_line(lambda l: l.strip() == UPSTREAM)
if up >= 0:
    # Upstream fake_config rule (normally absent in the clean OnePlus tree)
    gstart = find_line(lambda l: l.strip() == "ifneq ($(strip $(CONFIG_FAKE_DISABLE)),)", up)
    gend = find_line(lambda l: l.strip() == "endif", gstart + 1) if gstart >= 0 else -1
    if gstart >= 0 or gend >= 0:
        if gstart < 0 or gend < 0:
            die("upstream fake_config gating is incomplete")
        ridx, sidx = find_rule(up)
        if ridx < 0 or sidx < 0 or not (gstart < ridx < gend):
            die("upstream fake_config gating does not wrap the config_data rule")
        del lines[gend]
        del lines[gstart]

    ridx, sidx = find_rule(up)
    if ridx < 0 or sidx < 0:
        die("upstream fake_config block has no expected config_data rule/sed line")

    if "CONFIG_HTFG/d" not in lines[sidx]:
        if "CONFIG_HTFG/d" in text:
            die("CONFIG_HTFG/d exists outside the effective upstream rule")
        lines[sidx] = lines[sidx].replace(
            "$(KCONFIG_CONFIG) > $@", EXPRS + " $(KCONFIG_CONFIG) > $@", 1)

    if not any(MARKER in l for l in lines):
        lines.insert(up, MARKER + "\n")
else:
    if "CONFIG_HTFG/d" in text:
        if MARKER in text:
            print("HTFG fake config: already patched")
            sys.exit(0)
        die("CONFIG_HTFG/d exists but no HTFG marker was found")
    ridx, _ = find_rule(0)
    if ridx < 0:
        die("cannot find $(obj)/config_data rule")

    if ridx + 1 < len(lines) and "$(call filechk,cat)" in lines[ridx + 1]:
        lines[ridx + 1] = ("\t$(Q)mkdir -p $(dir $@); sed" + EXPRS
                           + " $(KCONFIG_CONFIG) > $@\n")
        if not any(MARKER in l for l in lines):
            lines.insert(ridx, MARKER + "\n")
    else:
        fidx = find_line(lambda l: l.strip() == "filechk_cat = cat $<")
        if fidx < 0:
            die("cannot find config_data filechk recipe or filechk_cat")
        lines[fidx] = "filechk_cat = sed" + EXPRS + " $(KCONFIG_CONFIG)\n"
        if not any(MARKER in l for l in lines):
            lines.insert(fidx, MARKER + "\n")

out = "".join(lines)
n_filter_lines = sum(1 for l in lines if "CONFIG_HTFG/d" in l)
if n_filter_lines != 1:
    die("expected exactly one CONFIG_HTFG/d line, got %d" % n_filter_lines)
if out.count(MARKER) != 1:
    die("expected exactly one HTFG fake config marker, got %d" % out.count(MARKER))

io.open(path, "w", encoding="utf-8", errors="surrogateescape", newline="").write(out)
print("HTFG fake config: patched %s" % path)
PY
}

if [ "${HTFG_FAKE_CONFIG:-1}" = "1" ]; then
    install_fake_config_filter
else
    echo "HTFG fake config: disabled (HTFG_FAKE_CONFIG=0)"
fi

# ---- 6) remove HTFG from the kheaders archive ----------------------------
patch_kheaders() {
    local f="kernel/gen_kheaders.sh"
    [ -f "$f" ] || die "missing $f"

    "$PYTHON" - "$f" <<'PY'
import io
import sys

path = sys.argv[1]
text = io.open(path, "r", encoding="utf-8", errors="surrogateescape", newline="").read()
MARKER = "# --- HTFG kheaders filter ---"
ANCHOR = "# Remove comments except SDPX lines\n"

if MARKER in text:
    print("HTFG kheaders: already patched")
    sys.exit(0)
if ANCHOR not in text:
    sys.stderr.write("HTFG kheaders: FAILED: anchor not found in %s\n" % path)
    sys.exit(1)

block = (
    MARKER + "\n"
    'rm -f "$cpio_dir/include/linux/htfg.h"\n'
    # Kconfig may create timestamp/empty files under include/config; the
    # gen_kheaders.sh archive only copies *.h, so remove both the .h form and
    # the bare form, uppercase and lowercase.
    'rm -f "$cpio_dir"/include/config/HTFG* "$cpio_dir"/include/config/htfg*\n'
    'if [ -f "$cpio_dir/include/generated/autoconf.h" ]; then\n'
    "\tsed -i '/CONFIG_HTFG/d' \"$cpio_dir/include/generated/autoconf.h\"\n"
    "fi\n"
    'if [ -f "$cpio_dir/include/config/auto.conf" ]; then\n'
    "\tsed -i '/CONFIG_HTFG/d' \"$cpio_dir/include/config/auto.conf\"\n"
    "fi\n"
    "# --- HTFG kheaders filter end ---\n"
)

text = text.replace(ANCHOR, block + ANCHOR, 1)
io.open(path, "w", encoding="utf-8", errors="surrogateescape", newline="").write(text)
print("HTFG kheaders: patched %s" % path)
PY
}

if [ "${HTFG_KHEADERS_FILTER:-1}" = "1" ]; then
    patch_kheaders
else
    echo "HTFG kheaders: filter disabled (HTFG_KHEADERS_FILTER=0)"
fi

# ---- 7) self-check: every mount/hook must appear exactly once ------------
FAIL=0
chk "kernel/sys.c htfg_kernel_entry" 1 "$(grep -c 'htfg_kernel_entry' kernel/sys.c || true)"
chk "drivers/Kconfig HTFG mount" 1 "$(grep -c 'drivers/htfg/Kconfig' drivers/Kconfig || true)"
chk "drivers/Makefile HTFG mount" 1 "$(grep -cF 'obj-$(CONFIG_HTFG) += htfg/' drivers/Makefile || true)"
chk "defconfig CONFIG_HTFG=y" 1 "$(grep -c '^CONFIG_HTFG=y' "$HTFG_DEFCONFIG" || true)"

if [ "${HTFG_ALLOW_TOOL_UID:-0}" = "1" ]; then
    chk "defconfig CONFIG_HTFG_ALLOW_TOOL_UID=y" 1 \
        "$(grep -c '^CONFIG_HTFG_ALLOW_TOOL_UID=y' "$HTFG_DEFCONFIG" || true)"
fi

if [ "${HTFG_FAKE_CONFIG:-1}" = "1" ]; then
    chk "kernel/Makefile HTFG fake marker" 1 \
        "$(grep -c 'HTFG fake config filter' kernel/Makefile || true)"
    chk "kernel/Makefile CONFIG_HTFG filter" 1 \
        "$(grep -c 'CONFIG_HTFG/d' kernel/Makefile || true)"
fi

if [ "${HTFG_KHEADERS_FILTER:-1}" = "1" ]; then
    chk "gen_kheaders.sh HTFG filter" 1 \
        "$(grep -c '^# --- HTFG kheaders filter ---$' kernel/gen_kheaders.sh || true)"
fi

if [ "$FAIL" != 0 ]; then
    die "injection self-check failed (see counts above)"
fi

ls -l drivers/htfg/ include/linux/htfg.h
echo "HTFG: injection complete (rev ${HTFG_REV:-unknown})"
