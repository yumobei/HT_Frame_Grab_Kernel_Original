# 设计说明（clean / no-root）

## 1. 范围

本仓库只负责**内核侧**：HTFG 驱动、`prctl` 入口、注入/校验脚本、独立构建 workflow 和原厂基线。App/reader/JNI 不在本仓库；它们继续使用旧项目 `UI_Fetch_KM` / `NEW_AI_JiaoBen`，协议 ABI 不变。

与旧 root 方案的区别：

- 不编译 KSU/SUSFS/KPM/BakaSU；不装管理器/模块；不保留 root 用户态；
- 身份门生产只认 **htai APK 签名证书**；uid 0/2000 仅在显式调试构建（`CONFIG_HTFG_ALLOW_TOOL_UID`）存在；
- 内核 Image 是“原厂基线 + HTFG 一个 bool 驱动”，不是“root 内核 + 隐藏”。

## 2. 运行时链路

1. App（htai 签名）经 `prctl(HTFG_PRCTL_MAGIC, op, ...)` 进 `htfg_kernel_entry`；
2. op 1 = ping；op 2/3/4 = `READ_MEM`/`FIND_PID`/`GET_VMAS`；op 5/6 = `TOUCH_DEV`/`TOUCH_SEND`；
3. 读内存走 present-only：`find_get_task_by_vpid` → `get_task_mm` → `mmap_read_lock` → `find_vma`/`follow_page(FOLL_GET|FOLL_FORCE)` → `kmap`/`memcpy` 到内核缓冲 → unlock → `copy_to_user` → `mmput`/`put_task_struct`；
4. 触摸注入：`class_for_each_device` 定位真实触摸屏 `input_dev`（持引用、用完 `put_device`），`input_event()` 注入其管线；不注册 handler、不新建设备、不建 proc/sysfs；
5. 失败统一 fail-closed：身份门未授权返回 `-EINVAL`（与 stock 未知 prctl option 不可区分）；冷验签投 `system_wq`，客户端短重试。

协议定义、结构体布局、字段偏移、App/reader 细节见旧项目：

- `../HT_Frame_Grab_内核直读UI数据方案.md`
- `../docs/第3步_M0.5校准.md` / `第3步_M1根定位.md` / `第3步_M2全键JSON.md`
- `../docs/第4步_所见帧.md`
- `../docs/第5步_内核触控注入.md`

本仓库不重复偏移表；内核侧只依赖 `include/linux/htfg.h` 的 ABI。

## 3. 身份门

```
if (!htfg_identity_allowed()) return -EINVAL;
```

`htfg_identity_allowed()`：

- 生产：只查 TTL 缓存；未命中投 `system_wq` 冷验签并返回 false；worker 用 system_server 凭据读 `/data/system/packages.list` → `/data/app` → `base.apk`，解析 v2 签名块第一张证书 SHA-256，与内置 htai 指纹比对；
- 调试：`#ifdef CONFIG_HTFG_ALLOW_TOOL_UID` 时允许 uid 0/2000；生产 defconfig 不设置，verify 断言不是 `y`；
- 文件打开一律 `__FMODE_NONOTIFY`；`packages.list`/`base.apk` 带 `O_NOATIME`；`/data/app` 及子目录经 `htfg_kopen_noatime()`，`-EPERM` 回退不带 `O_NOATIME`。

威胁模型：设备上无 root 的其他 App 无法伪造证书；持有 htai 私钥 == 可通过身份门（与读内存同级）。

## 4. 内核源码改动

`htfg/` 五个内核文件：

- `htfg.c`：驱动主体；`htfg_kernel_entry` noinline；present-only；触摸；身份门；零 printk；
- `htfg.h`：ABI 头（内核/用户态共用）；
- `Kconfig`：`CONFIG_HTFG`（bool，depends `INPUT`，select `CRYPTO_SHA256`，default n）+ `CONFIG_HTFG_ALLOW_TOOL_UID`（debug，default n）；
- `Makefile`：`obj-$(CONFIG_HTFG) += htfg.o`；
- `patch_sysc.py`：在 `kernel/sys.c` 的 `prctl()` 里、LSM 钩子之前插入 `htfg_kernel_entry` 调用；锚点失配即失败。

`htfg_apply.sh`：

1. 定位内核树（`HTFG_KERNEL_TREE` 或 `kernel_workspace/kernel_platform/common`）；
2. 复制 5 文件；挂 `drivers/Kconfig`/`drivers/Makefile`；
3. 向 `HTFG_DEFCONFIG` 追加 `CONFIG_HTFG=y`（stock=`mgk_64_k510_defconfig`，fast=`gki_defconfig`）；
4. `patch_sysc.py`；
5. fake `config_data`：只过滤 `^CONFIG_HTFG`/`^# CONFIG_HTFG`（覆盖 `HTFG_ALLOW_TOOL_UID`），不改真实 `.config`；
6. `gen_kheaders.sh`：删除 `include/linux/htfg.h`、`include/config/HTFG*`/`htfg*`，过滤 `autoconf.h`/`auto.conf`；
7. 计数自检（hook/mount/defconfig/fake marker/kheaders 各恰好一次），失败即红。

`htfg_verify.sh`：见 `docs/verify.md`；stock 模式对 `baseline/stock.config.gz` 做全量 diff，只允许 `CONFIG_HTFG*`。

## 5. 构建

见 `docs/build.md`。要点：

- workflow 不 clone Action-Build；manifest 以 vendored XML 放在 `manifest/`；
- stock：`scripts/build_kernel_direct.sh stock`（直接 make；片段 = `gki_defconfig` + `mgk_64_k510_defconfig` + `oplus6895.config`，与原厂 `kernel/build/oplus_build_kernel.sh unknown gki` 相同）；
- fast：直接 `make gki_defconfig`，只作显式 fallback；
- `KBUILD_BUILD_USER=build-user`、`HOST=build-host`、`VERSION=1`、`TIMESTAMP` 原厂值；`setlocalversion` 强制后缀；`mkcompile_h` 强制 `#1 SMP PREEMPT ...`；
- clean Image-only artifact，只放 `Image` + `htfg-build-info.txt`；由紫罗兰合并成 boot.img。

## 6. 安全/检测纪律

- 零 printk、零 proc/sysfs 条目、零新设备、零定时器；
- present-only，不 fault-in/换入；
- 不写目标进程内存/文件（触摸注入是唯一副作用原语）；
- 不把 uid 0/2000 写进生产；
- 不伪造 build ID/Image 哈希；
- 残余检测面见 `docs/detection-surface.md`，不承诺“整机不可检测”。

## 7. 版本/维护

- 协议/ABI 不变；`kernel/intree` 与 `htfg/` 是两份同源代码，本仓库是 clean 版真源；旧 root 项目仍保留自己的 `kernel/intree`，不要交叉覆盖。
- 换 ROM/OTA：重新提取 `boot.img` 基线，更新 `baseline/`、`manifest/`、`offsets.json`（reader 侧另行处理），重跑 `htfg_verify`。
- `CONFIG_HTFG_ALLOW_TOOL_UID` 只用于 bring-up；生产构建必须 false。
