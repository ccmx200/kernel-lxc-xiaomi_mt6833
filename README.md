# Evergo / MT6833 Kernel

ReSukiSU + KVM + BBRv2 + zstd/lz4 + Binder 优化内核。

> **作者**：璀璨梦星 · cuicanmx · <https://github.com/ccmx200>
>
> 本项目在社区成果之上整合而成，**并非全部原创**。主要移植来源为
> [`seriaTvT/kernel_mt6893`](https://github.com/seriaTvT/kernel_mt6893)（BBRv2、LZ4/zstd、KVM vGIC/ITS、Binder）；
> 各部分来源见 [移植与出处](#移植与出处) 与 [致谢](#致谢)。

## 基本信息

- 设备：xiaomi MT6833 / evergo
- 内核版本：Linux 4.14.356
- 当前版本号：
  ```text
  4.14.356-Evergo-KVM-cuicanmx-v1.0
  # uname -r -> 4.14.356-Evergo-KVM-cuicanmx-v1.0
  ```
- 默认 defconfig：
  ```text
  arch/arm64/configs/evergo_defconfig
  ```
- 编译脚本：
  ```text
  build.sh
  ```

## 已集成功能

### ReSukiSU

- 源码内置：
  ```text
  ReSukiSU/
  ```
- 内核入口：
  ```text
  drivers/kernelsu -> ../ReSukiSU/kernel
  ```
- Hook 模式：
  ```text
  CONFIG_KSU=y
  CONFIG_KSU_MANUAL_HOOK=y
  # CONFIG_KSU_TRACEPOINT_HOOK is not set
  # CONFIG_KSU_SUSFS is not set
  ```

### KVM / EL2 / vGIC / ITS

已开启：

```text
CONFIG_KVM=y
CONFIG_VIRTUALIZATION=y
CONFIG_ARM64_VHE=y
```

已关闭 LTO：

```text
# CONFIG_LTO_CLANG is not set
CONFIG_LTO_NONE=y
```

并恢复标准：

```c
void *val = &sym;
```

已移植 vGIC/ITS 相关修复：

- ITS outer cacheability 默认改为 `SameAsInner`
- 移除过严的 stage-2 read permission fault 检查
- 增加 `KVM_DEV_ARM_ITS_CTRL_RESET`
- 修复保存 ITE 时 NULL collection 导致内核崩溃
- VCPU ioctl 使用 `task_pid(current)`

#### ISV=0 场景支持（NISV + 外部数据中止注入）

4.14 主线的 stage-2 MMIO 路径在 `ESR_EL2.ISV == 0` 时无法解码故障指令，
只能打印一行错误后返回 `-ENOSYS`，vCPU 随即变成 `paused (internal-error)`。
上游的解法是把问题上报给用户态（VMM），本内核已回移这套机制：

- `KVM_EXIT_ARM_NISV`（= 28）与 `struct kvm_run.arm_nisv { esr_iss, fault_ipa }`
- `KVM_CAP_ARM_NISV_TO_USER`（= 177）：内核把 ISV=0 的 MMIO 退出上报用户态
- `KVM_CAP_ARM_INJECT_EXT_DABT`（= 178）：用户态通过 `KVM_SET_VCPU_EVENTS`
  注入外部数据中止，配合 `struct kvm_vcpu_events`（该结构本内核原本不存在，
  为本次回移一并补齐，布局与上游 5.10 一致，`ext_dabt_pending` 落在原有
  填充字节内，`sizeof` 与所有字段偏移均未改变）

涉及文件：

```text
include/uapi/linux/kvm.h
arch/arm64/include/uapi/asm/kvm.h
arch/arm64/include/asm/kvm_host.h
arch/arm64/include/asm/kvm_emulate.h
arch/arm64/kvm/guest.c
arch/arm64/kvm/reset.c
virt/kvm/arm/arm.c
virt/kvm/arm/mmio.c
```

已验证（运行时）：

```text
KVM_CAP_VCPU_EVENTS         ( 41) = 1
KVM_CAP_ARM_NISV_TO_USER    (177) = 1
KVM_CAP_ARM_INJECT_EXT_DABT (178) = 1
```

#### 重要限制：UEFI 固件写 NVRAM 会卡死（详见 [docs/KVM.md](docs/KVM.md)）

QEMU 的 NISV 处理**不做指令解码**，它只是把外部数据中止注入 guest，
因此无法代替真正的指令模拟。而 ARM 架构规定：**带 writeback 的
load/store（如后索引 `ldr x0, [x1], #4`）和 `LDXR/STXR` 这类指令
永远不会置 ISV 位**。QEMU 维护者的立场是"guest 不应该对 MMIO 用这类指令"。

实际后果：标准 EDK2/AAVMF 固件在写 pflash NVRAM 变量时恰好使用这类指令，
于是触发 ISV=0，最终 vCPU 进入活锁（CPU 满载但毫无进展）。

**解决办法是换一个不写 NVRAM 的 EDK2 固件**（例如 Limbo 项目随 APK 分发的
`edk2_qemu_aarch64_nonvram.fd`）。换用后 UEFI 可在本内核的 KVM 下正常启动，
且 `dmesg` 中 NISV abort 计数为 0。

若不便更换固件，另一条可行路径是绕过固件，直接用 `-kernel` 引导内核
（需要 gzip 或裸 `Image` 格式；PE32+ 的 EFI stub 内核不被 QEMU 接受）。

### BBRv2

已移植并设为默认：

```text
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_BBR2=y
CONFIG_DEFAULT_BBR2=y
CONFIG_DEFAULT_TCP_CONG="bbr2"
CONFIG_NET_SCH_DEFAULT=y
CONFIG_NET_SCH_FQ=y
CONFIG_DEFAULT_FQ=y
```

### zstd / lz4 / zram

已升级：

```text
zstd 1.5.7
lz4  1.10.0
```

配置：

```text
CONFIG_CRYPTO_ZSTD=y
CONFIG_ZSTD_COMMON=y
CONFIG_ZSTD_COMPRESS=y
CONFIG_ZSTD_DECOMPRESS=y
CONFIG_CRYPTO_LZ4=y
CONFIG_CRYPTO_LZ4HC=y
CONFIG_LZ4_COMPRESS=y
CONFIG_LZ4HC_COMPRESS=y
CONFIG_LZ4_DECOMPRESS=y
```

zram 默认压缩算法：

```c
static const char *default_compressor = "zstd";
```

### Binder

已移植：

- Oneway 垃圾消息检测
- 位图描述符查找

### cgroup 稳定性

已加入 `cgroup_file_open/release/write/poll` NULL 检查，避免 cgroup 文件释放 alignment fault 导致随机重启。

### THP

已关闭：

```text
# CONFIG_TRANSPARENT_HUGEPAGE is not set
```

原因：该 4.14 THP 回移在 MIUI mem reclaim 场景可能触发 `reclaim_pte_range` 崩溃。


## 用虚拟机（KVM / UEFI）

内核带 KVM，可以在这台手机上跑**硬件加速**的完整虚拟机，装了 UEFI 固件，
能装系统、能多开。

### 安装（一条命令）

```bash
curl -fsSLk https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager/kvm-vm.sh | bash -s -- install
```

详细的用法、参数、排错见 **[`kvm_manager/README.md`](kvm_manager/README.md)**。

### 创建与启动

```bash
ckvm create ubuntu26                     # 自动下载 Ubuntu 26.04 镜像并建盘
ckvm start ubuntu26
ssh u0@127.0.0.1 -p 8023                 # 密码 1
```

可以调参数：

```bash
ckvm create win --cpus 4 --mem 1536 --disk 50 --rel 24.04 --port 8030
```

### 多开

每个虚拟机有独立目录、独立磁盘、独立端口，互不影响：

```bash
ckvm create a
ckvm create b
ckvm start a && ckvm start b
ckvm list
```

```text
  NAME      STATE    CPUS   MEM      DISK    PORT   SSH
  a         running  8      2048     50G     8023   ssh u0@127.0.0.1 -p 8023
  b         running  8      2048     50G     8024   ssh u0@127.0.0.1 -p 8024
```

### 命令行一览

```bash
ckvm list                    # 所有虚拟机及状态
ckvm status <name>           # 详细状态 + 串口末尾
ckvm console <name>          # 实时看串口
ckvm stop|restart <name>
ckvm rm <name> [-f]          # 删除
ckvm config [name]           # 看配置
ckvm cache                   # 镜像缓存（多开只下载一次）
ckvm edit <name>             # 改配置
```

### systemd 管理

```bash
ckvm enable ubuntu26         # 启用并启动，且开机自启
systemctl status ckvm@ubuntu26
systemctl stop   ckvm@ubuntu26
ckvm disable ubuntu26
```

### 镜像源（国内加速）

默认已经配好国内源，改脚本顶部的变量即可切换：

```bash
MIRROR_IMAGE_LIST="https://mirror.nju.edu.cn/ubuntu-cloud-images https://cloud-images.ubuntu.com"
MIRROR_APT="https://mirrors.ustc.edu.cn/ubuntu-ports"
```

镜像按顺序回退，第一个失败自动试下一个。`MIRROR_APT` 会写进 guest 的
cloud-init，装完系统后 apt 直接走 USTC。

> USTC 的 cloud-images 目录只镜像了 amd64，arm64 会 403，所以镜像走 NJU。

### 配置文件

全局：脚本顶部。单个虚拟机：`/var/lib/ckvm/<name>/vm.conf`

```ini
CPUS=8            # vCPU 数
MEM=2048          # 内存 MiB
DISK_GB=50
PORT=8023
CPUSET=0-7        # 可用的物理核，随便配
VM_USER=u0
VM_PASS=1
```

### 四个坑（都已在脚本里处理）

1. ~~必须绑核~~ **已修复，不再需要**。这台机器是 big.LITTLE（6 个 A55 +
   2 个 A76），KVM 在不同核上暴露的 ID 寄存器不同，早期会随机报
   `Failed to put registers after init`。内核现在按 VM 快照这些寄存器，
   跨簇不再失败，CPU 掩码可以随便配。详见
   [`kvm_manager/TECHNICAL.md`](kvm_manager/TECHNICAL.md) 第 12 章。
2. **固件必须是不写 NVRAM 的那份**。普通 EDK2 一写变量存储就会让虚拟机
   卡死，这是 ARM 架构限制（写 MMIO 的指令不置 `ISV` 位，KVM 无法解码）。
3. **NVRAM 每次要刷新**。脚本每次 `start` 都从模板拷一份干净的，
   否则 GRUB 会卡在加载后不动。
4. **固件不能自动下载**。它只打包在 Limbo 的 APK 里，不在任何 git 仓库。
   `ckvm install` 会自动在常见位置找；找不到会打印从 Termux 拷贝的命令。

想要图形界面自己加 `-device virtio-gpu-pci` 配 VNC；默认只有串口。

## 编译

```sh
cd /root/kernel-lxc_xiaomi_mtk810_mt6833-resukisu
./build.sh --no-menuconfig --no-update
```

快速检查配置：

```sh
./build.sh --check --no-menuconfig --no-update
```

## 输出

```text
out/arch/arm64/boot/Image.gz
ReSukiSU-Evergo-KVM-cuicanmx-v1.0-YYYYMMDD-HHMM.zip   (AnyKernel3 刷机包)
```

## 刷入

请自行使用 fastboot / magiskboot 等方式刷入对应 boot 镜像。

刷机前务必备份原 boot。

---

## 免责声明

**请在使用前完整阅读本节。刷写内核或分区表属于高风险操作。**

1. **按原样提供（AS IS）**
   本项目及其全部产物（内核镜像、刷机包、脚本、文档）按"原样"提供，
   **不附带任何形式的明示或暗示担保**，包括但不限于对适销性、特定用途
   适用性和不侵权的担保。

2. **风险自负**
   刷写自定义内核、修改 GPT 分区表、执行 `fastboot flash` 等操作**可能导致
   设备变砖、无法开机、丢失全部数据、失去保修**。使用者须自行承担全部风险。
   作者与贡献者**不对任何直接、间接、附带或后果性损害承担责任**，包括数据
   丢失、设备损坏、收入或利润损失。

3. **前置要求**
   本项目面向**已解锁引导程序、已获得 root 权限**的设备。使用前请确认你
   了解如何进入 fastboot / recovery、如何备份分区，并**务必保留原厂镜像**。

4. **不隶属声明**
   本项目与**小米（Xiaomi）、联发科（MediaTek）、Ubuntu/Canonical、
   Google 及其他商标持有者没有任何隶属、赞助或背书关系**。所有商标归其
   各自所有者所有。

5. **禁止商业用途**
   未经作者书面许可，**不得将本项目或其衍生作品用于商业目的**，包括但不限于
   预装、捆绑销售、以付费服务形式分发。

6. **禁止非法用途**
   不得将本项目用于任何违反当地法律法规的用途。使用者须自行确保其使用行为
   合法合规。

7. **无技术支持义务**
   作者没有提供技术支持、修复缺陷或持续维护的义务。Issue 与 PR 可能不被
   响应。

8. **保留修改权利**
   作者保留随时修改、暂停或终止本项目的权利，恕不另行通知。

9. **OTA 与系统更新**
   系统 OTA 可能还原被修改的分区（例如 GPT），更新后相关修改会失效，
   需要重新执行。升级系统前请确认你知道后果。

10. **继续使用即表示接受**
    下载、编译、刷写或以任何方式使用本项目，即表示你已阅读、理解并同意
    上述全部条款。**若不同意，请立即停止使用并删除相关文件。**

---

## 移植与出处

本项目整合了多项社区成果与上游内核代码。以下按**代码与提交记录中可确认**的
信息标注来源。

### 主要移植来源

**BBRv2、LZ4 / zstd、KVM vGIC/ITS 修复，以及 Binder 的 oneway
垃圾消息检测与位图描述符查找，都迁移自
[`seriaTvT/kernel_mt6893`](https://github.com/seriaTvT/kernel_mt6893)。**

对应提交：

```text
b5c5fce5b  migrate BBRv2 + LZ4/zstd and KVM vGIC/ITS fixes from kernel_mt6893
9eae96319  binder: migrate oneway spam detection and bitmap descriptor lookup
d377ff482  wip: migrate bbr/fq/zram lz4 from chopin      (更早的一次尝试)
```

Binder 那两项在来源仓库里的原始提交是：

```text
af4a2bac2e6c  binder: tell userspace to dump current backtrace when detected oneway spamming
7655a874c90c  binder: use bitmap for faster descriptor lookup
```

逐项核对的依据（与本机 `/root/kernel_mt6893` 工作树对比）：

| 组件 | 与该仓库的关系 |
|---|---|
| `net/ipv4/tcp_bbr2.c` | 内容**完全相同** |
| `lib/lz4/` | 内容**完全相同** |
| `lib/zstd/` | 内容**完全相同** |
| `drivers/android/dbitmap.h` | 内容**完全相同** |
| `include/uapi/linux/android/binder.h` | 内容**完全相同** |
| `drivers/android/binder.c` | 仅 19 行差异：本仓库少了无关的 `binder: signal epoll threads of self-work`，多了 `BINDER_WATCHDOG` 块 |
| KVM vGIC/ITS 修复 | 由 `b5c5fce5b` 一并迁移 |

### 各组件来源一览

| 组件 | 来源 | 可确认依据 |
|---|---|---|
| BBRv2 拥塞控制 | `seriaTvT/kernel_mt6893`（其自身实现源自 Linux 内核上游） | `tcp_bbr2.c` 与该仓库逐字节相同；文件头保留原作者注释与 `TODO(ncardwell)` |
| lz4（1.10.0） | `seriaTvT/kernel_mt6893`（上游为 lz4 项目） | `lib/lz4/lz4.h` 的 `LZ4_VERSION_MAJOR/MINOR/RELEASE` = 1/10/0；目录与该仓库相同 |
| zstd（1.5.7） | `seriaTvT/kernel_mt6893`（上游为 zstd 项目） | `include/linux/zstd_lib.h` 的 `ZSTD_VERSION_*` = 1/5/7；目录与该仓库相同 |
| Binder Oneway 垃圾消息检测<br>位图描述符查找 | **`seriaTvT/kernel_mt6893`** —— 对应其 `af4a2bac2e6c binder: tell userspace to dump current backtrace when detected oneway spamming` 与 `7655a874c90c binder: use bitmap for faster descriptor lookup` | 本仓库的 `9eae96319 binder: migrate oneway spam detection and bitmap descriptor lookup`；`BR_ONEWAY_SPAM_SUSPECT` / `BINDER_WORK_TRANSACTION_ONEWAY_SPAM_SUSPECT` / `dbitmap` 出现次数两边一致（3 / 6 / 18） |
| KVM vGIC / ITS 修复 | 由 `b5c5fce5b` 迁自 `kernel_mt6893` | 提交说明 |
| ReSukiSU（root 方案） | ReSukiSU 上游项目，以源码形式内置于 `ReSukiSU/`，经 `drivers/kernelsu` 符号链接接入内核 | 目录内自带 `LICENSE` / `CONTRIBUTING.md` / `SECURITY.md` |
| KVM NISV / 外部数据中止注入 | Linux 内核上游 5.10 引入的机制，回移至本 4.14 树 | 见 [docs/KVM.md](docs/KVM.md) 的出处列表 |
| 不写 NVRAM 的 EDK2 固件 | Limbo for Tensor 项目（`wasdwasd0105/limbo_tensor`）随 APK 分发 | 见 `kvm_manager/TECHNICAL.md` 第 4 节 |
| 禁用 GenieZone 的工具链 | `jsbsbxjxh66/mtk-soc-disable-geniezone`（MIT） | 见 `kvm_manager/TECHNICAL.md` 第 11 节 |

> **诚实说明**：本仓库由多方成果整合而成。若你是某项代码的原作者而此处未
> 列出或标注有误，请提 Issue，会尽快更正。

---

## 致谢

- **[`seriaTvT/kernel_mt6893`](https://github.com/seriaTvT/kernel_mt6893)**
  —— **本项目的主要移植来源**。BBRv2、LZ4 / zstd、KVM vGIC/ITS 修复以及
  Binder 的 oneway 垃圾消息检测与位图描述符查找也都来自这里。特别感谢。
- **ReSukiSU** 及其贡献者 —— root 方案
- **Neal Cardwell** 与 BBRv2 的贡献者 —— 拥塞控制
- **jsbsbxjxh66**（酷安）—— `mtk-soc-disable-geniezone`，禁用 GenieZone
  并释放 EL2 的工具链
- **Limbo for Tensor**（`wasdwasd0105`）—— 提供不写 NVRAM 的 EDK2 固件
- **Linux 内核社区** —— 本仓库大量代码回移自上游
- 以及所有在公开渠道分享 MTK 平台经验的人

---

## License

内核源码遵循其原始 **GPL-2.0** 许可证。

ReSukiSU、Linux 内核回移代码、zstd、lz4、EDK2 固件、
`mtk-soc-disable-geniezone` 等分别遵循**各自的原始许可证**：
使用、修改或再分发这些部分时，请一并遵守其许可条款。

`mtk-soc-disable-geniezone` 为 MIT；Limbo 的固件请遵循其项目声明。

本仓库自有的脚本（`kvm_manager/kvm-vm.sh`，即 `ckvm`）采用 **GPL-2.0**，
与内核部分一致。
