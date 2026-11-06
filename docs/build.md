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

`scripts/build_kernel_direct.sh stock` 直接在内核源码树里生成与 OPLUS 脚本相同组合的 `.config` 并 `make`：

```
cd kernel_workspace/kernel_platform/common
make O=out ... gki_defconfig
# 等价于 OPLUS 的 gen_build_config.py + make <fragment>.config：
scripts/kconfig/merge_config.sh -m out/.config mgk_64_k510.config
make O=out ... olddefconfig
scripts/kconfig/merge_config.sh -m out/.config oplus6895.config
make O=out ... olddefconfig
make -j... O=out Image
```

- 与原厂 `kernel/build/oplus_build_kernel.sh unknown gki` 使用**同一组 defconfig 片段**（`gki_defconfig` + `arch/arm64/configs/mgk_64_k510_defconfig` + `kernel/configs/oplus6895.config`），所以最终 `.config` 应与原厂构建一致；`htfg_verify` 的 stock 全量 diff 仍会检查这一点。唯一例外是公开分支的热驱动符号名：原厂 vendor 树用 `CONFIG_MTK_REALME_THERMAL=m`，公开分支改为 `CONFIG_MTK_OPLUS_THERMAL=m`；REALME 驱动未公开，无法精确还原。verify 只对这一精确配对放行并 warning，其他差异仍判红。
- 不再调用 `kernel/build/oplus_build_kernel.sh`：它依赖的 `kernel-5.10/scripts/gen_build_config.py` 是 **Python 2**（`print '...'`），在 runner 的 `python -> python3` 下直接 `SyntaxError`；该旧布局还把工具链写在 `kernel/prebuilts*` 下，而本 manifest 放在 `kernel_platform/`。
- 不执行 `build_dt_cmd` 和 `EXT_MODULES`：产物只打包 `Image`，dtbo/供应商 `.ko` 不在本项目产物里；DT 工具（`device/mediatek`、`vendor/mediatek/.../dct`）本 manifest 也不同步。
- **HTFG 注入的 defconfig 是 `arch/arm64/configs/mgk_64_k510_defconfig`**（不是 `gki_defconfig`）。workflow 的 `HTFG Inject` 在 stock 模式传 `HTFG_DEFCONFIG=arch/arm64/configs/mgk_64_k510_defconfig`。
- **报告层与真实配置分离**：真实 `.config` 保留 `CONFIG_MTK_OPLUS_THERMAL=m`（verify 的 allowlist 放行）；fake `config_data.gz` 与 kheaders 把报告名替换为 stock 的 `CONFIG_MTK_REALME_THERMAL`，使 `/proc/config.gz` 与 stock 逐字节相同（实测替换后 232546 字节全等）。这只改报告数据块，不改变编译配置/行为；`HTFG Verify` 在 stock 模式下对 fake config 和 Image 内嵌 IKCFG 做逐字节校验。
- **源码 pin**：`Pin Kernel Source` 在 `repo sync` 之后、任何本地修改之前读取 `manifest/pinned-sources.txt` 的 `KERNEL_SHA`；HEAD 不一致时 `git fetch --depth=1` + `checkout --detach`，失败即红。check_defconfig 的 sed 拆到随后的 `Prepare Build Config`，避免本地修改阻止 checkout。
- 不覆盖 `LTO` 环境变量，保持原厂 full LTO；不设置 `TMPFS_*`、`BBG`、`KPM`、`SUSFS`、`KSU`。
- **`BRANCH` / `KMI_GENERATION` 从 `common/build.config.common` 解析后显式传给 make**：顶层 Makefile 的 `filechk_kernel.release` 把这两个变量作为 `scripts/setlocalversion` 的第 2/3 个参数；OPLUS 的 `build.sh` 通过 `set -a` source 配置文件让 make 继承，直接 `make` 不会。缺了它们 `setlocalversion` 只输出 `-o-g<sha>`，`Custom Kernel Suffix` 再拼接就变成 `-o-9-o-g<sha>`，`HTFG Verify` 的 `UTS_RELEASE` 精确校验会失败（实测 `5.10.236-o-9-o-g38e2c85bc7af`）。传入 `BRANCH=android12-5.10`、`KMI_GENERATION=9` 后输出 `-android12-9-o-g<sha>`，后缀注入（`cut -d- -f1-2` 保留 `-android12`）最终得到原厂的 `5.10.236-android12-9-o-g38e2c85bc7af`。
- **runner 资源**：仓库保持 public，使用公开 runner（4 vCPU / 16 GiB）；full LTO + KASAN 需要这个配置（私有 Free 计划只有 2 vCPU / 7.7 GiB，实测 63 分钟后在 `Build Kernel Stock` 被杀）。为留足余量，workflow 用 `Maximize Build Space` 创建 **8 GiB LVM swap**（build 卷约 23 GiB），并给 make 传 `DEBUG_CFLAGS=-g0`：`.config` 仍是 `CONFIG_DEBUG_INFO=y`（全量 diff 通过），只是不生成 DWARF 调试信息；`-g` 不参与代码生成，调试段也不在 `arch/arm64/boot/Image` 里。
- 只构建 `Image` 目标（不构建 `modules`/`Image.lz4`）：产物只打包 `Image`，vendor/in-tree `.ko` 不属于 boot 分区；`Image` 仍会生成 `vmlinux`、`System.map`、`Module.symvers`、`htfg.o` 和 `kernel/kheaders_data.tar.xz`。
- **ccache 放在 `$GITHUB_WORKSPACE`（大卷），不放在 `$HOME`**：root 文件系统在 `Maximize Build Space` 后只剩约 2 GiB；旧做法把多 GiB ccache 放到 root，编译中途可能把 root 写满，连带 runner 失去通信。ccache 上限 4 GiB；`Maximize` 脚本也会删掉 runner 自带的 `/swapfile`，只保留 LVM swap。
- 构建结束后脚本确认 `Image` 确实生成，并把 `HTFG_OUT_DIR` 写入 `$GITHUB_ENV` 供 `HTFG Verify` 使用。

### 2.2 fast（显式 fallback）

```
scripts/build_kernel_direct.sh fast     # gki_defconfig + make
```

- 只用于 stock 路径在 runner 上跑不动/跑不通时的诊断/备用。
- 不应用 OPLUS fragments；`htfg_verify.sh` 在 `BUILD_MODE=fast` 时跳过全量 stock config diff，只保留关键项校验，并打印 warning。
- 不再强制 thin LTO（原厂 full LTO 保持）；不再加 `-fno-stack-protector`。
- 若 `CLANG_VERSION` 找不到，FAST 步骤写 `fallback=true`，随后自动转 stock 路径。

> 结论：**优先 stock**。fast 是“能产出 Image”的工程备用，不是“与原厂 config 一致”的证明。

## 3. Full LTO 资源风险

原厂 `CONFIG_LTO_CLANG_FULL=y` + `KASAN/KFENCE/UBSAN/CFI_CLANG`，标准 GitHub runner（4 vCPU/16 GB）可能 OOM 或超时。当前 workflow：

- `Maximize Build Space` 合并 root + `/mnt` 的空间，挂一个大的 ext4 到 `$GITHUB_WORKSPACE`，并创建 **8 GiB LVM swap**（build 卷约 23 GiB）；
- 给 make 传 `DEBUG_CFLAGS=-g0`：`.config` 仍是 `CONFIG_DEBUG_INFO=y`（全量 diff 通过），只去掉 DWARF 元数据；`-g` 不参与代码生成，调试段也不进 `arch/arm64/boot/Image`；
- 默认 stock；如果 OOM/超时，先换更大 runner，或显式选择 `BUILD_MODE=fast`（接受 config 偏差，并在 `docs/detection-surface.md` 登记）。

`DEBUG_CFLAGS=-g0` 是当前 workflow 的固定行为（不是隐藏开关）：它解决 full LTO + KASAN 在 runner 上 `vmlinux` 链接被 SIGTERM 的问题；若将来需要调整，必须同步更新本节与 `docs/verify.md` 的校验口径。

## 4. Manifest 与源码

- `manifest/oneplus_ace_race_v.xml` 是 vendored 的小 XML；来源/理由见 `manifest/SOURCE.md`。
- workflow 在 `$RUNNER_TEMP` 建一个本地 git 仓库，把 XML 作为 manifest 文件，`repo init -u file://...`，不 clone 任何第三方 manifest 仓库。
- 项目列表仍来自 `OnePlusOSS` 和 `git.codelinaro.org`；`repo sync` 需要 runner 能访问这两处。
- `android_kernel_5.10_oneplus_mt6895` 的公开分支头不一定等于原厂提交 `38e2c85...`；见 `stock-baseline.md` §5。实际构建的源码由 `manifest/pinned-sources.txt` 的 `KERNEL_SHA` 钉住（当前 `05dd76e8...`）；首启若 vendor 模块报 CRC/vermagic，先回厂 boot，再审查源码差异。

## 5. 注入顺序

1. `Stage Build Inputs`：把 `htfg/`、`baseline/`、`manifest/`、`scripts/` 复制到 `$RUNNER_TEMP`（`Maximize Build Space` 会覆盖 workspace）。
2. `Maximize Build Space`。
3. `Configure Git`、`Validate Inputs`、`Load Manifest Info`。
4. 8 GiB LVM swap、ccache、依赖、repo init/sync。
5. `Pin Kernel Source`（`repo sync` 后、任何本地修改前；校验/checkout `KERNEL_SHA`）。
6. `Prepare Build Config`（check_defconfig 修补；必须在 pin 之后）。
7. `Kernel Version Handling`、`Rust Version Handling`。
8. `Custom Kernel Suffix`（修改 `setlocalversion`）。
9. `HTFG Inject`（复制 5 文件、挂 drivers、patch `kernel/sys.c`、fake config、kheaders）。
10. `Custom BUILD_TIME`（`KBUILD_BUILD_*` + `mkcompile_h`）。
11. `Disable GPUEB`（MTK 5.10；沿用旧工作流能开机的修正）、`Fix libbpf`。
12. `Build Kernel FAST`（仅 fast）或 `Build Kernel Stock`；两者都调用 `scripts/build_kernel_direct.sh`。
13. `Resolve Effective Build Mode`（fast 回退时记为 stock）。
14. `HTFG Verify`（构建后、打包前；含 fake config/Image IKCFG 逐字节校验）。
15. `Make Image Artifact`（只放 `Image` + `htfg-build-info.txt` + `SHA256SUMS`）。
16. `Upload Image Artifact`；ccache 保存。

## 6. 产物

- Artifact：`HTFG_Image_oneplus_ace_race_v_<stock|fast>_9-o-g38e2c85bc7af`，zip 根目录只有 `Image`、`htfg-build-info.txt`、`SHA256SUMS`。`build_mode` 用实际执行的模式（fast 回退到 stock 时记 stock）。
- `htfg-build-info.txt`：`build_mode`、`kernel_source_sha`、`kernel_release`、`image_sha256`、`build_time`，用于下载后核对 provenance。
- 没有 KSU/SUSFS/KPM/BakaSU 的 APK、模块、patch 二进制，也没有 AnyKernel3 的 `tools/`/`META-INF`/`anykernel.sh`；产物不能直接当 AK3 刷机包使用。
- 紫罗兰“制作 GKI 镜像”直接选 `Image` + 原厂 `boot.img`，得到 `boot-new.img`。
- `HTFG Verify` 日志末尾打印 `Image sha256`，刷机前解包 boot 后要逐位比对。
- 下载产物后先跑 `python tools/check_artifact.py <zip> --boot <boot-new.img> --stock-boot 原厂镜像/boot.img`；完整刷机前/后检查清单见 `docs/构建后验证清单.md`。
