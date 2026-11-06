# 原厂基线

本文件记录从 `原厂镜像/boot.img` 提取的原厂数据，以及这些数据与当前 Action-Build 自编内核的差异。所有数据只读提取，不修改 boot.img。

## 1. 原厂完整 banner

```
Linux version 5.10.236-android12-9-o-g38e2c85bc7af (build-user@build-host) (Android (7284624, based on r416183b) clang version 12.0.5 (https://android.googlesource.com/toolchain/llvm-project c935d99d7cf2016289302412d708641d52d2f7ee), LLD 12.0.5 (/buildbot/src/android/llvm-toolchain/out/llvm-project/lld c935d99d7cf2016289302412d708641d52d2f7ee)) #1 SMP PREEMPT Mon Jan 12 09:35:58 UTC 2026
```

逐字副本在 `baseline/stock_version.txt`。

boot.img 结构（供复核）：

- 64 MiB，Android bootimg v4，`header_size=1584`，kernel 位于 4096 偏移；
- kernel gzip 原始 20,510,966 字节，解压 49,185,772 字节；
- 内嵌 config：`IKCFG_ST` @ 27,477,280，`IKCFG_ED` @ 27,527,409，gzip payload 50,121 字节，解压 232,546 字节（8,276 行）。

## 2. 原厂关键 config

完整文件在 `baseline/stock.config.gz`（gzip 解压后是 `/proc/config.gz` 的形态）。

| 项 | 原厂值 |
|---|---|
| `CONFIG_LOCALVERSION` / `CONFIG_LOCALVERSION_AUTO` | `""` / `y` |
| `CONFIG_IKCONFIG` / `CONFIG_IKCONFIG_PROC` | `y` / `y` |
| `CONFIG_IKHEADERS` | `y` |
| `CONFIG_KALLSYMS` / `CONFIG_KALLSYMS_ALL` | `y` / `y` |
| `CONFIG_CRYPTO_SHA256` | `y` |
| `CONFIG_MODULES` / `CONFIG_MODVERSIONS` | `y` / `y` |
| `CONFIG_INPUT` | `y` |
| `CONFIG_LTO_CLANG` / `_FULL` / `_THIN` | `y` / `y` / `n` |
| `CONFIG_TMPFS_XATTR` / `_POSIX_ACL` | `n` / `n` |
| `CONFIG_STACKPROTECTOR` / `_STRONG` | `y` / `y` |
| `CONFIG_SHADOW_CALL_STACK` / `CONFIG_CFI_CLANG` | `y` / `y` |
| `CONFIG_KASAN` / `_HW_TAGS` / `CONFIG_KFENCE` / `CONFIG_UBSAN` | `y` / `y` / `y` / `y` |
| `CONFIG_DEBUG_INFO_BTF` | `n` |
| `CONFIG_CC_VERSION_TEXT` | `Android (7284624, based on r416183b) clang version 12.0.5 ...` |
| `CONFIG_KSU` / `CONFIG_SUSFS` / `CONFIG_KPM` / `CONFIG_BBG` / `CONFIG_HTFG` | 均不存在 |

## 3. 当前 Action-Build 自编内核的非原厂点

当前 root 内核虽然把 `SUFFIX` 和 `BUILD_TIME` 伪装成原厂值，但至少还有：

1. `linux_banner` 的 `(runner@runnervm...)`：GitHub Actions runner 的 `KBUILD_BUILD_USER/HOST`，未设置原厂的 `build-user@build-host`。
2. `CONFIG_LTO_CLANG_THIN=y`：Action-Build 的 FAST 路径强制 thin LTO；原厂是 full LTO。
3. `CONFIG_TMPFS_XATTR=y` / `CONFIG_TMPFS_POSIX_ACL=y`：`Add Configuration Settings` 无条件追加。
4. `KCFLAGS=-fno-stack-protector`：FAST 路径关闭栈保护，但原厂 `CONFIG_STACKPROTECTOR_STRONG=y`。
5. `CONFIG_KPM=y`（`KPM=N/A` 时仍会写）、`CONFIG_BBG=y`（`LSM_BBG` 默认 true）、SUSFS（`SUSFS_META=""` 默认开启）、KSU 系列。
6. `/sys/kernel/kheaders.tar.xz` 中会出现 `include/linux/htfg.h` / `CONFIG_HTFG`（旧项目未处理）。
7. `/data/app` 目录 open 未带 `O_NOATIME`（旧项目只给 `packages.list`/`base.apk` 加了）。

本项目逐项处理；`htfg_verify.sh` 对 1–4 和 5 的 config 项做硬校验（stock 模式），对 kheaders/BTF 做产物校验，对 7 做源码修正。

## 4. 版本字符串的构造

原厂 release 由三部分组成：

```
5.10.236                     KERNELVERSION（Makefile）
-android12                   KMI 的 Android release（build.config 的 BRANCH=android12-5.10）
-9-o-g38e2c85bc7af          SUFFIX（OPLUS 的 -o infix + 原厂源码 commit）
```

本项目 `Custom Kernel Suffix` 步骤修改 `scripts/setlocalversion`，把 scm 段强制为 `-${KANDROID_VERSION}-${SUFFIX}`，并去掉 `-dirty`；`Custom BUILD_TIME` 设置：

- `KBUILD_BUILD_USER=build-user`
- `KBUILD_BUILD_HOST=build-host`
- `KBUILD_BUILD_VERSION=1`
- `KBUILD_BUILD_TIMESTAMP=Mon Jan 12 09:35:58 UTC 2026`

同时 patch `scripts/mkcompile_h`，强制 `UTS_VERSION="#1 SMP PREEMPT <BUILD_TIME>"`，避免 `CONFIG_FLAGS` 或 locale 造成差异。

## 5. 源码基线与 manifest 的诚实说明

`manifest/oneplus_ace_race_v.xml` 来自 `Numbersf/kernel_manifest` 的 `oneplus/mt6895` 分支（提交 `b4ad3a17...`）。原因是 `OnePlusOSS/kernel_manifest` 的公开分支没有这个设备文件（已逐分支检查，均 404）；manifest 内容本身只是 OnePlusOSS/CLO 的 project 列表，放在项目内可避免运行时依赖作者仓库。

需要明确的残余事实：

- 公开分支 `android_kernel_5.10_oneplus_mt6895` 的 `oneplus/mt6895_v_15.0.0_ace_race` 头是 `05dd76e8b6e4969b7bcda3edc53a98ea441d90f5`（2026-11-05 查询），已写入 `manifest/pinned-sources.txt` 的 `KERNEL_SHA`；workflow 在 `repo sync` 后校验/checkout 该提交，漂移会明确失败；
- 原厂 `g38e2c85bc7af` 对应的源码提交在公开 refs 中不可见/未确认；
- 因此本项目能保证的是 **banner/config/公开面** 对齐（报告层 `/proc/config.gz`、kheaders 已与 stock 逐字节/逐符号一致），不能保证源码逐提交等于原厂。vendor 模块 vermagic/CRC 必须在真机首启验证；若失败，回退原厂 boot，再审查 pin 的源码差异。
