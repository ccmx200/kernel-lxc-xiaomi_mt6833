# ckvm 技术文档

**作者**：璀璨梦星 · cuicanmx · <https://github.com/ccmx200>

本文解释 **为什么** ckvm 要这么写。每条结论都给出出处或本机实测数据。
引用到的外部项目（Linux 内核、QEMU、ARM 规范、Limbo、EDK2、
`mtk-soc-disable-geniezone` 等）在第 10 章「参考出处」逐一列出。

> 本工具按原样提供，不附带任何担保。刷写内核或分区表可能导致设备变砖或
> 数据丢失，风险自负。完整免责条款见仓库根目录 README。
>
> **许可**：ckvm 采用 **GPL-2.0**，与所在内核仓库一致。它下载或驱动的
> 外部组件（Ubuntu 镜像、EDK2 固件、`mtk-soc-disable-geniezone` 等）各有
> 其许可，见 kvm_manager/README.md 的「作者与许可」一节。

本文面向需要排查问题、移植到别的机型、或想改这套东西的人。

用户向的用法说明在 [README.md](README.md)。

---

## 目录

1. [目标环境与特权模型](#1-目标环境与特权模型)
2. [核心障碍：ESR_EL2.ISV == 0](#2-核心障碍esr_el2isv--0)
3. [内核回移](#3-内核回移)
4. [固件：为什么必须是不写 NVRAM 的 EDK2](#4-固件为什么必须是不写-nvram-的-edk2)
5. [big.LITTLE 与 CPU 使用](#5-biglittle-与-cpu-使用)
6. [网络：user 与 tap 两种模式](#6-网络user-与-tap-两种模式)
7. [下载子系统](#7-下载子系统)
8. [systemd 与安装流程](#8-systemd-与安装流程)
9. [实测数据集](#9-实测数据集)
10. [参考出处](#10-参考出处)
11. [在红米 Note 11 5G（MT6833）上禁用 GenieZone 并释放 EL2](#11-在红米-note-11-5gmt6833上禁用-geniezone-并释放-el2)
12. [物理核使用：从"必须绑核"到"随便配"](#12-物理核使用从必须绑核到随便配) ← **核心章节**
13. [自检](#13-自检)
14. [镜像缓存](#14-镜像缓存)
15. [附：本机原始测量记录](#附本机原始测量记录)

---

## 1. 目标环境与特权模型

### 1.1 硬件

| 项目 | 值 | 来源 |
|---|---|---|
| SoC | MediaTek MT6833（天玑 810） | 设备 |
| CPU | 6× Cortex-A55 `0xd05` @2.0GHz + 2× Cortex-A76 `0xd0b` @2.4GHz | `/proc/cpuinfo`，本机实测 |
| 内核可见 CPU | 8（`0-7`） | `nproc --all` |
| 页大小 | 4KiB | `CONFIG_ARM64_4K_PAGES=y` |
| 内核 | 4.14.356（厂商分支） | `uname -r` |

本机实测的 CPU 拓扑：

```text
$ awk -F: '/^CPU part/{gsub(/ /,"",$2); print $2}' /proc/cpuinfo | sort | uniq -c
      6 0xd05
      2 0xd0b
```

### 1.2 特权级

厂商固件在移交内核时**已占据 EL2**，但没有实现任何功能。因此本内核以
**nVHE**（non-Virtualized Host Extension）方式运行，即内核自身跑在 EL2：

```text
CONFIG_VIRTUALIZATION=y
CONFIG_ARM64_VHE=y
CONFIG_KVM=y
```

**重要推论**：Pixel pKVM 使用的 `kvm-arm.mode=protected` / `nvhe` 开关在
本机型上**不适用**，因为那是给"内核在 EL1、hypervisor 在 EL2"的架构用的。
本机型的内核和 KVM 都在 EL2。详见
[Linux 内核 KVM ARM 文档](https://www.kernel.org/doc/html/latest/virt/kvm/arm/index.html)。

### 1.3 容器

KVM 需要 `/dev/kvm`。Android 上 Termux 属于 `untrusted_app` 域，**拿不到
`/dev/kvm`**（实测 `Permission denied`）。因此必须通过 droidspaces 这类
容器/命名空间获得访问权限。

本机容器是 Debian 13，**systemd 作为 PID 1**：

```text
$ cat /proc/1/comm
systemd
$ systemctl is-system-running
running
```

这是 ckvm 能用 `ckvm@.service` 的前提。

---

## 2. 核心障碍：ESR_EL2.ISV == 0

这是理解所有其他问题的关键。

### 2.1 什么是 ISV

当 guest 访问 stage-2 页表之外的地址（即 MMIO），会触发 data abort 陷入
EL2。`ESR_EL2` 记录原因，其中 **ISV（Instruction Syndrome Valid，bit 24）**
表示**后续的 ISS 字段是否包含对故障指令的有效译码**（读/写方向、访问宽度、
目标寄存器）。

只有 ISV=1 时，KVM 才能知道"guest 想干什么"，从而把访问转交给用户态模拟。

### 2.2 什么时候 ISV 一定是 0

`ESR_EL2.ISV` 的定义在 **ARM Architecture Reference Manual for A-profile
architecture, DDI 0487**，章节 *D13.2.37 ESR_EL2, Exception Syndrome Register
(EL2)*：

> ISV, bit [24] — Instruction Syndrome Valid. Indicates whether the syndrome
> information in ISS[23:14] is valid.
> ...
> **For a Data Abort exception, this bit is 0 for all faults reported in
> AArch64 state except for those described in the syndromes table.**

而"syndromes table"（*D13.2.37 的 Data Abort ISS encoding*）列出的**会置
ISV=1 的情况只有单寄存器、无 writeback、非 exclusive 的 load/store**。以下
**必然 ISV=0**：

- 带 writeback 的 load/store（例如后索引 `ldr x0, [x1], #4`）
- `LDP` / `STP`（成对寄存器）
- `LDXR` / `STXR` 等 exclusive 访问
- 各类原子指令（`LDADD`、`CAS` 等）

### 2.3 内核侧的后果

4.14 的 `virt/kvm/arm/mmio.c` 在 ISV=0 时无法译码，只能：

```c
} else {
        kvm_err("load/store instruction decoding not implemented\n");
        return -ENOSYS;          /* vCPU -> paused (internal-error) */
}
```

用户看到的是 QEMU 报：

```text
qemu-system-aarch64: kvm run failed Function not implemented
```

上游内核文档明确记录了这个返回值：

> **ENOSYS** — data abort outside memslots with no syndrome info and
> **KVM_CAP_ARM_NISV_TO_USER not enabled** (arm64)
>
> — [The Definitive KVM API Documentation, §4.10 KVM_RUN](https://www.kernel.org/doc/html/latest/virt/kvm/api.html#kvm-run)

### 2.4 本机实测现场

用 QEMU 加日志抓到的原始数据（EDK2 写 pflash NVRAM 变量区时）：

```text
esr=920000c7  ec=24 (DABT lower EL)  isv=0  dfsc=07
pc=0000000000004670  pstate=EL1h
far=000000004007c000  ipa=9000
```

`0x4007c000` 落在 QEMU `virt` 机型 pflash 变量存储的 64MiB 块内偏移
`0x7c000` 处。

### 2.5 QEMU 维护者的立场

QEMU 邮件列表上就此问题的官方答复（qemu-arm，arm64 KVM MMIO 与 ISV=0）：

> "Don't do this -- KVM doesn't support it. For access to MMIO, stick to
> instructions which will set the ISV bit in ESR_EL1."
>
> — Peter Maydell（QEMU ARM 维护者）

**结论：这不是 4.14 的 bug，是架构层面的既有约束。** 内核无法凭空补出
ISV=0 时缺失的译码信息。

---

## 3. 内核回移

上游的解法**不是**在内核里解码指令，而是**把事件上报给用户态**（VMM），
由 VMM 决定怎么办。这套机制在 Linux 5.10 进入主线，4.14 没有，所以需要回移。

### 3.1 两个 API

**`KVM_EXIT_ARM_NISV`**（值为 28）配合 `KVM_CAP_ARM_NISV_TO_USER`（177）：
内核遇到 ISV=0 时不再返回 `-ENOSYS`，而是退出到用户态。

```c
/* virt/kvm/arm/mmio.c（回移后） */
if (!kvm_vcpu_dabt_isvalid(vcpu)) {
        if (vcpu->kvm->arch.return_nisv_io_abort_to_user) {
                run->exit_reason = KVM_EXIT_ARM_NISV;
                run->arm_nisv.esr_iss =
                        kvm_vcpu_dabt_iss_nisv_sanitized(vcpu);
                run->arm_nisv.fault_ipa = fault_ipa;
                return 0;
        }
        /* 未启用则维持原有行为 */
        kvm_err("load/store instruction decoding not implemented\n");
        return -ENOSYS;
}
```

**`KVM_CAP_ARM_INJECT_EXT_DABT`**（178）：允许用户态把**外部数据中止**
注入 guest。上游内核文档：

> If the guest performed an access to I/O memory which could not be handled by
> userspace, for example because of missing instruction syndrome decode
> information or because there is no device mapped at the accessed IPA, then
> userspace can ask the kernel to inject an external abort using the address
> from the exiting fault on the VCPU. It is a programming error to set
> `ext_dabt_pending` after an exit which was not either `KVM_EXIT_MMIO`,
> `KVM_EXIT_ARM_NISV`, or `KVM_EXIT_ARM_LDST64B`. This feature is only
> available if the system supports `KVM_CAP_ARM_INJECT_EXT_DABT`.
>
> — [The Definitive KVM API Documentation, §4.32 KVM_SET_VCPU_EVENTS](https://www.kernel.org/doc/html/latest/virt/kvm/api.html#kvm-set-vcpu-events)

上游相关提交（供对照）：

- `KVM: arm64: Force injection of a data abort on NISV MMIO exit`
  — commit `3b467b16582c077f57fab244cf0801ecea7914b6`
- 原始补丁系列标题：*"Allow reporting non-ISV data aborts to userspace"*
  （kvmarm 邮件列表，2019-11）

### 3.2 涉及的文件（8 个）

| 文件 | 改动 |
|---|---|
| `include/uapi/linux/kvm.h` | `KVM_EXIT_ARM_NISV=28`、`arm_nisv` 载荷、能力 177/178 |
| `arch/arm64/include/uapi/asm/kvm.h` | `__KVM_HAVE_VCPU_EVENTS`、`struct kvm_vcpu_events` |
| `arch/arm64/include/asm/kvm_host.h` | `return_nisv_io_abort_to_user` 标志 |
| `arch/arm64/include/asm/kvm_emulate.h` | `kvm_vcpu_dabt_iss_nisv_sanitized()` |
| `arch/arm64/kvm/guest.c` | `__kvm_arm_vcpu_{get,set}_events()` |
| `arch/arm64/kvm/reset.c` | 上报三个能力 |
| `virt/kvm/arm/arm.c` | `KVM_ENABLE_CAP`、`KVM_GET/SET_VCPU_EVENTS` ioctl |
| `virt/kvm/arm/mmio.c` | ISV=0 改走 `KVM_EXIT_ARM_NISV` |

### 3.3 ABI 对齐

`struct kvm_vcpu_events` 在 4.14 中**不存在**（5.10 才随本机制进主线），
本次按上游布局新增：

```c
/* 上游定义，见 KVM API 文档 §4.31 */
struct kvm_vcpu_events {
        struct {
                __u8 serror_pending;
                __u8 serror_has_esr;
                __u8 ext_dabt_pending;
                /* Align it to 8 bytes */
                __u8 pad[5];
                __u64 serror_esr;
        } exception;
        __u32 reserved[12];
};
```

实际验证（真实编译器，与 QEMU 头文件对比）：

```text
size = 64        exception = 16
serror_esr @ 8   reserved @ 16
ext_dabt_pending @ 2
```

`ext_dabt_pending` 落在原有填充内，因此 `sizeof` 与所有字段偏移**均与上游
一致**，QEMU 不会读错位。`struct kvm_run` 也逐字段比对过：`sizeof = 2352`，
`offsetof(arm_nisv.fault_ipa) = 40`。

### 3.4 效果与局限（重要）

| | 回移前 | 回移后 |
|---|---|---|
| vCPU 状态 | `paused (internal-error)`，cpu 0.2s | 持续运行，cpu 29s / 25 次退出 |
| 结果 | 立即死 | **活锁**（CPU 满载、无进展） |

**这套回移解决不了固件问题。** 原因：注入外部数据中止只是告诉 guest
"这个地址有问题"，**无法代替真正的访问模拟**；固件收到 abort 后只能重试，
于是变成活锁。

QEMU 侧的逻辑（`target/arm/kvm.c`）：

```c
if (cap_has_inject_ext_dabt) {
    events.exception.ext_dabt_pending = 1;
    kvm_vcpu_ioctl(CPU(cpu), KVM_SET_VCPU_EVENTS, &events);
    return 0;
} else {
    error_report("KVM unable to emulate faulting instruction.");
}
return -1;      /* 无该能力时 QEMU 直接放弃 */
```

所以在回移**之前**，QEMU 遇到 NISV 会直接退出（`KVM unable to emulate
faulting instruction`）；回移**之后**它会尝试注入，但 guest 无法恢复。

**真正的解法是换固件**（见下一节）。

### 3.5 运行时验证

```text
$ 通过 KVM_CHECK_EXTENSION 读取
KVM_CAP_VCPU_EVENTS         ( 41) = 1
KVM_CAP_ARM_NISV_TO_USER    (177) = 1
KVM_CAP_ARM_INJECT_EXT_DABT (178) = 1     <- 回移前为 0
```

---

## 4. 固件：为什么必须是不写 NVRAM 的 EDK2

### 4.1 因果链

```text
EDK2 启动
  └─ 初始化 NVRAM 变量存储（pflash）
       └─ 使用带 writeback 的 store 写 pflash
            └─ 该指令必然 ISV=0（见 §2.2）
                 └─ KVM 无法译码
                      └─ 回移前：vCPU paused (internal-error)
                         回移后：注入外部数据中止 -> 固件重试 -> 活锁
```

### 4.2 解法

使用**不写 NVRAM**的 EDK2 构建，使这条路径根本不发生。

现成可用的一份来自 Limbo 项目（`wasdwasd0105/limbo_tensor`），其 README
说明两种固件的区别：

> **Enable**: Loads a full version UEFI firmware that can save EFI variables
> to NVRAM pflash. Requires unlock pKVM.
> **Disable**: Loads a modified version that bypasses NVRAM write.

该固件**只随 APK 分发**（`assets/roms/edk2/`），仓库里没有——`roms` 在
`.gitignore` 中：

```text
$ grep -n roms .gitignore
57:roms
```

因此 ckvm **无法自动下载它**，只能在已知位置寻找（见 README）。

本仓库 `kvm_manager/` 下附带两份，校验值：

| 文件 | 大小 | SHA-256 |
|---|---|---|
| `edk2_qemu_aarch64_nonvram.fd` | 67108864 | `becc95919db490cd819df8ec89f7d51eae1d146b50d44f7a73b6e01905cd8cc4` |
| `edk2_vars.fd` | 67108864 | `b3b855c5a80310168051164986855692d1bdb06e67619856177965cd87c6774f` |

### 4.3 验证

换上不写 NVRAM 的固件后：

```text
UEFI 正常启动到 shell / 正常引导系统
dmesg 中 NISV abort 计数 = 0
```

那次访问**根本不再发生**，而不是被"处理"了。

### 4.4 NVRAM 变量存储仍需清理

即便用 nonvram 固件，pflash 的变量存储文件（`uefi-vars.fd`）若残留旧状态，
仍可能让 GRUB 在加载后卡住。ckvm 每次 `start` 都从模板拷一份干净的副本。

---

## 5. big.LITTLE 与 CPU 使用

这台机器是 big.LITTLE（6×A55 + 2×A76），两种核心暴露的 ID 寄存器不同，
早期会让 QEMU 随机启动失败。

**完整分析、修复实现和实测见 [§12](#12-物理核使用从必须绑核到随便配)。**
这一节只保留 QEMU 侧的出处和一句结论。

### 5.1 结论

**早期**必须把虚拟机钉死在单一种核心上；**现在不需要了** —— 内核按 VM
快照了这两类寄存器，CPU 掩码可以任意配置（实测 21/21，见 §12.7）。

### 5.2 QEMU 侧的出处

这条报错来自 QEMU 的 `write_list_to_kvmstate()`。该函数在补丁
*"arm/kvm: report registers we failed to set"*（Cornelia Huck，2025-09）中
被加入了更详细的诊断，补丁说明原文：

> If we fail migration because of a mismatch of some registers between source
> and destination, the error message is not very informative:
> `qemu-system-aarch64: Failed to put registers after init: Invalid argument`
> At least try to give the user a hint which registers had a problem

补丁代码注释给出了失败的两个原因：

> We might fail for **"unknown register"** and also for **"you tried to set a
> register which is constant with a different value from what it actually
> contains"**.
>
> — [PATCH v3] arm/kvm: report registers we failed to set
> <https://patchew.org/QEMU/20250911154159.158046-1-cohuck@redhat.com/>

第二种情况正是本机型的问题：

```text
1. QEMU 建临时 vCPU，探测宿主 CPU 特性（此时可能调度到 A76）
2. QEMU 把这些值写入真正的 vCPU（此时可能调度到 A55）
3. A55 的 ID 寄存器值与 A76 不同
4. KVM 判定"这是常量寄存器且值不一致" -> EINVAL
```

本机型两种核心的 ID 寄存器视图**确实不同**（见 §1.1 的 `CPU part` 实测）。

---

## 6. 网络：user 与 tap 两种模式

### 6.1 容器网络现状（本机实测）

```text
lo       127.0.0.1/8
docker0  172.17.0.1/16
eth0     172.28.80.95/16     <- 容器地址
default via 172.28.0.1 dev eth0
```

容器**没有**手机在局域网上的地址（如 `192.168.111.x`），因为它位于
droidspaces 创建的独立网络命名空间内。实测：

```text
ping 192.168.111.1     -> 可达（经 172.28.0.1 NAT）
ping 8.8.8.8           -> 可达
ip -4 -o addr show     -> 只有 172.28.80.95，无 192.168.111.x
```

### 6.2 user 模式

QEMU 内建 user-mode 网络栈（slirp），通过 `hostfwd` 暴露端口：

```text
-netdev user,id=n0,hostfwd=tcp:0.0.0.0:<host>-:<guest>
```

特点：

- 无需 tap、无需额外内核模块、无需宿主机配合
- guest 的 **22** 映射到该 guest 分配的 `PORT`，避免多开冲突
- 其他端口默认同号映射，支持 `host:guest` 形式
- **无需任何特权**，任何环境都能用

### 6.3 host（tap）模式

需要有 `ip` 命令和 `/dev/net/tun`。本机实测两者都具备：

```text
/dev/net/tun  crw-rw-rw-  (10, 200)
ip            /usr/sbin/ip
ip tuntap add dev tap-test mode tap   -> 成功
```

ckvm 建立：

```text
tap ckvm-<name>     172.28.100.1/24
guest 静态地址      172.28.100.2/24，网关 172.28.100.1
sysctl net.ipv4.ip_forward = 1
iptables -t nat  -A POSTROUTING -s 172.28.100.0/24 -o eth0 -j MASQUERADE
iptables         -I FORWARD -i ckvm-<name> -j ACCEPT
```

guest 侧通过 cloud-init 的 `network-config`（netplan v2）配置静态地址，
因为 tap 链路上**没有 DHCP 服务器**。

实测结果：

```text
ip neigh:  172.28.100.2 lladdr 52:54:00:12:34:56 REACHABLE
ping:      2 packets transmitted, 2 received, 0% packet loss
ssh:       172.28.100.2:22 -> SSH-2.0-OpenSSH_10.2p1 Ubuntu-2ubuntu3.6
```

`stop` / `rm` 会删除 tap 并清理 iptables 规则（实测清理干净）。

### 6.4 为什么 host 模式也不是"真正的局域网"

`172.28.100.0/24` 处在**容器的网络命名空间内**。局域网上其他机器无法直接
路由到它。要让 guest 出现在手机所在网段，必须改动网络命名空间的拓扑：

**方案 a（简单）**：用 user 模式，在 Android 宿主侧把端口转进容器。

**方案 b（彻底）**：在 Android 宿主侧建网桥：

```bash
ip link add br-ckvm type bridge
ip link set eth0 master br-ckvm        # 容器的 veth 对端
ip link set br-ckvm up
```

Android 的 netd/iptables 规则可能与手工桥接冲突，需要按机型调整。

### 6.5 端口占用

容器自身 sshd 在 **22**，Android 宿主 sshd 在 `172.28.0.1:22`。
ckvm 启动前会检查 host 端口占用并给出提示，避免与它们冲突。
host 模式下 guest 自己跑 sshd（`172.28.100.2:22`），不经过任何端口转发。

---

## 7. 下载子系统

### 7.1 为什么用 aria2c

`aria2` 支持多连接分段下载（`-x` 并发连接数 / `-s` 分段数）与断点续传，
对 945MB 的 cloud image 提升明显。本机实测（NJU 镜像）：

```text
aria2c -x16 -s16 -k1M ... -> 约 10 MB/s
```

ckvm 的调用形式：

```bash
aria2c -x16 -s16 -k1M -c \
       --console-log-level=warn --summary-interval=0 \
       --show-console-readout=false --allow-overwrite=true \
       --file-allocation=none \
       -d <dir> -o <name> <url>
```

关键点：

- `--show-console-readout=false` + `--summary-interval=0`：抑制 aria2 自带
  输出，让 ckvm 自己的进度条独占终端
- `--file-allocation=none`：避免在慢速存储上预分配
- `-c`：断点续传，配合 `*.aria2` 控制文件

aria2 不在时自动回退 `curl`，进度条行为一致。安装时可由 `install` 自动
通过 apt 安装 aria2（可用 `CKVM_NO_APT=1` 禁用）。

### 7.2 进度条

- **只有在 TTY 上才输出**（`[ -t 1 ]`），管道/日志里保持干净
- 颜色受 `TERM != dumb` 与 `NO_COLOR` 控制
- 动画帧用 Braille 点阵 `⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`，进度条用 `█` / `░`
- 每 0.4 秒刷新一次，用 `\r\033[K` 原地重绘

实测渲染（去 ANSI 后）：

```text
  ⠋ ░░░░░░░░░░░░░░░░░░░░░░░░   0%  0
  ⠹ ░░░░░░░░░░░░░░░░░░░░░░░░   0%  1.0M
  ⠼ ░░░░░░░░░░░░░░░░░░░░░░░░   2%  25M
  ⠦ █░░░░░░░░░░░░░░░░░░░░░░░   6%  55M
```

### 7.2.1 百分比为什么不能用文件大小算

第一版的进度条出现过 **12514%** 这种数字。原因值得记下来：

aria2c 用多连接分段下载时是**稀疏写入** —— 它会在文件的不同偏移处并发写入，
所以 `stat -c%s` 拿到的文件大小会**跳到远超实际已下载字节数**的值。用它当
分母、再用"已下载"当分子，结果完全失真：

```text
  ⠙ ███████████████████████
12514%  Ubuntu 26.04 arm64  876M      <-- 分母被算成了极小的值
```

正确做法：

1. **分母从 HTTP 头取**，而不是从正在写的文件取：

   ```bash
   total=$(curl -sSLkI --max-time 25 "$url" | \
           awk 'BEGIN{IGNORECASE=1}/^content-length:/{gsub(/\r/,"");print $2}' | tail -1)
   ```

2. **强制上限**，任何情况下不超过 100%：

   ```bash
   [ "$cur" -gt "$tot" ] && cur="$tot"
   pct=$(( cur * 100 / tot ))
   ```

3. 取不到 `Content-Length` 时**只显示字节数，不显示百分比**，避免给出假信息。

实测（8 MB 文件，本地限速源，PTY 下采样 33 次）：

```text
  ⠙ ######..................  26%  2097152/8000000
  ⠼ #########...............  39%  3145728/8000000
  ⠧ ############............  52%  4194304/8000000
  ⠏ ######################## 100%  8000000/8000000

sampled 33 percentages
min=0  max=100
VERDICT: PASS - never exceeded 100%
```

另一个相关陷阱：**进度条只在 TTY 上输出**（`[ -t 1 ]`）。用
`cmd > file` 或在没有 PTY 的 SSH 会话里跑，是看不到进度条的 —— 这本身是
正确行为（避免污染日志），但会让"我明明跑了却没看到进度"变成误报。

---

### 7.2.2 慢步骤的反馈

创建流程里有两类"看起来卡住"的步骤：

| 步骤 | 耗时 | 原来 | 现在 |
|---|---|---|---|
| `check_release` | 每个镜像一次 HEAD | 静默 | `spin` 转圈 |
| `qemu-img convert` | 裸镜像可能几十秒 | **完全静默** | `spin` 转圈 |
| `qemu-img resize` | 秒级到十几秒 | **完全静默** | `spin` 转圈 |
| `cloud-localds` | 秒级 | 静默 | `spin` 转圈 |
| 镜像下载 | 几十秒到几分钟 | 有进度条 | 进度条 + 百分比 + 字节 |

`spin` 是个通用包装：把命令放后台跑，前台画转圈，失败时把输出的最后几行打出来，
而不是静默失败。

```bash
spin "扩容到 ${DISK_GB}G" qemu-img resize "$img" "${DISK_GB}G"
```

非 TTY 环境下自动退化为普通文字输出（`say` + 直接执行），日志保持干净。

`_progress` 内部对 `/dev/null` 做了保护 —— `spin` 用 `/dev/null` 表示"没有可测量
的进度"，此时只显示转圈和标签，不做 `stat`。

一个测试上的注意点：在脚本里单独验证 `spin` 时，`_progress` 会因为 awk 提取不完整
而报 `command not found`。实际运行时没有问题 —— `_progress` 定义在
`download_url` 内部，而下载总是先于这些步骤执行。

---

### 7.3 镜像源

| 用途 | 源 | 说明 |
|---|---|---|
| 系统镜像 | `mirror.nju.edu.cn/ubuntu-cloud-images` | 有 arm64，实测 200 |
| 系统镜像（回退） | `cloud-images.ubuntu.com` | 官方 |
| apt | `mirrors.ustc.edu.cn/ubuntu-ports` | 写进 guest cloud-init |

**实测注意**：USTC 的 `ubuntu-cloud-images` 目录**只镜像了 amd64**
（`releases/<ver>/` 下只有 `-amd64` 与 `-amd64v3` 文件），arm64 请求返回
**403**。故系统镜像默认走 NJU。

### 7.4 脚本自身的下载源

ckvm 是 Python 程序，**没法在自己还没跑起来的时候安装自己**，所以由一个极小的
POSIX sh 包装（`install2.sh`）先取 `ckvm.py`，校验，再执行 `install`。

#### 为什么路径是 `<branch>` 而不是 `refs/heads/<branch>`

一开始按 `refs/heads/resukisu/...` 写，全部失败。从设备逐条实测：

```text
raw.githubusercontent.com/<repo>/resukisu/...            200
raw.githubusercontent.com/<repo>/refs/heads/resukisu/... 500
```

**短格式可用，`refs/heads/` 形式被 GitHub 的 raw 主机拒绝。** 之前的记录
（认为 `refs/heads/` 才新鲜）是早期在另一个镜像上测的，缓存行为已经变了，
那份结论对当前环境是错的。

#### 哪些加速可用

从设备实测（同一个文件，逐个请求）：

| 地址 | 结果 |
|---|---|
| `ghproxy.net/https://raw.githubusercontent.com/...` | **200** ✅ |
| `gh-proxy.com/https://raw.githubusercontent.com/...` | **200** ✅ |
| 直连 `raw.githubusercontent.com` | 连接重置 |
| `git.yylx.win/raw.githubusercontent.com/...` | **404** ❌ |
| `ghfast.top` / `raw.gitmirror.com` / `cdn.jsdelivr.net` | 失败 |
| `hub.gitmirror.com` / `ghproxy.cc` / `raw.kkgithub.com` | 失败 |

**`git.yylx.win` 只代理 `git clone`，不代理 raw 文件**（`git ls-remote` 和
clone 都通，raw 一律 404）。所以基于 clone 的安装方案在这里同样不可行。

#### 缓存是按路径的，绕不过

`install.sh` 这个路径被国内镜像缓存到了旧版本。加查询参数、换用另一个加速，
拿到的都是同一份旧文件 —— 说明缓存键是路径，客户端没有别的杠杆。
解决办法是**换一个新文件名**（`install2.sh`），并把 `install.sh` 留成转发存根，
这样已经写进文档的旧地址在缓存过期后仍然能用。

`install2.sh` 里带 `INSTALLER_VERSION`，一眼能看出是不是旧副本。

#### 安装脚本的选择顺序

`ghproxy.net → gh-proxy.com → 直连`，每个下载都用
`python3 -c "import ast; ast.parse(...)"` 校验过才算成功，
并用第一个通过的。想固定一个：

```bash
sh install2.sh --from https://ghproxy.net/
```

失败会明确报错并给出可手动执行的命令，不会静默换源。

### 7.4.1 为什么要校验下载

包装脚本会把镜像返回的**任何**字节交给 `python3` 执行，所以必须验。

```sh
looks_valid() {
    [ -s "$TMP" ] || return 1
    head -1 "$TMP" | grep -q python || return 1
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TMP"
}
```

三道：非空、首行是 Python、**能整体解析**。第三道是关键 —— 被截断的响应
往往前几行看着正常，只有解析整个文件才会暴露。校验不过就换下一个源，
全部失败才报错。

早期用 shell 写时有另一套标记（`#!/bin/bash`、`CKVM_BUILD=`、特征函数名、
`bash -n`）。改成 Python 后这些不再适用，改为 `ast.parse`，它同时覆盖了
「是不是 Python」和「完不完整」两件事。

### 7.5 安装的原子性

两个真实 bug，都已修复：

1. **`$0` 判定**：脚本经 `curl | bash` 管道安装时 `$0` 是 `bash`，早期版本
   把它当成"本地文件"从而跳过下载，导致 GitHub 不可达时**什么也装不上**。
   现在会识别 `bash`/`sh` 并强制重新下载。

2. **失败不破坏现状**：此前安装失败会把已有的 `ckvm` 删掉。现在先下载到
   临时文件，**成功后才覆盖**。实测：

   ```text
   $ ls -la /usr/local/bin/ckvm      -> 40645 bytes（完好）
   $ cat script | bash -s -- install  -> ERROR: could not download ...
   $ ckvm list                        -> 仍然正常工作
   ```

3. 顺带修掉 `mv` 的 SELinux 问题：`/tmp` 可能是独立挂载点、带自己的
   `security.selinux` 标签，跨文件系统 `mv` 会报
   `setting attribute 'security.selinux': Permission denied`。改用 `cat`
   写入目标文件规避。

---

## 8. systemd 与安装流程

### 8.1 模板单元

```ini
# /etc/systemd/system/ckvm@.service
[Unit]
Description=ckvm KVM guest %i
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/ckvm start %i
ExecStop=/usr/local/bin/ckvm stop %i
PIDFile=/var/lib/ckvm/%i/qemu.pid
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

要点：

- `%i` = 实例名（guest 名字），一个单元文件服务所有 guest
- `Type=forking` + `PIDFile`：`ckvm start` 后台派生 QEMU 并写 pid 文件
- `Restart=on-failure`：guest 异常退出会自动重启

实测：

```text
$ ckvm enable test2
  systemd: ckvm@test2.service enabled and started
$ systemctl is-active  ckvm@test2.service   -> active
$ systemctl is-enabled ckvm@test2.service   -> enabled
```

### 8.2 目录布局

```text
/var/lib/ckvm/<name>/
├── vm.conf          # 该 guest 的配置
├── disk.qcow2       # 系统盘
├── uefi-code.fd     # 固件副本
├── uefi-vars.fd     # NVRAM（每次 start 从模板刷新）
├── user-data        # cloud-init
├── meta-data
├── network-config   # 仅 host 模式
├── seed.img
├── serial.log
└── qemu.pid
```

固件模板在 `/usr/local/share/ckvm/firmware/`，与 guest 实例分离，便于批量
刷新。

### 8.3 cloud-init

`user-data` 生成账号，并把 apt 源指向 `MIRROR_APT`：

```yaml
#cloud-config
users:
  - name: <VM_USER>
    groups: [sudo, adm]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: <openssl passwd -6 生成的哈希>
ssh_pwauth: true
growpart: { mode: auto, devices: ['/'] }
resize_rootfs: true
apt:
  primary:  [{ arches: [default], uri: "<MIRROR_APT>" }]
  security: [{ arches: [default], uri: "<MIRROR_APT>" }]
```

`growpart` + `resize_rootfs` 让 guest 首次启动自动把根分区扩到虚拟磁盘
容量（实测：3.5GiB 镜像 resize 到 50G 后，guest 内 `/dev/vda1` 为 48G）。

---

### 8.4 串口输出的清洗

UEFI 与 GRUB 会在串口上输出终端控制序列，直接转储到用户终端会污染显示：

```text
\033P+q6E616D65\033\\          DCS（UEFI 元数据）
\033]3008;start=...\033\\       OSC（systemd 会话信息）
\033[!p  \033[?7h  \033[1G        私有模式设置、光标移动
\033[6n                          光标位置查询
```

清洗要求**保留 SGR 颜色、删除其余序列**。实现上用 Python 而非 sed/awk，
因为下面的坑都实际踩过：

| 工具 | 问题 |
|---|---|
| GNU sed 4.9 | **没有 `-u`**（无法流式处理实时串口），BRE **无法表达** CSI 参数区间 |
| awk (gawk 5.2) | 手写状态机在私有模式序列 `ESC[!p` 上会误判 |
| Python `re` | 可以精确表达：CSI 参数字节 `0x30–0x3F`，终字节 `0x40–0x7E` |

实际规则：

```python
SGR  = rb"\x1b\[[0-9;]*m"                        # 保留
DROP = re.compile(
    rb"\x1b\[[0-9:;<=>?!]*[a-ln-zA-LN-Z]"        # 非 SGR 的 CSI
    rb"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"    # OSC
    rb"|\x1bP[^\x1b]*\x1b\\"                    # DCS
    rb"|\x1b[()][A-Z0-9]|\x1b[=>]|\x1b")       # 字符集 / 键区 / 裸 ESC
```

**关键细节**：`[a-ln-zA-LN-Z]` 故意排除 `m`。SGR 以 `m` 结尾，必须单独匹配
并原样保留，否则会被当作普通 CSI 一起删掉。这是本次实现中唯一真正的逻辑
难点，验证如下：

```text
[OK] "  \x1b[0;32m  OK  \x1b[0m done\n"               颜色完整保留
[OK] "\x1b[!p\x1b[?7h\x1b[1G\x1b[0J\x1b[6n\x1b]3008;…\x1b[0mtext\n"
                                          只剩 \x1b[0mtext
[OK] "\x1bP+q6E616D65\x1b\\after-dcs\n"            只剩 after-dcs
[OK] "\x1b[?25h\x1b[2J\x1b[Hplain\n"               只剩 plain
[OK] "\x1b[38;5;196mRED\x1b[0m\n"                   256 色保留
```

`ckvm console` 的三种行为：

| 调用 | 行为 |
|---|---|
| `console <名字>` | **只显示新输出**（默认，避免重放 bootlog） |
| `console <名字> -n N` | 先重放最后 N 行 |
| `console <名字> -a` | 重放全部 |

用 `tail -c +N -F`（大写 F）保证日志文件被重建时仍能跟上。

---

### 8.5 交互式商店与版本目录

`ckvm create` 不带参数并且 stdin/stdout 都是终端时进入交互模式：

```bash
if [ $# -eq 0 ] && [ "$IS_TTY" = 1 ]; then interactive=1; fi
IS_TTY=0; [ -t 0 ] && [ -t 1 ] && IS_TTY=1
```

**给了名字或任何选项就走命令模式**，两条路径共用同一套校验与创建逻辑。

可选的发行版目录内置在脚本里（`CATALOGUE`），格式 `版本|代号|LTS|大小`：

```text
22.04 jammy LTS 673M      24.04 noble LTS 592M      26.04 resolute LTS 902M
22.10 kinetic   716M      24.10 oracular  584M
23.04 lunar     688M      25.04 plucky    680M
23.10 mantic    684M      25.10 questing  843M
```

代号与 LTS 状态取自 Ubuntu 官方的
[meta-release](https://changelogs.ubuntu.com/meta-release)；镜像大小来自各镜像站
的 `Content-Length`，本机实测：

```text
22.04 .. 26.04 全部 9 个版本
  南京大学镜像 mirror.nju.edu.cn     全部可用
  官方 cloud-images.ubuntu.com       全部可用
  USTC ubuntu-cloud-images           仅 amd64，arm64 返回 403
```

**关键实现点：创建前先验证镜像可下。** 用一次 `HEAD` 请求读
`Content-Length` 判断，而不是假定存在：

```bash
check_release() {
    for url in $(image_urls "$rel"); do
        len=$(curl -sSLkI --max-time 20 "$url" | \
              awk 'BEGIN{IGNORECASE=1}/^content-length:/{gsub(/\r/,"");print $2}' | tail -1)
        case "$len" in ''|*[!0-9]*) continue ;; esac   # 404/403 时没有该头
        CC_URL="$url"; CC_LEN="$len"; return 0
    done
    return 1
}
```

失败时直接报错并列出可用版本，**不会先建目录再卡在下载上**。

实测（交互选 24.04，PTY 下）：

```text
选择：Ubuntu 24.04 noble (LTS)  ~592M
  可用：Ubuntu 24.04 (noble, LTS)  592M
已创建 'srv24'  (Ubuntu 24.04, 8025 端口, 4 vCPU, 1536 MiB, 30G)
```

启动后确认是真的 24.04，不是 26.04 换个标签：

```text
guest 内：  Ubuntu 24.04.5 LTS
kernel:    6.8.0-142-generic          (26.04 是 7.0.0-38)
ssh banner: SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.19
```

**测试提醒**：验证交互模式必须给 stdin 一个真 PTY。`printf ... | cmd` 会让
`[ -t 0 ]` 为假，脚本正确地走了非交互路径 —— 这曾让我误判"选择没生效"。
用 `script -q -c 'cmd' /dev/null` 可以模拟真实终端：

```bash
printf '5\nsrv24\n4\n1536\n30\nuser\n22\n' | script -q -c 'ckvm create' /dev/null
```

### 8.6 账号与密码

默认账号不再写死 `u0`。交互模式会问「登录账号」，可以填 `root` 或任意名字；
命令行用 `--user` / `--pass`。命令模式不给参数时用 `ubuntu`（与 Ubuntu cloud
image 自带的默认账号一致）。

两种 seed 形态：

| `VM_USER` | user-data |
|---|---|
| `root` | 不建额外账号，只给 root 设密码 |
| 其他 | 建一个带 `sudo: ALL=(ALL) NOPASSWD:ALL` 的账号；**root 同密码**，便于救急 |

#### root 密码登录为什么会失败

在 Ubuntu cloud image 上，只设密码是**不够**的。实测：

```text
$ sshd -T | grep -i permitroot
permitrootlogin prohibit-password      <-- 即使设了密码也拒绝
```

原因在 sshd 的配置包含顺序：

```text
/etc/ssh/sshd_config              Include /etc/ssh/sshd_config.d/*.conf
/etc/ssh/sshd_config.d/50-cloud-init.conf        PasswordAuthentication yes   <- cloud-init 写的
/etc/ssh/sshd_config.d/60-cloudimg-settings.conf PasswordAuthentication no    <- 镜像自带，排后面，赢
```

后者按字母序在后面，覆盖了 cloud-init 的设置。所以 ckvm 另外写一个
`99-ckvm-root.conf`：

```text
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
```

并删除 `60-cloudimg-settings.conf` 里的 `PasswordAuthentication` 行，最后重启
sshd。实测（`--user root --pass Secret123`）：

```text
$ sshpass -p Secret123 ssh -p 8030 root@127.0.0.1 'id'
uid=0(root) gid=0(root) groups=0(root)
```

#### 为什么用 write_files 而不是 runcmd

第一版把 shell 命令直接塞进 `runcmd:`，转义在 cloud-init YAML 里被层层吃掉，
写出来的文件是坏的：

```text
- [ sh, -c, "printf %s\\n \"PermitRootLogin yes\" ... > ..." ]
```

现在改成 `write_files` 写一个 `/usr/local/sbin/ckvm-ssh-fix` 脚本，`runcmd`
只调用它：

```yaml
write_files:
  - path: /usr/local/sbin/ckvm-ssh-fix
    permissions: "0755"
    content: |
      #!/bin/sh
      ...
runcmd:
  - [ /usr/local/sbin/ckvm-ssh-fix ]
```

这样脚本内容原样落到 guest，不需要任何转义。

---

## 9. 实测数据集

### 9.1 环境

```text
设备     小米 MT6833 / evergo
容器     droidspaces Debian 13，systemd 为 PID 1
内核     4.14.356-Evergo-KVM-cuicanmx-v1.0
QEMU     /usr/bin/qemu-system-aarch64
guest    Ubuntu 26.04.1 LTS，kernel 7.0.0-38-generic
```

### 9.2 启动

```text
$ ckvm start ubuntu26
  guest 'ubuntu26' running (pid 11506, 8 vCPU, 2048 MiB, cpuset 6-7)
  network: user-mode NAT
    ssh ubuntu@127.0.0.1 -p 8023

约 30 秒后串口出现：
Ubuntu 26.04.1 LTS ubuntu2604 ttyAMA0
ubuntu2604 login:
```

### 9.3 guest 规格

```text
PRETTY_NAME="Ubuntu 26.04.1 LTS"
uname -r          7.0.0-38-generic
nproc             (对应 -smp 值)
Memory            1946 MiB
/dev/vda1         48G  2% used      <- 50G 盘自动扩容
```

### 9.4 多开

```text
$ ckvm list
  NAME             STATE    CPUS   MEM      DISK    PORT   SSH
  test2            running  4      1536     50G     8024   ssh u0@127.0.0.1 -p 8024
  ubuntu26         running  8      2048     50G     8023   ssh ubuntu@127.0.0.1 -p 8023
```

### 9.5 关键对照实验

| 实验 | 条件 | 结果 |
|---|---|---|
| 绑核 | `taskset -c 6-7`，3 次 | 3 成功 / 0 失败 |
| 不绑核 | 同样配置，3 次 | 0 成功 / 3 失败 |
| vCPU 数 | `-smp 2/4/6/8`（绑核） | 全部启动，assert=0 |
| NVRAM | nonvram 固件 | NISV abort = 0 |
| NVRAM | 标准 AAVMF | `far=0x4007c000`，vCPU 卡死 |
| 网络 | host 模式 | `172.28.100.2:22` 可达，ping 0% 丢包 |
| 下载 | aria2 多连接 | 约 10 MB/s |

---

## 10. 参考出处

### 10.1 架构规范

- **ARM Architecture Reference Manual for A-profile architecture**（DDI 0487）
  — *D13.2.37 ESR_EL2, Exception Syndrome Register (EL2)*，ISV bit [24] 的
  定义与 Data Abort ISS 编码表。
  <https://developer.arm.com/documentation/ddi0487/latest/>
- **ARM Reliability, Availability, and Serviceability (RAS) Specification**
  （DDI 0587）— 2.5.3 *Multiple SError interrupts*。
  被 KVM API 文档在 SError 语义处引用。

### 10.2 Linux 内核

- **The Definitive KVM API Documentation** — 官方 API 文档，本文多处引用：
  - §4.10 `KVM_RUN`（`ENOSYS` 与 `KVM_CAP_ARM_NISV_TO_USER`）
  - §4.31 `KVM_GET_VCPU_EVENTS`（`struct kvm_vcpu_events` 布局）
  - §4.32 `KVM_SET_VCPU_EVENTS`（`ext_dabt_pending` 语义）
  <https://www.kernel.org/doc/html/latest/virt/kvm/api.html>
- **KVM for Arm 文档** — EL2 / VHE / nVHE 模式说明。
  <https://www.kernel.org/doc/html/latest/virt/kvm/arm/index.html>
- **`KVM: arm64: Force injection of a data abort on NISV MMIO exit`**
  — commit `3b467b16582c077f57fab244cf0801ecea7914b6`（上游实现）。
  <https://github.com/torvalds/linux/commit/3b467b16582c077f57fab244cf0801ecea7914b6>
- **补丁系列 "Allow reporting non-ISV data aborts to userspace"**（kvmarm
  邮件列表，2019-11）— NISV 机制的原始提交。
  <https://lists.cs.columbia.edu/pipermail/kvmarm/2019-November/037985.html>
- 本机源码：`virt/kvm/arm/mmio.c`、`arch/arm64/kvm/guest.c`、
  `arch/arm64/kvm/reset.c`、`virt/kvm/arm/arm.c`

### 10.3 QEMU

- **`[PATCH v3] arm/kvm: report registers we failed to set`**（Cornelia Huck，
  2025-09）— `Failed to put registers after init` 的来源与失败原因说明。
  <https://patchew.org/QEMU/20250911154159.158046-1-cohuck@redhat.com/>
- QEMU 邮件列表（qemu-arm）关于 ISV=0 的答复，Peter Maydell：
  > "Don't do this -- KVM doesn't support it. For access to MMIO, stick to
  > instructions which will set the ISV bit in ESR_EL1."

### 10.4 固件

- **Limbo for Tensor**（`wasdwasd0105/limbo_tensor`）— 不写 NVRAM 的 EDK2
  构建来源；README 说明 Enable/Disable 两种固件的差异。
  <https://github.com/wasdwasd0105/limbo_tensor>
- **EDK2 / TianoCore** — UEFI 固件实现。
  <https://github.com/tianocore/edk2>
- **cloud-init 文档** — `users`、`growpart`、`apt` 模块与 NoCloud 数据源。
  <https://cloudinit.readthedocs.io/>
- **netplan 文档** — `network-config` 的 v2 语法。
  <https://netplan.readthedocs.io/>

### 10.5 禁用 GenieZone / 释放 EL2

- **mtk-soc-disable-geniezone** — jsbsbxjxh66（酷安），MIT。提供
  `detect_gz_bypass.py`（检测 preloader 能否走 GPT 方案）与
  `patch_gz_gpt.py`（改写 GZ 分区 LBA 并重算 CRC）。第 11 节的全部操作
  基于此项目。
  <https://github.com/jsbsbxjxh66/mtk-soc-disable-geniezone>

### 10.6 工具

- **aria2 手册** — `-x` / `-s` / `-k` / `-c` 等选项语义。
  <https://aria2.github.io/manual/en/html/aria2c.html>
- **systemd.service / systemd.unit** — `Type=forking`、`PIDFile`、实例单元。
  <https://www.freedesktop.org/software/systemd/man/systemd.service.html>
- **QEMU 系统模拟文档** — `virt` 机型、`pflash`、`-netdev user/tap`。
  <https://www.qemu.org/docs/master/system/>

### 10.7 镜像源

- 南京大学镜像站：<https://mirror.nju.edu.cn/ubuntu-cloud-images/>
- 中国科学技术大学镜像站：<https://mirrors.ustc.edu.cn/>
- Ubuntu 官方 cloud images：<https://cloud-images.ubuntu.com/releases/>

---

## 11. 在红米 Note 11 5G（MT6833）上禁用 GenieZone 并释放 EL2

> **本节内容由使用者提供并整理，实践过程记录自实际设备操作。**
> 原文是一份独立记录，此处并入技术文档，作为 KVM 工作的前提步骤。

### 11.1 致谢

本实践参考并使用了酷安用户 **jsbsbxjxh66** 开发的开源项目
`mtk-soc-disable-geniezone`。该项目提供了完整的检测、修改与补丁工具链，
使得在联发科平台上禁用 GenieZone 成为可能。

| 项目 | 内容 |
|---|---|
| 项目地址 | `github.com/jsbsbxjxh66/mtk-soc-disable-geniezone` |
| 作者 | jsbsbxjxh66（酷安） |
| 协议 | MIT |

### 11.2 设备与目标

| 项目 | 内容 |
|---|---|
| 设备 | Redmi Note 11 5G（MT6833），代号 `evergo` |
| 平台代际 | 天玑 v5 |
| 存储类型 | UFS（扇区大小 4096 字节） |
| 目标 | 禁用 GenieZone（GZ），释放 EL2，为运行 KVM 做准备 |

根据 jsbsbxjxh66 项目文档，天玑 v5 平台的 GZ 初始化完全由 **preloader**
负责，LK 中无 GZ 代码。因此采用 **GPT 方案 A（无效 LBA）** 即可在 preloader
层面禁用 GZ，无需修改 LK 或 ATF。

### 11.3 第一步：检测 preloader 可行性

从设备提取 `boot1.bin`（即 preloader 分区），运行检测脚本：

```bash
python3 detect_gz_bypass.py boot1.bin
```

检测结果：

```text
文件大小: 4,194,304 bytes (4.0 MB)
GFH: load_addr=0x00200F10  BASE=0x001FFE20  Thumb PIC  GFH偏移=0x1000
NoGZ: 2 处  CMP #512: 0x271E8
assert_fatal: 0x3D978 (global)  halt_on_assert: 0x00272DC8

GPT 修改方案: 可用
halt_on_assert 未强制置 1, assert 非致命
存储类型: UFS

重名方案 (gz→gx): 不可行
  "gz" 2 处代码引用 (0x4F418(2))
  主引导函数 (0x2AB38-0x2C338) 包含 gz 分区名引用
  主引导循环依赖 gz 名称解析, 重名导致引导流水线中断
无效 LBA 欺骗:    有 UFS 越界风险
  "LBA out of range" @0x59AC0

推荐: 无效 LBA 方案 (只需修改 PGPT)
```

结论：

- **GPT 方案可用** —— `halt_on_assert` 未被强制置 1，assert 非致命，I/O 失败后
  preloader 可正常设置 `NoGZ` 并继续启动。
- **重名方案不可行** —— 主引导函数独立引用 `gz` 分区名，重命名为 `gx` 会导致
  引导流水线中断，设备黑砖。
- **UFS 越界风险** —— 脚本提示越界 LBA 可能被 UFS 控制器拒绝。但
  jsbsbxjxh66 项目的兼容性列表显示，同为 MT6833 的 OPPO A55 已验证该方案
  可用，因此决定继续。

### 11.4 第二步：修改 GPT 分区表

先预览：

```bash
python3 patch_gz_gpt.py pgpt.bin --dry-run
```

确认脚本正确识别 `gz_a`（LBA `0xac600`–`0xae5ff`）和 `gz_b`
（LBA `0xd1e00`–`0xd3dff`）后，生成修改后的 GPT：

```bash
python3 patch_gz_gpt.py pgpt.bin -o pgpt_patched.bin
```

```text
找到 2 个 GZ 分区:
  gz_a: LBA 0xac600 - 0xae5ff (8192 扇区, 32.0 MB)
  gz_b: LBA 0xd1e00 - 0xd3dff (8192 扇区, 32.0 MB)

已备份原始文件到: pgpt_backup.bin

修改详情 (改 LBA 越界):
  无效 LBA: 0x3b96000 (最后有效 LBA: 0x3b95fff)
  gz_a: Start LBA 0xac600 → 0x3b96000, End LBA 0xae5ff → 0x3b96000
  gz_b: Start LBA 0xd1e00 → 0x3b96002, End LBA 0xd3dff → 0x3b96002

CRC 更新:
  Entries CRC32: 0xbbd764b2 → 0xb00b51ab
  Header CRC32:  0xb253f760 → 0x07bd9b95

完成! 共修改 23 字节
输出文件: pgpt_patched.bin
备份文件: pgpt_backup.bin
```

脚本自动备份原始文件，并更新 GPT 的 Header CRC32 与 Entries CRC32。

### 11.5 第三步：刷入 PGPT 分区

首次直接刷完整的 `pgpt_patched.bin`（512 KB）会失败：

```text
FAILED (remote: 'size too large')
```

原因是 `pgpt` 分区实际只有 **32 KB**（32768 字节），而完整 GPT 镜像包含主
GPT、备份 GPT 等结构，共 512 KB。

提取前 32 KB 再刷：

```bash
head -c 32768 pgpt_patched.bin > pgpt_32k.bin
# 或者
dd if=pgpt_patched.bin of=pgpt_32k.bin bs=4096 count=8

fastboot flash pgpt pgpt_32k.bin
```

```text
Sending 'pgpt' (32 KB)  OKAY
Writing 'pgpt'          OKAY
Finished
```

重启后设备正常开机，进入系统，**无变砖现象**。

### 11.6 第四步：验证 GZ 是否被禁用

```bash
adb shell su

# 设备树里不应有 gz 节点
ls /proc/device-tree/chosen/
find /proc/device-tree -name "*gz*"

# 内核日志里不应有 GZ 初始化
dmesg | grep -iE "nogz|gz is disabled|gz_init"

# KVM 设备节点
ls -l /dev/kvm

# 启动参数
cat /proc/cmdline
```

结果：

| 检查 | 结果 |
|---|---|
| `/proc/device-tree` 下 `*gz*` | 无任何结果 |
| `dmesg` 中 `nogz` / `gz_init` | 无输出 |
| `/dev/kvm` | `No such file or directory` |
| `/proc/cmdline` 中 `el2` / `kvm` / `hvc` | 无 |

结论：

- **条件一满足** —— 设备树中无 GZ 相关节点、`dmesg` 无 GZ 初始化日志，
  表明 preloader 读取越界 LBA 失败后已设置 `NoGZ`，跳过了 GZ 加载。
  **GZ 已禁用，EL2 已释放。**
- **条件二未满足** —— `/dev/kvm` 不存在，启动参数中无 EL2/KVM 字样，
  表明当时的内核未开启 KVM 支持。

### 11.7 第五步：内核编译准备

```bash
git clone https://github.com/ccmx200/kernel-lxc-xiaomi_mt6833
cd kernel-lxc_xiaomi_mt6833
```

切换到 `resukisu` 分支后 `git pull` 遇到本地 `build.sh` 冲突：

```text
error: Your local changes to the following files would be overwritten by merge:
        build.sh
```

用 stash 暂存再恢复：

```bash
git stash
git pull
git stash pop
```

计划：

- 配置内核开启 `CONFIG_KVM`
- 添加可识别的版本号（如 `-NoGZ-EL2-KVM`），便于 `uname -a` 辨认
- 编译并刷入，确认 `/dev/kvm` 出现、内核运行在 EL2
- 用 QEMU/KVM 运行虚拟机

### 11.8 关键命令汇总

```bash
# 1. 检测 preloader
python3 detect_gz_bypass.py boot1.bin

# 2. 修改 GPT
python3 patch_gz_gpt.py pgpt.bin -o pgpt_patched.bin

# 3. 提取 32KB
head -c 32768 pgpt_patched.bin > pgpt_32k.bin

# 4. 刷入 PGPT
fastboot flash pgpt pgpt_32k.bin
fastboot reboot

# 5. 验证
adb shell su
dmesg | grep -iE "nogz|gz is disabled"
find /proc/device-tree -name "*gz*"
ls -l /dev/kvm

# 6. 还原（如需）
head -c 32768 pgpt_backup.bin > pgpt_backup_32k.bin
fastboot flash pgpt pgpt_backup_32k.bin
```

### 11.9 经验与提醒

1. **严格区分方案** —— MT6833 上重名方案（`--rename`）会导致黑砖，必须使用
   无效 LBA 方案。
2. **分区大小限制** —— `pgpt` 分区仅 32 KB，刷写前必须从完整 GPT 镜像中提取
   前 32 KB。
3. **UFS 越界风险** —— 部分 UFS 控制器遇到越界 LBA 可能崩溃而非返回错误，
   操作前须做好救砖准备。
4. **备份至关重要** —— `patch_gz_gpt.py` 会自动备份，务必保留
   `pgpt_backup.bin`。
5. **OTA 更新** —— 系统 OTA 可能还原 GPT，更新后需重新刷入修改后的 PGPT。
6. **区分来源** —— 本实践使用 GPT 方案，**未修改 preloader**，也未刷入旧版
   preloader。这与 jsbsbxjxh66 文章中提及的"改 preloader"路径不同，请勿混淆。
7. **v5 平台优势** —— 天玑 v5 平台禁用 GZ 后无需 ATF 补丁，设备可稳定运行，
   不会出现 VCP 看门狗重启或 DEVMPU 违规问题。

### 11.10 与本文其他章节的关系

| 条件 | 状态 | 说明 |
|---|---|---|
| preloader 未把 EL2 交给 GZ | ✅ 已满足 | 通过 GPT 无效 LBA 方案禁用 GZ |
| 内核开启 KVM | 取决于内核 | 见第 1.2 节与第 3 节 |

本节记录的是**条件一**：把 EL2 从 GenieZone 手里拿回来。第 1.2 节描述的
"厂商固件占据 EL2" 是本文 KVM 工作最初面对的状态；一旦按本节禁用 GZ，
EL2 就重新归内核所有，`CONFIG_ARM64_VHE` 与 KVM 才有落脚点。

两条路径的其余部分（`ESR_EL2.ISV == 0`、NISV 回移、绑核、固件选择）与本节
正交，不因 GZ 是否禁用而改变。

> **设备代号的说明**：本文的实测数据全部来自**同一台设备** —— MT6833，
> 代号 `evergo`（本仓库的 DTS 是 `evergo.dts`）。文档与版本号里也出现过
> `everpal`，那是**同一个东西的另一个名字**，不是第二台机器。
>
> 第 1 章的环境、第 9 章的测量、第 11 章的 GenieZone、第 12 章的 CPU 拓扑，
> 指的都是这一台。不需要维护两份设备档案。

### 11.11 致谢（重申）

再次感谢酷安用户 **jsbsbxjxh66** 开发并开源了
`mtk-soc-disable-geniezone`。该项目的检测脚本准确识别了 preloader 特性，
修改脚本安全高效地完成了 GPT 越界 LBA 改写与 CRC 校验更新，使得在不修改
preloader 代码、不破坏签名验证的前提下，成功禁用 GenieZone 并释放 EL2。

---

---

## 12. 物理核使用：从"必须绑核"到"随便配"

这一章是本项目最核心的一段。它解释**为什么早期必须把虚拟机钉死在单一种
核心上**、**根因到底是什么**、**怎么修的**，以及**修好之后 CPU 能怎么配**。

结论先行：

| | 修复前 | 修复后 |
|---|---|---|
| CPU 掩码 | 只能单簇（如 `6-7`） | **任意掩码**，混合簇也行 |
| `-smp 8` 不绑核 | 6 次成功 1–2 次 | **3/3** |
| `ckvm` 需要 workaround | 是（`BOOT_CPU` + `widen_affinity`） | **否** |

### 12.1 硬件拓扑

`/proc/device-tree/cpus/` 实测：

```text
cpu0-5   Cortex-A55   capacity 367    max 2.0 GHz    6 个
cpu6-7   Cortex-A76   capacity 1024   max 2.4 GHz    2 个
```

两种核心的 **`MIDR_EL1` 不同**：

```text
cpu0-5 (A55)   midr_el1 = 0x00000000412fd050
cpu6-7 (A76)   midr_el1 = 0x00000000414fd0b0
```

> `lscpu` 在这台机器上会误报成清一色的 A55（`CPU(s): 8`，
> `Core(s) per socket: 6`），因为它只读了第一个簇。要看真实拓扑用
> `/sys/devices/system/cpu/cpu*/cpu_capacity`。

**核心差异不止 MIDR。** 用 `KVM_GET_ONE_REG` 逐核实测：

```text
               cpu0 (A55)           cpu6 (A76)
MIDR_EL1       0x00000000412fd050   0x00000000414fd0b0
ID_PFR0_EL1    0x0000000010000131   0x0000000010010131
CTR_EL0        0x0000000084448004   0x000000009444c004
CCSIDR(csselr=0) 0x700fe01a         0x200fe01a
```

### 12.2 症状

不加限制地启动 QEMU，会随机失败：

```text
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

有时固件更早就崩：

```text
ASSERT [ArmPlatformPrePeiCore]
```

**成功率实测（每组 6 次）：**

```text
掩码 0-7     smp 1    4 / 6
掩码 0-7     smp 2    1 / 6
掩码 0-7     smp 4    2 / 6
掩码 0-7     smp 8    2 / 6
掩码 6-7     smp 8    6 / 6      <- 单一簇
掩码 0-5     smp 4    6 / 6      <- 单一簇
单核                 6 / 6
```

**不是 vCPU 数量的问题，是掩码是否跨簇的问题。**

### 12.3 根因（一）：invariant 寄存器被钉在开机那个核上

`arch/arm64/kvm/sys_regs.c` 里有一张 invariant 表：

```c
static struct sys_reg_desc invariant_sys_regs[] = {
        { SYS_DESC(SYS_MIDR_EL1),   NULL, get_midr_el1 },
        { SYS_DESC(SYS_REVIDR_EL1), NULL, get_revidr_el1 },
        { SYS_DESC(SYS_ID_PFR0_EL1), NULL, get_id_pfr0_el1 },
        ...
};
```

它的值由 `kvm_sys_reg_table_init()` **在开机时填一次**：

```c
#define FUNCTION_INVARIANT(reg)                                       \
        static void get_##reg(struct kvm_vcpu *v,                     \
                              const struct sys_reg_desc *r)           \
        {                                                             \
                ((struct sys_reg_desc *)r)->val = read_sysreg(reg);   \
        }
```

`read_sysreg()` 读的是**执行它的那个核**。于是整张表被固定成
"开机时恰好跑到的那个核"的值。

写入时又比对这张表：

```c
static int set_invariant_sys_reg(struct kvm *kvm, u64 id, void __user *uaddr)
{
        ...
        if (invariant_reg_value(kvm, r) != val)
                return -EINVAL;
}
```

**QEMU 的行为正好踩中这个坑**：它先探测宿主 CPU 特性（读），再把
这些值写回真正的 vCPU（写）。两次操作只要落在**不同的簇**上，值必然不同，
写入就被 `-EINVAL` 拒绝。

```text
1. QEMU 读宿主 CPU 特性       <- 可能调度到 A76
2. QEMU 把值写入目标 vCPU     <- 可能调度到 A55
3. A55 与 A76 的值不同
4. KVM 判定"常量寄存器值不一致" -> EINVAL
```

### 12.4 根因（二）：demux 寄存器读的是"当前核"

**第一版修复只覆盖了上面这张表，结果 QEMU 仍然失败。** 用穷举法
（枚举 `KVM_GET_REG_LIST` 暴露的全部 262 个寄存器，逐个"在 cpu0 读、
在 cpu6 写回同值"）才找到剩下的元凶 —— 只有 3 个，而且都不是 sysreg：

```text
u32 proc=0x110000 0x110000   0x700fe01a   Invalid argument
u32 proc=0x110000 0x110001   0x200fe01a   Invalid argument
u32 proc=0x110000 0x110002   0x703fe01a   Invalid argument
```

`proc=0x110000` 是 **`KVM_REG_ARM_DEMUX`**（sysreg 是 `0x600000`），
它们是 AArch32 的缓存寄存器 `CCSIDR`。实现里有**一模一样的核心依赖**：

```c
static int demux_c15_set(struct kvm *kvm, u64 id, void __user *uaddr)
{
        ...
        /* This is also invariant: you can't change it. */
        if (newval != get_ccsidr(val))
                return -EINVAL;
}

static u32 get_ccsidr(u32 csselr)
{
        ...
        write_sysreg(csselr, csselr_el1);
        isb();
        ccsidr = read_sysreg(ccsidr_el1);   /* <- 读【当前核】的缓存几何 */
        ...
}
```

A55 和 A76 的缓存不同，`CCSIDR` 必然不同，于是跨簇的读-写回和 MIDR 一样
必然失败。**这一处不在 sysreg 表里，所以第一版修复碰不到它。**

### 12.5 修复：把这两类寄存器改成"按 VM 快照"

思路来自主线：现代内核把 ID 寄存器变成**per-VM 属性**
（`kvm->arch.id_regs[]`，经 `read_id_reg()` / `set_id_reg()` 访问），值对整个
VM 一致，不再取决于调用方所在的核心。

4.14 没有这个结构，所以加了一个。**实现在 `kvm_arch_init_vm()` 里取一次
快照，之后所有读写都走这份快照。**

数据结构（`arch/arm64/include/asm/kvm_host.h`）：

```c
struct kvm_arch {
        ...
        u64 *id_regs_snapshot;          /* invariant sysreg 快照 */
        bool id_regs_snapshot_valid;

        u32 id_demux_snapshot[16];      /* CCSIDR，按 CSSELR 索引 */
        bool id_demux_snapshot_valid;
};
```

取快照（`arch/arm64/kvm/sys_regs.c`）：

```c
int kvm_arm_id_reg_snapshot(struct kvm *kvm)
{
        ...
        for (i = 0; i < ARRAY_SIZE(invariant_sys_regs); i++) {
                const struct sys_reg_desc *r = &invariant_sys_regs[i];

                if (r->reset) {
                        r->reset(NULL, r);          /* 重新读一次，不要复制旧值 */
                        kvm->arch.id_regs_snapshot[i] = r->val;
                } else {
                        kvm->arch.id_regs_snapshot[i] = r->val;
                }
        }
        kvm->arch.id_regs_snapshot_valid = true;
        return 0;
}
```

读写都走快照：

```c
static u64 invariant_reg_value(struct kvm *kvm, const struct sys_reg_desc *r)
{
        int i;

        if (!kvm || !kvm->arch.id_regs_snapshot_valid ||
            !kvm->arch.id_regs_snapshot)
                return r->val;                  /* 退化：仍用全局表 */

        i = invariant_reg_index(r);
        if (i < 0)
                return r->val;

        return kvm->arch.id_regs_snapshot[i];
}
```

demux 同理：

```c
static u32 demux_snapshot_value(struct kvm *kvm, u32 csselr)
{
        if (!kvm || !kvm->arch.id_demux_snapshot_valid ||
            csselr >= ARRAY_SIZE(kvm->arch.id_demux_snapshot))
                return get_ccsidr(csselr);

        return kvm->arch.id_demux_snapshot[csselr];
}
```

挂钩点（`virt/kvm/arm/arm.c`）：

```c
int kvm_arch_init_vm(struct kvm *kvm, unsigned long type)
{
        ...
        kvm_vgic_early_init(kvm);

        ret = kvm_arm_id_reg_snapshot(kvm);
        if (ret)
                goto out_free_stage2_pgd;

        ret = kvm_arm_id_demux_snapshot(kvm);
        if (ret)
                goto out_free_stage2_pgd;
        ...
}
```

#### 为什么这样就"自由"了

`kvm_arch_init_vm()` 在 **`KVM_CREATE_VM` 时**执行，**任何 vCPU 都还不存在**。
所以：

1. 快照在**单一核**上取得 —— 没有竞态，值本身是自洽的一份
2. 之后**这个 VM 的每一次读和每一次写都查同一份快照**
3. vCPU 线程随后调度到哪个核，**不再影响读到的值，也不再影响写回是否被接受**

于是"读在 A76、写在 A55"这种情形不再产生不一致 —— 两边查的都是同一份快照。

#### 为什么是"重新读"而不是"复制全局表"

`invariant_sys_regs[]` 是**开机时**填的，可能来自 A55。如果直接复制它，
一个 vCPU 全跑在 A76 上的 VM 依然会被告知自己是 A55。

在 `kvm_arch_init_vm()` 里重新调用 `r->reset(NULL, r)` 再取值，既保持了
"整个 VM 一致"（只取一次、只存一份），又反映**该 VM 建立时那颗核**的视图。
`reset` 回调忽略 vcpu 参数（`kvm_sys_reg_table_init()` 也是用 `NULL` 调它），
所以传 `NULL` 是正确的。

#### 安全边界没有放宽

写入仍然要匹配本 VM 报告的值，用户态**依旧不能凭空造出宿主没有的特性**：

```c
if (invariant_reg_value(kvm, r) != val)
        return -EINVAL;
```

改的只是"跟谁比"，不是"要不要比"。

### 12.6 验证

#### 寄存器层面（穷举）

```text
修复前:  checked 230 writable registers, 3 failed the cross-cluster write-back
修复后:  checked 230 writable registers, 0 failed the cross-cluster write-back
```

#### 同一个 VM 跨核读，值应当一致

一个 VM，两个线程分别绑 `cpu0`（A55）和 `cpu6`（A76）读同一批寄存器：

```text
register       read on cpu0         read on cpu6         same?
MIDR_EL1       0x00000000414fd0b0   0x00000000414fd0b0   YES
ID_PFR0_EL1    0x0000000010010131   0x0000000010010131   YES
ID_ISAR0_EL1   0x0000000002101110   0x0000000002101110   YES
CTR_EL0        0x000000009444c004   0x000000009444c004   YES
```

> **一个容易犯的测试错误**：如果在**两次独立运行**里分别绑不同的核，每次
> 都会新建一个 VM，因而各拿到自己的快照值，看起来像"补丁没生效"。
> 每个 VM 有独立快照是**正确**行为 —— 验证必须在**同一个 VM 内**跨核进行。
> （我第一轮就是这么误判的。）

#### 端到端：QEMU 不再需要绑核

```text
修复前  不绑核 -smp 1                0 / 5
修复后  不绑核 -smp 1                5 / 5
修复后  不绑核 -smp 8  2048MB        3 / 3
```

### 12.7 所以 CPU 能怎么配

修复后在真机上穷举了 7 种掩码，每种 3 次：

```text
掩码         smp   说明                 结果
0-7          8     全核 8 vCPU          3/3
0-5          6     全小核 6 vCPU        3/3
6-7          2     全大核 2 vCPU        3/3
0-2,6-7      5     非对称 3小+2大       3/3     <- 以前必崩
0,7          2     极端 1小+1大         3/3     <- 以前必崩
6            8     8 vCPU 挤单大核      3/3
0-7          16    16 vCPU 超配 2x      3/3
```

**21/21 全过，包括以前必然失败的混合掩码。**

#### 仍然成立的两条正常语义

1. **给几个核就只能用几个核。** `taskset -c 6 ... -smp 8` 能跑，但 8 个
   vCPU 抢一个物理核，吞吐受限于单核（实测约 2.9–3.0 GB/s）。这是捆绑
   语义，不是 bug。
2. **不要手工绑核。** 让调度器自己管即可；`ckvm` 的 `BOOT_CPU` 现在默认为空。

### 12.8 vCPU 热插拔：本机仍然不可行

这与上面的修复无关，是架构限制：

```text
QMP device_add -> Parameter 'driver' expects a pluggable device type
qom-list /machine/unattached/device[cpu0] -> DeviceNotFound
```

aarch64 的 vCPU 不是可插拔设备 —— **GIC 的 CPU interface 在 machine init
时就固定了**。所以 `-smp N` 必须在启动时定好。变通办法是改 `vm.conf` 的
`CPUS` 后 `ckvm restart`。

### 12.9 性能：8 个物理核值不值

guest 内 `openssl speed -multi 8 -evp sha256 -seconds 2`（16384 字节块），
取多次运行的中位数：

| 物理核 | 吞吐 | 启动耗时 |
|---|---|---|
| 全部 8 核 | **7.4 – 7.7 GB/s** | 42 – 44 s |
| 6 个小核 | 4.5 – 4.9 GB/s | ~46 s |
| 2 个大核 | 2.9 – 3.0 GB/s | ~34 s |

**全核约为大核专用的 2.6 倍**，代价是启动慢 8 – 12 秒。

> **数据可信度声明**：第一轮测到的是噪声（gzip 结果摆动 1.7 倍且重测后
> 反转）。上表是**重复多次、交替顺序、取中位数**之后的结论。
>
> 另需注意，容器与 guest 的软件栈不同（容器 4.14 内核 + Debian 13 +
> OpenSSL 3.5.7；guest 6.8 内核 + Ubuntu 24.04 + OpenSSL 3.0.13），
> 所以严格说这是**两个环境的端到端对比**，不是纯 CPU 对比。

### 12.10 为什么默认是"全核"

因为这台机器的瓶颈是**吞吐**而不是单核延迟：

- 宿主要同时跑 droidspaces、guest、以及可能的多个 guest
- 全核吞吐是大核专用的 2.6 倍
- 多出的 8–12 秒启动时间，相对于"开一次用很久"可以忽略

想要低延迟、轻负载的场景（例如只跑一个交互式服务）再用 `--cores big`。

### 12.11 出处

**内核实现**

- `arch/arm64/kvm/sys_regs.c` —— `invariant_sys_regs[]`、
  `FUNCTION_INVARIANT`、`set_invariant_sys_reg()`、`demux_c15_set()`、
  `get_ccsidr()`；本项目的 `kvm_arm_id_reg_snapshot()` /
  `kvm_arm_id_demux_snapshot()`
- `arch/arm64/include/asm/kvm_host.h` —— `struct kvm_arch` 里的两个快照字段
- `virt/kvm/arm/arm.c` —— `kvm_arch_init_vm()` 里的挂钩
- 主线对照：`arch/arm64/kvm/sys_regs.c` 的 `read_id_reg()` / `set_id_reg()`
  与 `kvm->arch.id_regs[]`（Linux 7.2）

**QEMU 侧**

这条报错来自 QEMU 的 `write_list_to_kvmstate()`。该函数在补丁
*"arm/kvm: report registers we failed to set"*（Cornelia Huck，2025-09）中
被加入了更详细的诊断，补丁说明原文：

> If we fail migration because of a mismatch of some registers between source
> and destination, the error message is not very informative:
> `qemu-system-aarch64: Failed to put registers after init: Invalid argument`
> At least try to give the user a hint which registers had a problem

补丁代码注释给出了失败的两个原因：

> We might fail for **"unknown register"** and also for **"you tried to set a
> register which is constant with a different value from what it actually
> contains"**.
>
> — [PATCH v3] arm/kvm: report registers we failed to set
> <https://patchew.org/QEMU/20250911154159.158046-1-cohuck@redhat.com/>

第二种情况正是本机型的问题：

```text
1. QEMU 建临时 vCPU，探测宿主 CPU 特性（此时可能调度到 A76）
2. QEMU 把这些值写入真正的 vCPU（此时可能调度到 A55）
3. A55 的 ID 寄存器值与 A76 不同
4. KVM 判定"这是常量寄存器且值不一致" -> EINVAL
```

本机型两种核心的 ID 寄存器视图**确实不同**（见 §1.1 的 `CPU part` 实测）。


本文档没有引用本项目的私有提交号作为"证据" —— 所有结论都来自上述源码、
上表实测数据，或随文给出的复现脚本。

**复现脚本**（都在 `kvm_manager/tools/`）：

```text
kvm_midr_repro.c      绑单核读写 MIDR_EL1，展示核心依赖
kvm_samevm_read.c     同一 VM 跨核读，验证一致性
kvm_crosstest.c       跨核"读-写回"，QEMU 操作的等价物
kvm_exhaustive.c      枚举全部寄存器，定位到 demux
```

编译运行（设备上，需 `root` 与 `/dev/kvm`）：

```bash
gcc -D_GNU_SOURCE -O0 -o kvm_exh kvm_exhaustive.c -lpthread
./kvm_exh                  # 应输出 0 failed
```

### 12.12 思路来源

**主线内核的做法**是这一节的直接依据 —— 把 ID 寄存器变成 per-VM 属性，
而不是"每次从当前核现读"。参考 Linux 7.2 的 `arch/arm64/kvm/sys_regs.c`。

**穷举定位法**来自一个朴素的判断：既然单个寄存器（MIDR）能定位，那
"把所有寄存器都试一遍"就一定能找出**全部**跨簇依赖的寄存器，而不是靠猜。
这一步直接找出了第一版遗漏的 demux 寄存器。


---

## 13. 自检

`ckvm selftest` **只检查配置，不启动任何虚拟机**。这样它瞬间完成、随时可跑，
也不需要先下载几个 GB 的镜像。

```text
$ ckvm selftest

  自检  只检查配置，不启动虚拟机
  ────────────────────────────────────────────────────────────────────

    ✅ root 权限
    ✅ /dev/kvm
    ✅ qemu-system-aarch64
    ✅ qemu-img
    ✅ cloud-localds
    ✅ UEFI 固件
    ✅ 固件大小             64.0M
    ✅ CPU 拓扑             8 核，小核 367 / 大核 1024
    ✅ 内存                 总 5.5G，可用 1.4G
    ✅ 磁盘                 /var/lib/ckvm 可用 91.4G
    ✅ 虚拟机               1 台
    ✅ 镜像缓存             1 个，901.7M
    ✅ apt 源               https://mirror.nju.edu.cn/debian

  ✅ 全部通过

  下一步： ckvm create
```

### 13.1 检查项为什么是这些

| 项 | 不做会怎样 |
|---|---|
| root / `/dev/kvm` | KVM 用不了，只剩软件模拟 |
| 三个必需命令 | 创建到一半才失败 |
| UEFI 固件与大小 | guest 停在 UEFI，看不出原因 |
| CPU 拓扑（`cpu_capacity`）| 掩码选错也不知道大小核 |
| 内存 / 磁盘余量 | 启动时 QEMU 才报错 |
| apt 源 | 官方源在国内很慢，装依赖会像卡死 |

固件大小用「大于 1 MB」判断：真实的 EDK2 blob 是 64 MB，比这小的只可能是
错误页面或半截下载。

### 13.2 曾经写过一个永远通过的检查

早期版本里有这么一行：

```python
add("固件不写 NVRAM",
    b"NonVolatile" not in open(code, "rb").read(4096) or True, "")
```

`or True` 让它恒为真 —— 是占位符忘了填。**永远通过的检查比没有检查更糟**，
它会让人以为刻度是可信的。这条已经删掉：从固件二进制里没有便宜的办法判断
这个属性，所以就不假装能判断。

真正的后果（NVRAM 被污染导致 GRUB 卡住）在 `start` 时处理 ——
每次启动都从模板重新拷 `uefi-vars.fd`。

### 13.3 与第 12 节的关系

`selftest` 只读 `cpu_capacity` 来确认大小核划分，不验证跨簇。跨簇能不能用是
内核侧的事（第 12 章），由 `ckvm status` 里实际生效的亲和掩码来体现。

## 14. 镜像缓存

### 14.1 问题

`fetch_image()` 原本把基础镜像下载到**每个虚拟机自己的目录**，转换完再删：

```bash
download_url "$url" "$d/base.img"      # d = /var/lib/ckvm/<名字>
qemu-img convert ... "$d/base.img" "$img"
rm -f "$d/base.img"                     # 用完即删
```

于是每开一台都要重新下载 600–900 MB。开三台就是三次。

### 14.2 做法

下载放进 `$CKVM_ROOT/.cache/`，按版本命名，所有虚拟机共用：

```bash
ckvm_cache_dir()  { echo "$CKVM_ROOT/.cache"; }
cache_base_path() { echo "$(ckvm_cache_dir)/ubuntu-${1}-arm64.img"; }
ensure_cached_base() {
    ...
    if [ -s "$base" ] && [ -f "$mark" ]; then
        ok_flash "使用缓存 ...（跳过下载）"
        return 0
    fi
    ...
}
```

`fetch_image()` 只做两件事：确保缓存里有，然后**从缓存复制**给这台虚拟机。

### 14.3 几个实现取舍

| 问题 | 处理 |
|---|---|
| 下载中断 | `download_url` 已按 `Content-Length` 校验大小，不匹配就重下；aria2c 负责续传 |
| 文件系统支持 reflink | `cp --reflink=auto`，不支持时自动退化为普通复制 |
| 复制很慢 | 大于 64 MB 时显示字节进度条（`copy_with_progress`） |
| 删虚拟机 | `ckvm rm` 只删 `/var/lib/ckvm/<名字>/`，`.cache` 不受影响 |
| 缓存损坏 | 旁边写一个 `.ok` 文件记录字节数和时间；大小对不上视为未完成 |

### 14.4 实测

```text
第一次  ckvm create testvm2 --rel 24.04
        source: https://mirror.nju.edu.cn/...ubuntu-24.04-server-cloudimg-arm64.img
        cached: 592M

第二次  ckvm create testvm3 --rel 24.04
        ✓ 使用缓存 Ubuntu 24.04（592M，跳过下载）
        复制基础镜像到 testvm3
```

第二次没有发起任何下载。

### 14.5 与多开的关系

缓存让"多开"从"每台都要等一次下载"变成"只在第一次等"。这是多开体验最
关键的一处改动 —— 其余部分（端口自动分配、独立目录、独立固件副本）本来
就是按多开设计的。


## 附：本机原始测量记录

CPU 拓扑（`/proc/cpuinfo`）：

```text
      6 0xd05     Cortex-A55
      2 0xd0b     Cortex-A76
```

ISV=0 现场（QEMU KVM 日志）：

```text
esr=920000c7  ec=24  isv=0  dfsc=07
pc=0000000000004670  pstate=EL1h
far=000000004007c000  ipa=9000
```

绑核对照（各 3 次）：

```text
taskset -c 6-7   -> 3 成功 / 0 失败
不绑核           -> 0 成功 / 3 失败
```

8 vCPU（绑核）：

```text
-smp 8 : started, serial=189717B, assert=0
guest: smp: Brought up 1 node, 8 CPUs
       SMP: Total of 8 processors activated
```

tap 模式：

```text
tap ckvm-taptest  172.28.100.1/24  UP
ip neigh          172.28.100.2 lladdr 52:54:00:12:34:56 REACHABLE
ping              2 transmitted, 2 received, 0% loss
ssh               172.28.100.2:22 -> SSH-2.0-OpenSSH_10.2p1 Ubuntu-2ubuntu3.6
```

下载速率（NJU，aria2 16 连接）：

```text
约 10 MB/s
```

网络可达性（容器内）：

```text
raw.githubusercontent.com   Connection reset by peer
github.com                  Connection reset by peer
git.yylx.win                404（只代理 git clone，不代理 raw）
ghproxy.net                 200
gh-proxy.com                200
mirror.nju.edu.cn           200
mirrors.ustc.edu.cn         200
```
