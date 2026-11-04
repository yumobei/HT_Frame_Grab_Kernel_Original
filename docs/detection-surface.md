# 检测面

目标不是“任何手段都检测不到”，而是把**自编内核 + root 方案**留下的明显痕迹清掉，并把无法消除的残余登记清楚。

## 1. 公开面逐项

| 面 | 原厂 | clean 内核 | 处理 |
|---|---|---|---|
| `/proc/version` / `uname` | `5.10.236-android12-9-o-g38e2c85bc7af (build-user@build-host) ... #1 SMP PREEMPT Mon Jan 12 09:35:58 UTC 2026` | 同左 | `KBUILD_BUILD_USER/HOST/VERSION/TIMESTAMP` + `setlocalversion` + `mkcompile_h` |
| `linux_banner` 的 user@host | `build-user@build-host` | 同左 | 不再出现 `runner@...` |
| `/proc/config.gz` | 无 KSU/SUSFS/KPM/BBG/HTFG | 同左 | fake `config_data` 只过滤 `^CONFIG_HTFG`/`^# CONFIG_HTFG` |
| `/sys/kernel/kheaders.tar.xz` | 无 HTFG | 无 HTFG | `gen_kheaders.sh` 删除 `include/linux/htfg.h`、`include/config/HTFG*`，过滤 `autoconf.h`/`auto.conf` |
| `/sys/kernel/btf/vmlinux` | 无（BTF 关闭） | 无 | 不启用 `CONFIG_DEBUG_INFO_BTF` |
| `/proc/kallsyms` | 无 `ksu_`/`susfs`/`kpm`；有原厂符号 | 有 `htfg_kernel_entry`/`htfg_*` | 本 ROM 普通 App/shell 读不了；root/特权可读，属残余 |
| `System.map` / `vmlinux` | 无 HTFG | 有 `htfg_kernel_entry` | 只存在于构建产物/特权读取面 |
| 内核模块 ABI | 原厂 CRC | 依赖源码/config 一致性 | 首启看 vendor 模块；失败回滚 |
| build ID / Image SHA-256 | 原厂值 | 必然不同 | 不可消除；不要伪造 |
| bootloader / TEE / AVB / Play Integrity | 原厂 | 未改 | 用户自有方案；本项目不处理 |

## 2. 最近两个 HTFG 版本的检测结论

2026-10-19 的改动是**减少**痕迹：

- 目标内存读取改为 present-only（`follow_page(FOLL_GET|FOLL_FORCE)`，不 fault-in/换入），目标 RSS / `min_flt` / `maj_flt` / swap 不回增；
- 冷验签投 `system_wq` 异步执行，不在调用者线程 `override_creds`/文件 I/O，去掉调用者线程 1.7–5.1 ms 的离群和 system_server 凭据暴露；
- 未授权统一 `-EINVAL`，与 stock 未知 prctl option 不可区分，去掉 `-EPERM` 指纹。

仍在外围、本 clean 项目处理/登记的：

- `/data/app`/子目录 open 补 `O_NOATIME`（`htfg_kopen_noatime`，`-EPERM` 时回退不带，避免验签被目录 atime 保护打断）；`packages.list`/`base.apk` 原有 `O_NOATIME` 保留；
- `CONFIG_IKHEADERS` 泄漏（kheaders 补丁 + 产物校验）；
- `ksu_htfg_prctl` 符号名（改为 `htfg_kernel_entry`，源码不再含 `ksu` 字面量）；
- 原厂 BTF 本就关闭（不启用）；
- `CONFIG_CRYPTO_SHA256=m` 会触发模块自动加载（dmesg）；clean 构建要求 `y`（Kconfig 的 `HTFG` 会 `select CRYPTO_SHA256`，verify 断言）。

## 3. 容易误判的点

- **不要用裸 `grep -i ksu`**：`CHECKSUM` 包含子串 `KSU`，会把正常 Image 判红。verify 使用 `kernelsu|bakasu|susfs|ksu_htfg|ksu_susfs|htfg_prctl|config_ksu|config_kpm` 加词边界锚定。
- `CONFIG_NETFILTER_XT_TARGET_CHECKSUM` 是 fake config 过滤器的“未误删”哨兵：只在 `^CONFIG_HTFG`/`^# CONFIG_HTFG` 前缀上过滤，不能把 `CHECKSUM` 一起删掉。
- kheaders 的 `include/config/HTFG` 可能是**无 `.h` 后缀**的 Kconfig 空文件；补丁同时删除 `HTFG*`/`htfg*`，verify 检查 tar 成员名和内容，而不是只看源码 marker。
- `htfg_kernel_entry` 在 `System.map` 中出现是**预期**的；不能以“存在 htfg 符号”判红。App/shell 读不了 kallsyms 是 ROM 策略，不是本项目引入。
- `CONFIG_KALLSYMS_ALL=y` 是原厂配置，不要为了隐藏 `htfg` 去关闭它——那会造成 config 差异，反而更可疑。

## 4. 不可消除的残余

1. **源码基线**：公开 manifest 分支头不等于原厂 `38e2c85...`；即使 banner/config 完全一致，代码级差异仍可能存在。vendor 模块 CRC/vermagic 是首要风险。
2. **Image build ID/hash**：任何改动都无法与原厂一致；普通 App 读不到，root/特权可读。
3. **`htfg_*` 符号**：本 ROM App/shell 读不了 `/proc/kallsyms`；root/特权可读。若威胁模型包含“设备上已有 root 的检测器”，这一项无解（除非改符号名/裁 KALLSYMS，但那会引入新的 config 差异）。
4. **bootloader/TEE/AVB/Play Integrity**：不在本项目范围。
5. **fast 模式的 config 偏差**：fast 不应用 OPLUS fragments，`/proc/config.gz` 会与原厂不同；只能作为工程 fallback，不能当 stock 证明。

## 5. 不做的事

- 不伪造 `/sys/kernel/notes`/build ID/Image 哈希；
- 不关闭 `CONFIG_KALLSYMS_ALL`、不删除 `System.map` 来“隐藏”符号；
- 不保留 uid 0/2000 生产通道；
- 不在 clean boot 上保留 root 去“修” vendor 模块问题；
- 不把 `CHECKSUM` 误删/误报。
