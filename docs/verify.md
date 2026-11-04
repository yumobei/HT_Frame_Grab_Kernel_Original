# 验证与刷机

## 1. 构建后（CI）

`HTFG Verify` 必须全绿。它实际检查：

- `.config`：`CONFIG_HTFG=y`；无 `CONFIG_KSU/SUSFS/KPM/BBG`；生产无 `CONFIG_HTFG_ALLOW_TOOL_UID=y`；`INPUT`、`CRYPTO_SHA256`、`IKCONFIG`、`IKCONFIG_PROC`、`MODULES`、`MODVERSIONS`、`STACKPROTECTOR_STRONG` 为 `y`；`LTO_CLANG_FULL=y`、`LTO_CLANG_THIN` 非 `y`；`TMPFS_XATTR`/`TMPFS_POSIX_ACL` 非 `y`；`DEBUG_INFO_BTF` 非 `y`；`CC_VERSION_TEXT` 含原厂 clang 串。
- stock 模式：用 `baseline/stock.config.gz` 做**全量排序 diff**，只允许 `CONFIG_HTFG*` 行不同；任何其他差异直接失败。
- fake `/proc/config.gz`：`config_data.gz`/`config_data` 存在；无 KSU/SUSFS/KPM/BBG/HTFG 行；`IKCONFIG` 保留；`CHECKSUM` 不被误删。
- `UTS_RELEASE` 精确等于 `5.10.236-android12-9-o-g38e2c85bc7af`，无 `+`/`-dirty`。
- `System.map` 有 `htfg_kernel_entry`、无 `ksu_`；`drivers/htfg/htfg.o` 存在；`modules.builtin` 无 `htfg`。
- `Image` 字符串：完整原厂 banner（`build-user@build-host`）、原厂 clang 串、`#1 SMP PREEMPT Mon Jan 12 09:35:58 UTC 2026`；无 `runner@`；无 KSU/SUSFS/KPM/BakaSU 锚定串（不使用裸 `ksu`，避免 `CHECKSUM` 假阳性）。
- kheaders：`kheaders_data.tar.xz` 成员名不含 `htfg`（不区分大小写），内容不含 `CONFIG_HTFG`。
- BTF：`.config` 关闭。

fast 模式跳过全量 config diff，但关键项仍检查；日志会出现 fast warning。不要把 fast 的 PASS 当成 stock 等价。

## 2. 紫罗兰 / 刷机前

1. 下载 artifact；解压得到 AnyKernel3 文件树（含 `Image`）。
2. 用紫罗兰“制作 GKI 镜像”以**原厂 boot.img** 为底，把 `Image` 打进去，得到 `boot-new.img`。
3. 解包 `boot-new.img`，取 kernel 解压后的 `Image`：
   - `sha256sum` 必须等于 artifact 里的 `Image`；
   - `strings` 必须出现完整原厂 banner，且无 `runner@`、无 KSU/SUSFS/KPM/BakaSU；
   - 若紫罗兰工具对 AVB/verity 有重签/剥离选项，按你现有离线流程处理；不要在未核对的情况下刷入。
4. 备份原厂 boot 和当前 root boot；A/B 两个 slot 都备份。

> AVB 说明：stock boot 末尾有 AVB footer，boot 内也可能有 vbmeta 结构。不同离线工具对它的处理（重签/剥离/保留）不同。`HTFG Verify` 只保证 AK3 里的 `Image` 正确，**不保证**你的离线打包工具已经正确处理 AVB。刷前先确认工具的选项；如果首启失败，回滚原厂 boot。

## 3. 刷机前清 root（必须）

刷 clean boot 后设备没有 root，`/data/adb` 再也清不掉。顺序：

1. 旧内核上停用/卸载 KSU 管理器、SUSFS 模块；
2. 删除 `/data/adb/ksu`、`/data/adb/modules`（SUSFS 等）、`ksud`、`su` 包装、Magisk 残留；
3. `pm list packages | grep -iE 'ksu|sukisu|magisk'`、`ls -la /data/adb`、`which su` 复核；
4. 重启确认无 root，再刷 clean boot；
5. 如果拿不准残留，恢复出厂设置后再刷。

## 4. 首启（无 root 设备）

在没有 root 的情况下，`dmesg`、`/proc/kallsyms`、`/sys/kernel/kheaders.tar.xz` 可能不可读；这些主要靠构建期检查。设备侧优先做：

- `uname -r`、`cat /proc/version`：逐字匹配原厂 banner（含 `build-user@build-host`、`#1 SMP PREEMPT`、时间）。
- `cat /proc/config.gz | gzip -dc`（若 shell 可读）：无 HTFG/KSU/SUSFS/KPM/BBG；`IKCONFIG`、`INPUT`、`CRYPTO_SHA256` 等仍在。若不可读，用构建期 verify 的 fake config 结果。
- 功能回归：Wi-Fi/BT/相机/触摸/显示/传感器/蜂窝/音频；`lsmod` 看 vendor 模块是否加载。
- 若某 vendor 模块报 `disagrees about version` / `invalid module format` / `Unknown symbol`：说明源码/CRC 与 stock 不一致；回退原厂 boot，记录日志，再评估 manifest 钉提交或换源码基线。不要在 clean boot 上保留 root 去“修”。

## 5. App 回归

- 安装 htai 签名的 `UI_Fetch_KM`（或 `NEW_AI_JiaoBen`），生产版不再走 uid 0/2000；`htfgctl` shell 失败是预期。
- 跑 ⑤/⑥/触摸回归：`READ_MEM`/`FIND_PID`/`GET_VMAS`、`roots`、`dump`、`touch info/selftest/tap/swipe`。
- 帧输出应与旧 root 内核同场帧逐字段一致（ABI 未变）。
- 若先用 `DEBUG_TOOL_UID=true` 的调试内核 bring-up，验证完必须再刷 `DEBUG_TOOL_UID=false` 的生产内核；不要长期保留 uid 0/2000 通道。

## 6. 检测面记录

至少记录：

- Native Detector 各项（`Detected delayed syscall caused by Apatch/KSU` 应消失；`Detected Custom Kernel`、bootloader/TEE/Play Integrity 可能仍在）；
- `/proc/version`、`/proc/config.gz`、kheaders、BTF 的可读性/内容；
- `uname -a`、`/proc/cmdline`；
- 任何新出现的 vendor 模块错误。

残余检测面是预期内的，见 `docs/detection-surface.md`；不要为了“全绿”去伪造 Image 哈希或 `/sys/kernel/notes`。

## 7. 回滚

- 失败/不开机：恢复备份的原厂 boot（两个 slot）。
- 刷 clean boot 后无法清 `/data/adb`：恢复出厂设置或先恢复 root boot 清理，再重新刷 clean boot。
- 保留 `boot-new.img` 与 artifact 的 `sha256`，便于复现。
