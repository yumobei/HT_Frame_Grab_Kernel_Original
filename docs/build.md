# 构建说明

## 1. Workflow 输入

`.github/workflows/build.yml` 只有这几个输入：

| 输入 | 默认 | 说明 |
|---|---|---|
| `FILE` | `oneplus_ace_race_v` | 只保留本设备；manifest 在 `manifest/` |
| `SUFFIX` | `9-o-g38e2c85bc7af` | 原厂后缀；不要用 `-1` 或随机值 |
| `BUILD_TIME` | `Mon Jan 12 09:35:58 UTC 2026` | 原厂时间；不要用 `F`/`-1` |
| `BUILD_MODE` | `stock` | `stock` = OPLUS 脚本；`fast` = 直接 make |
| `DEBUG_TOOL_UID` | `false` | 生产必须 false；true 才编译 uid 0/2000 调试白名单 |
| `BUILD_NOCACHE` | `false` | true 时不恢复/保存 ccache |

`SUFFIX` / `BUILD_TIME` 若不是原厂值，workflow 只发 warning；`HTFG Verify` 的 `UTS_RELEASE`/banner 精确校验会失败，这是有意的——不要把“能过构建”当成“与原厂一致”。

## 2. 两条构建路径

### 2.1 stock（默认）

```
cd kernel_workspace
./kernel/build/oplus_build_kernel.sh unknown gki
```

- `unknown` 是 `oplus_setup.sh` 的 `choose_platform` 默认值（落到 6895）；`gki` 是 build type（user）。
- 脚本内部用 `kernel-5.10/scripts/gen_build_config.py --kernel-defconfig mgk_64_k510_defconfig --kernel-defconfig-overlays oplus6895.config ...`，再走 `kernel/build/build.sh`。
- 因此 **HTFG 注入的 defconfig 是 `arch/arm64/configs/mgk_64_k510_defconfig`**，不是 `gki_defconfig`。workflow 的 `HTFG Inject` 在 stock 模式传 `HTFG_DEFCONFIG=arch/arm64/configs/mgk_64_k510_defconfig`。
- `oplus_build_kernel.sh` 内部已经用 `POST_DEFCONFIG_CMDS="exit 0"` 跳过 defconfig 检查；workflow 里对 `build.config.gki`/`common_kernels.bzl` 的 `check_defconfig` 处理只是防御性 build-mechanics，不改生成的 `.config`。
- 按旧 OPLUS 流程设置 `KMI_SYMBOL_LIST_STRICT_MODE=0`、`SYSTEM_DLKM_RE_SIGN=0`、`BUILD_SYSTEM_DLKM=0`（只为构建通过；`htfg_verify` 仍对最终 `.config` 做全量 stock diff）。
- 不覆盖 `LTO` 环境变量，让 OPLUS 脚本按原厂 build.config 走 full LTO；不设置 `TMPFS_*`、`BBG`、`KPM`、`SUSFS`、`KSU`。

### 2.2 fast（显式 fallback）

```
cd kernel_workspace/kernel_platform/common
make O=out ... gki_defconfig
make O=out ... olddefconfig
make -j... O=out ...
```

- 只用于 stock 路径在 runner 上跑不动/跑不通时的诊断/备用。
- 不应用 OPLUS fragments；`htfg_verify.sh` 在 `BUILD_MODE=fast` 时跳过全量 stock config diff，只保留关键项校验，并打印 warning。
- 不再强制 thin LTO（原厂 full LTO 保持）；不再加 `-fno-stack-protector`。
- 若 `CLANG_VERSION` 找不到，FAST 步骤写 `fallback=true`，随后自动转 stock 路径。

> 结论：**优先 stock**。fast 是“能产出 Image”的工程备用，不是“与原厂 config 一致”的证明。

## 3. Full LTO 资源风险

原厂 `CONFIG_LTO_CLANG_FULL=y` + `KASAN/KFENCE/UBSAN/CFI_CLANG`，标准 GitHub runner（4 vCPU/16 GB）可能 OOM 或超时。当前 workflow：

- `Maximize Build Space` 合并 root + `/mnt` 的空间，挂一个大的 ext4 到 `$GITHUB_WORKSPACE`；
- `Create and Enable 3G Swap` 增加 3 GB swap；
- 默认 stock；如果 OOM/超时，先换更大 runner，或显式选择 `BUILD_MODE=fast`（接受 config 偏差，并在 `docs/detection-surface.md` 登记）。

没有使用 `-g0` 之类“关调试信息换构建”的隐式手段；如果将来需要，必须作为显式输入并在 build-info 记录，不能静默。

## 4. Manifest 与源码

- `manifest/oneplus_ace_race_v.xml` 是 vendored 的小 XML；来源/理由见 `manifest/SOURCE.md`。
- workflow 在 `$RUNNER_TEMP` 建一个本地 git 仓库，把 XML 作为 manifest 文件，`repo init -u file://...`，不 clone 任何第三方 manifest 仓库。
- 项目列表仍来自 `OnePlusOSS` 和 `git.codelinaro.org`；`repo sync` 需要 runner 能访问这两处。
- `android_kernel_5.10_oneplus_mt6895` 的公开分支头不一定等于原厂提交 `38e2c85...`；见 `stock-baseline.md` §5。首启若 vendor 模块报 CRC/vermagic，先回厂 boot，再决定是否钉提交/换 manifest。

## 5. 注入顺序

1. `Stage Build Inputs`：把 `htfg/`、`baseline/`、`manifest/`、`scripts/` 复制到 `$RUNNER_TEMP`（`Maximize Build Space` 会覆盖 workspace）。
2. `Maximize Build Space`。
3. `Configure Git`、`Validate Inputs`、`Load Manifest Info`。
4. 3G swap、ccache、依赖、repo init/sync。
5. `Kernel Version Handling`、`Rust Version Handling`。
6. `Custom Kernel Suffix`（修改 `setlocalversion`）。
7. `HTFG Inject`（复制 5 文件、挂 drivers、patch `kernel/sys.c`、fake config、kheaders）。
8. `Custom BUILD_TIME`（`KBUILD_BUILD_*` + `mkcompile_h`）。
9. `Disable GPUEB`（MTK 5.10；沿用旧工作流能开机的修正）、`Fix libbpf`。
10. `Build Kernel FAST`（仅 fast）或 `Build Kernel Stock`。
11. `HTFG Verify`（构建后、AK3 前）。
12. `Make AnyKernel3`（`osm0sis/AnyKernel3`，只放 `Image`）。
13. `Upload AnyKernel3`；ccache 保存。

## 6. 产物

- Artifact：`HTFG_Clean_oneplus_ace_race_v_9-o-g38e2c85bc7af`，内容是 AnyKernel3 文件树（`anykernel.sh`、`META-INF`、`tools`、`Image`）。
- 没有 KSU/SUSFS/KPM/BakaSU 的 APK、模块、patch 二进制。
- 紫罗兰“制作 GKI 镜像”只取其中的 `Image`；AK3 的 `do.devicecheck=0`、`do.modules=0`、`do.systemless=0`、`do.cleanup=1`。
- `HTFG Verify` 日志末尾打印 `Image sha256`，刷机前解包 boot 后要逐位比对。
