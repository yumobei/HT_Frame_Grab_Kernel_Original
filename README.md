# HTFG_Kernel_Original

只带 HTFG 的**无 root** 内核独立构建项目。目标设备：一加 Ace 竞速版（Android 15，GKI 5.10.236，原厂内核 `5.10.236-android12-9-o-g38e2c85bc7af`）。

本项目与旧 `HT_Frame_Grab_Kernel_CC` 的 App/reader/协议 **ABI 完全一致**：`UI_Fetch_KM` / `NEW_AI_JiaoBen` 不需要改代码；变化只在内核侧——去掉 KSU / SUSFS / KPM / BakaSU 管理器 / SUSFS 模块 / root 用户态，只保留 HTFG 的 `READ_MEM` / `FIND_PID` / `GET_VMAS` / `TOUCH_DEV` / `TOUCH_SEND`。

> 状态：**仓库保持 public 进行云构建**。公开 runner 为 4 vCPU / 16 GiB；full LTO + KASAN 需要这个配置（私有 Free 计划只有 2 vCPU / 7.7 GiB，链接会被打挂，实测 63 分钟后在 `Build Kernel Stock` 被杀）。原厂 `boot.img` 被 `.gitignore` 排除，不随仓库上传。由用户自行构建、刷机、真机验证。

## 目标

1. 内核 Image 中不再有 KSU/SUSFS/KPM/BakaSU；`/proc/version`、`/proc/config.gz`、`/sys/kernel/kheaders.tar.xz` 等公开面与原厂一致（`CONFIG_HTFG` 本身被 fake config/kheaders 过滤）。
2. 生产身份门只保留 **htai APK 签名证书** 路径；uid 0/2000 只在显式 `DEBUG_TOOL_UID=true` 的调试构建中存在，默认不编译。
3. 保留“自定义后缀 + 自定义构建时间”能力，但默认值就是原厂值；`KBUILD_BUILD_USER/HOST` 也固定为原厂的 `build-user@build-host`，不再出现 `runner@...`。
4. 构建过程不 clone `Numbersf/Action-Build`，不依赖作者仓库；设备 manifest 已作为小 XML 放在 `manifest/` 中（原因见 `manifest/SOURCE.md`）。

## 原厂基线

完整 banner 见 `baseline/stock_version.txt`（从 `原厂镜像/boot.img` 的内核中逐字提取）：

```
Linux version 5.10.236-android12-9-o-g38e2c85bc7af (build-user@build-host) (... clang version 12.0.5 ...) #1 SMP PREEMPT Mon Jan 12 09:35:58 UTC 2026
```

关键 config（完整内嵌 config 见 `baseline/stock.config.gz`）：

| 项 | 原厂值 | 本项目处理 |
|---|---|---|
| `CONFIG_LTO_CLANG_FULL` | `y` | stock 路径保持 full LTO；fast 路径也保持 full，不再强制 thin |
| `CONFIG_LTO_CLANG_THIN` | `n` | 不设置 |
| `CONFIG_TMPFS_XATTR` / `_POSIX_ACL` | `n` / `n` | 不设置（旧 Action-Build 无条件设 `y`，已去掉） |
| `CONFIG_STACKPROTECTOR_STRONG` | `y` | 保留；去掉旧 FAST 路径的 `-fno-stack-protector` |
| `CONFIG_DEBUG_INFO_BTF` | `n` | 保持关闭 |
| `CONFIG_IKHEADERS` | `y` | 保留；在 `gen_kheaders.sh` 中剔除 HTFG 头/配置 |
| `CONFIG_KALLSYMS_ALL` | `y` | 保留（本 ROM 普通 App/shell 读不了） |
| `CONFIG_CRYPTO_SHA256` | `y` | 依赖 `y`；不能是 `m`（避免首次验签触发模块加载） |
| `CONFIG_MODVERSIONS` | `y` | 保留；vendor 模块 CRC 依赖 |
| `CONFIG_KSU/SUSFS/KPM/BBG` | 不存在 | 全部移除；`CONFIG_HTFG` 是唯一新增项 |

## 目录

```
htfg/                     HTFG 内核源码（htfg.c/h、Kconfig、Makefile、patch_sysc.py）
htfg/htfg_apply.sh        注入脚本（复制 5 文件、挂 Kconfig/Makefile、patch sys.c、fake config、kheaders）
htfg/htfg_verify.sh       构建后校验（config、banner、符号、kheaders、BTF、Image 字符串）
.github/workflows/build.yml  独立 clean workflow（OnePlusOSS + HTFG，无 Action-Build）
manifest/                 本设备 manifest 小 XML + 构建命令（vendored，见 SOURCE.md）
baseline/                 原厂 banner 与内嵌 config（构建后 diff 用）
scripts/                  maximize-build-space.sh（独立实现的 runner 空间扩展）
tools/extract_stock_baseline.py  只读解析 boot.img，重新生成 baseline
docs/                     设计、构建、验证、检测面说明
原厂镜像/boot.img         本地原厂 boot（.gitignore 排除，不随项目上传）
```

## 构建

由用户在 GitHub Actions 手动运行 `.github/workflows/build.yml`：

- `FILE=oneplus_ace_race_v`
- `SUFFIX=9-o-g38e2c85bc7af`
- `BUILD_TIME=Mon Jan 12 09:35:58 UTC 2026`
- `BUILD_MODE=stock`（默认；直接 `make`，配置片段与原厂 `kernel/build/oplus_build_kernel.sh unknown gki` 相同：`gki_defconfig` + `mgk_64_k510_defconfig` + `oplus6895.config`）
- `DEBUG_TOOL_UID=false`（生产必须 false）
- `BUILD_NOCACHE=false`

源码 pin：`manifest/pinned-sources.txt` 的 `KERNEL_SHA`（以及 `ANYKERNEL3_SHA`）。`Pin Kernel Source` 在 `repo sync` 后校验内核树，漂移时尝试 fetch/checkout 该提交，失败即红并提示更新 pin。报告层对齐：fake `/proc/config.gz` 与 kheaders 里的 thermal 符号报告为 stock 的 `CONFIG_MTK_REALME_THERMAL`；真实 `.config` 仍是 `CONFIG_MTK_OPLUS_THERMAL`（公开分支无 realme 驱动），verify 的 allowlist 保留。

stock 路径的 full LTO + KASAN/CFI 对 runner 内存/时间要求高；失败时可显式改用 `BUILD_MODE=fast`（直接 `make gki_defconfig`），但 fast 不应用 OPLUS fragments，`htfg_verify` 会跳过全量 config diff 并给出偏差提示。详见 `docs/build.md`。

## 验证

构建后先看 `HTFG Verify` 是否 PASS。它检查：

- `.config` 只有 `CONFIG_HTFG*` 相对原厂有差异（stock 模式；fast 模式跳过全量 diff）；
- fake `/proc/config.gz`（`config_data.gz`）与最终 Image 内嵌 IKCONFIG 都与 `baseline/stock.config.gz` 逐字节相同（stock 模式）；
- kheaders 报告 stock 的 thermal 符号集（无 `CONFIG_MTK_OPLUS_THERMAL`）；
- `UTS_RELEASE` 精确等于 `5.10.236-android12-9-o-g38e2c85bc7af`；
- `System.map` 有 `htfg_kernel_entry`、无 `ksu_`；
- `Image` 中有完整原厂 banner/编译器串/构建时间，且无 `runner@`、无 KSU/SUSFS/KPM/BakaSU；
- `/sys/kernel/kheaders.tar.xz` 的成员名/内容不含 HTFG；
- BTF 关闭。

产物是干净 AnyKernel3（`osm0sis/AnyKernel3` 模板，按 `ANYKERNEL3_SHA` 钉版本；`do.devicecheck=1`，只接受 `OP5911`/`PGZ110`；根目录含 `Image` 与 `htfg-build-info.txt`）。artifact 名为 `HTFG_Clean_oneplus_ace_race_v_<stock|fast>_9-o-g38e2c85bc7af`。zip 的 `tools/magiskboot`、`tools/magiskpolicy` 是 AnyKernel3 模板自带的打包工具，位于 `tools/` 子目录，不在 `Image` 内；紫罗兰“制作 GKI 镜像”只取其中的 `Image`，不会执行它们。刷机、真机 vendor 模块/App 回归和检测面记录见 `docs/verify.md`。

下载产物后先跑 `python tools/check_artifact.py <zip> --boot <boot-new.img> --stock-boot 原厂镜像/boot.img`；刷机前/后的完整检查清单见 `docs/构建后验证清单.md`。

## 刷机顺序（重要）

**先清 root，再刷 clean boot。** 刷入后设备没有 root，`/data/adb` 就再也清不掉了。建议：

1. 备份原厂 `boot.img` 和当前 root `boot.img`；
2. 在旧内核上停用/卸载 KSU 管理器、SUSFS 模块，清理 `/data/adb/ksu`、`/data/adb/modules`、`ksud`、`su` 包装、Magisk 残留；
3. 用紫罗兰“制作 GKI 镜像”把 clean AK3 的 `Image` 打进原厂 `boot.img`，解包核对 `sha256sum`；
4. 刷入 boot（A/B 两个 slot 都备份）；
5. 首启验证 `uname -r` / `/proc/version`、vendor 模块、App 拉取、触摸注入、Native Detector 基线。

## 检测面与边界

本项目解决的是“自编内核的明显 root 痕迹”：`runner@`、KSU/SUSFS/KPM 符号与 config、kheaders 泄漏、BTF、uid 0/2000 通道。它**不承诺整机不可检测**：

- `htfg_kernel_entry` / `htfg_*` 仍会出现在 `/proc/kallsyms`（本 ROM 普通 App/shell 读不了；root/特权可读）；
- Image 的 build ID / 哈希不可能与原厂一致；
- 公开 manifest 分支头（`05dd76e...`）不等于原厂内核提交 `38e2c85...`（后者未公开/未确认）；源码差异是残余风险，vendor 模块 CRC 必须在真机验证；
- bootloader / TEE / AVB / Play Integrity 由用户自有方案处理。

详见 `docs/detection-surface.md`。
