#!/bin/bash
# Build the arm64 kernel Image directly from kernel_platform/common.
#
#   fast  : gki_defconfig only (the proven Action-Build fast path).
#   stock : gki_defconfig + arch/arm64/configs/mgk_64_k510_defconfig +
#           kernel/configs/oplus6895.config.  These are exactly the fragments
#           that kernel/build/oplus_build_kernel.sh feeds through
#           gen_build_config.py, but the merge is done here with the kernel's
#           own scripts/kconfig/merge_config.sh.  That avoids the Python 2
#           helper and the dtbo/ext-module stages, neither of which contributes
#           to the Image packaged by AnyKernel3.
#
# Environment: GITHUB_WORKSPACE, GITHUB_ENV, RUNNER_TEMP, ENABLE_RUST.
set -euo pipefail

MODE="${1:-stock}"
case "$MODE" in
  fast|stock) ;;
  *) echo "::error::unknown build mode: $MODE" >&2; exit 2 ;;
esac

WS="${GITHUB_WORKSPACE}/kernel_workspace"
KP="${WS}/kernel_platform"
COMMON="${KP}/common"
[ -d "$COMMON" ] || { echo "::error::kernel_platform/common not found" >&2; exit 1; }

cd "$KP"

USE_LLVM_IAS=false
if [ -f ./common/build.config.arm ] && grep -q '^LLVM_IAS=1' ./common/build.config.arm; then
  USE_LLVM_IAS=true
fi

CLANG_PREBUILT_NAME=$(find "$KP" -maxdepth 1 -type d -name 'prebuilts*' -exec test -d '{}/clang/host/linux-x86' \; -print | head -1 || true)
CLANG_PREBUILT_NAME=$(basename "${CLANG_PREBUILT_NAME:-}")
KERNEL_BUILD_TOOLS_PREBUILT_NAME=$(find "$KP" -maxdepth 1 -type d -name 'prebuilts*' -exec test -d '{}/kernel-build-tools' \; -print | head -1 || true)
KERNEL_BUILD_TOOLS_PREBUILT_NAME=$(basename "${KERNEL_BUILD_TOOLS_PREBUILT_NAME:-}")

CLANG_PREBUILT_BIN=""
if [ -f ./common/build.config.common ]; then
  CLANG_PREBUILT_BIN=$(grep '^CLANG_PREBUILT_BIN=' ./common/build.config.common | cut -d'=' -f2- || true)
fi
if [ -z "$CLANG_PREBUILT_BIN" ]; then
  CLANG_PREBUILT_BIN="${CLANG_PREBUILT_NAME}/clang/host/linux-x86/clang-zakozako/bin"
fi
if [[ "$CLANG_PREBUILT_BIN" =~ clang-(r[0-9a-z]+) ]]; then
  CLANG_VERSION="${BASH_REMATCH[1]}"
elif [ -f ./common/build.config.constants ]; then
  CLANG_VERSION=$(grep '^CLANG_VERSION=' ./common/build.config.constants | cut -d'=' -f2 || true)
fi
if [ -z "${CLANG_VERSION:-}" ]; then
  echo "::warning::clang version not found; build script cannot continue"
  exit 13
fi
CLANG_PREBUILT_BIN="${CLANG_PREBUILT_BIN/\$\{CLANG_VERSION\}/$CLANG_VERSION}"
CLANG_PREBUILT_BIN="${CLANG_PREBUILT_BIN/clang-zakozako/clang-${CLANG_VERSION}}"
export PATH="$KP/$CLANG_PREBUILT_BIN:$PATH"
CLANG_LIB_PATH="${CLANG_PREBUILT_BIN%/bin}"
if [ -d "$KP/$CLANG_LIB_PATH/lib" ]; then
  export LIBCLANG_PATH="$KP/$CLANG_LIB_PATH/lib"
elif [ -d "$KP/clang-${CLANG_VERSION}/lib" ]; then
  export LIBCLANG_PATH="$KP/clang-${CLANG_VERSION}/lib"
else
  export LIBCLANG_PATH="$(clang --print-resource-dir 2>/dev/null | sed 's|/lib/clang/.*||')/lib"
fi
export PATH="/usr/lib/ccache:$PATH"

PAHOLE_BIN="$KP/$KERNEL_BUILD_TOOLS_PREBUILT_NAME/kernel-build-tools/linux-x86/bin/pahole"
if [ ! -x "$PAHOLE_BIN" ]; then
  PAHOLE_BIN="$(command -v pahole 2>/dev/null || true)"
fi
[ -x "$PAHOLE_BIN" ] || { echo "::error::pahole not found" >&2; exit 13; }

if [ "${ENABLE_RUST:-false}" = "true" ]; then
  RUST_TOOLS_PREBUILT_NAME=$(find "$KP" -maxdepth 1 -type d -name 'prebuilts*' -exec test -d '{}/rust' \; -print | head -1 || true)
  RUST_TOOLS_PREBUILT_NAME=$(basename "${RUST_TOOLS_PREBUILT_NAME:-}")
  RUSTC_BIN="$KP/$RUST_TOOLS_PREBUILT_NAME/rust/linux-x86/${RUSTC_DIR_VERSION:-}/bin/rustc"
  [ -x "$RUSTC_BIN" ] || RUSTC_BIN="$(command -v rustc 2>/dev/null || true)"
  [ -x "$RUSTC_BIN" ] || { echo "::error::rustc not found" >&2; exit 13; }
  export RUSTC="$RUSTC_BIN"
  BINDGEN_BIN="$KP/$CLANG_PREBUILT_NAME/clang-tools/linux-x86/bin/bindgen"
  [ -x "$BINDGEN_BIN" ] || BINDGEN_BIN="$(command -v bindgen 2>/dev/null || true)"
  [ -x "$BINDGEN_BIN" ] || { echo "::error::bindgen not found" >&2; exit 13; }
  export BINDGEN="$BINDGEN_BIN"
fi

REAL_CLANG_BIN="$KP/$CLANG_PREBUILT_BIN/clang"
CC_WRAPPER="$WS/cc-wrapper"
printf '#!/bin/bash\nexec ccache "%s" "$@"\n' "$REAL_CLANG_BIN" > "$CC_WRAPPER"
chmod +x "$CC_WRAPPER"

cd "$COMMON"
COMMON_REAL_PATH=$(pwd -P)
PLATFORM_REAL_PATH=$(dirname "$COMMON_REAL_PATH")
ROOT_REAL_PATH=$(dirname "$PLATFORM_REAL_PATH")
MAP="-fdebug-prefix-map=$ROOT_REAL_PATH=."
MPMAP="-fmacro-prefix-map=$ROOT_REAL_PATH=."
FPMAP="-ffile-prefix-map=$ROOT_REAL_PATH=."

# Keep the stock full-LTO configuration; do not force thin LTO and do not
# disable the stack protector.
KCFLAGS="$MAP $FPMAP -no-canonical-prefixes -O2 -pipe -Wno-error -D__ANDROID_COMMON_KERNEL__"
KCPPFLAGS="$MPMAP"

MAKE_ARGS=(
  O=out
  ARCH=arm64
  LLVM=1
  CROSS_COMPILE=aarch64-linux-gnu-
  CC="$CC_WRAPPER"
  HOSTCC="$CC_WRAPPER"
  HOSTLD=ld.lld
  LD=ld.lld
  PAHOLE="$PAHOLE_BIN"
  KCFLAGS="$KCFLAGS"
  KCPPFLAGS="$KCPPFLAGS"
  # CONFIG_DEBUG_INFO stays y in .config, but the DWARF metadata is dropped.
  # With full LTO+KASAN, the debug metadata is what makes the vmlinux link
  # exceed the 7.7 GiB private-repo runner; -g does not change codegen and
  # debug sections are not part of arch/arm64/boot/Image.
  DEBUG_CFLAGS=-g0
)
if [ "$USE_LLVM_IAS" = "true" ]; then
  MAKE_ARGS+=(LLVM_IAS=1)
fi
if [ "${ENABLE_RUST:-false}" = "true" ]; then
  MAKE_ARGS+=(RUSTC="$RUSTC" BINDGEN="$BINDGEN")
fi

make "${MAKE_ARGS[@]}" gki_defconfig --no-print-directory

if [ "$MODE" = "stock" ]; then
  MGK_DEFCONFIG="arch/arm64/configs/mgk_64_k510_defconfig"
  [ -f "$MGK_DEFCONFIG" ] || { echo "::error::$MGK_DEFCONFIG not found" >&2; exit 1; }
  [ -f "kernel/configs/oplus6895.config" ] || { echo "::error::kernel/configs/oplus6895.config not found" >&2; exit 1; }
  FRAG_DIR="$RUNNER_TEMP/htfg-stock-fragments"
  rm -rf "$FRAG_DIR"
  mkdir -p "$FRAG_DIR"
  cp "$MGK_DEFCONFIG" "$FRAG_DIR/mgk_64_k510.config"
  cp "kernel/configs/oplus6895.config" "$FRAG_DIR/oplus6895.config"
  # The OPLUS script passes these two fragments to "make" in this order, and
  # the kernel %.config rule runs merge_config.sh + olddefconfig per fragment.
  # Reproduce that sequence; merge_config.sh -m writes ./.config (cwd = out).
  ( cd out && sh ../scripts/kconfig/merge_config.sh -m .config "$FRAG_DIR/mgk_64_k510.config" )
  make "${MAKE_ARGS[@]}" olddefconfig --no-print-directory
  ( cd out && sh ../scripts/kconfig/merge_config.sh -m .config "$FRAG_DIR/oplus6895.config" )
fi

make "${MAKE_ARGS[@]}" olddefconfig --no-print-directory
# AnyKernel3 ships only Image; vendor/in-tree .ko files are not part of the
# boot partition, so skip the module LTO links (a large time/disk saver on
# the 7.7 GiB runner).  Image still depends on vmlinux, System.map,
# Module.symvers, htfg.o and kernel/kheaders_data.tar.xz.
make -j"$(nproc --all)" "${MAKE_ARGS[@]}" Image
ccache -s || true

IMAGE="$COMMON_REAL_PATH/out/arch/arm64/boot/Image"
if [ ! -f "$IMAGE" ]; then
  IMAGE=$(find "$COMMON_REAL_PATH/out" -type f -name Image -print 2>/dev/null | head -n 1 || true)
fi
[ -n "$IMAGE" ] && [ -f "$IMAGE" ] || { echo "::error::no Image produced" >&2; exit 1; }

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "HTFG_OUT_DIR=$COMMON_REAL_PATH/out" >> "$GITHUB_ENV"
  echo "HTFG_IMAGE=$IMAGE" >> "$GITHUB_ENV"
fi
echo "Built $MODE Image: $IMAGE"
