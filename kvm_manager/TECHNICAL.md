# ckvm 技术文档

本文解释 **为什么** ckvm 要这么写。每条结论都给出出处或本机实测数据。
面向需要排查问题、移植到别的机型、或想改这套东西的人。

用户向的用法说明在 [README.md](README.md)。

---

## 目录

1. [目标环境与特权模型](#1-目标环境与特权模型)
2. [核心障碍：ESR_EL2.ISV == 0](#2-核心障碍esr_el2isv--0)
3. [内核回移](#3-内核回移)
4. [固件：为什么必须是不写 NVRAM 的 EDK2](#4-固件为什么必须是不写-nvram-的-edk2)
5. [big.LITTLE 与 CPU 绑核](#5-biglittle-与-cpu-绑核)
6. [网络：user 与 tap 两种模式](#6-网络user-与-tap-两种模式)
7. [下载子系统](#7-下载子系统)
8. [systemd 与安装流程](#8-systemd-与安装流程)
9. [实测数据集](#9-实测数据集)
10. [参考出处](#10-参考出处)
11. [在红米 Note 11 5G（MT6833）上禁用 GenieZone 并释放 EL2](#11-在红米-note-11-5gmt6833上禁用-geniezone-并释放-el2)

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

## 5. big.LITTLE 与 CPU 绑核

### 5.1 现象

不绑核时 QEMU 报：

```text
qemu-system-aarch64: Failed to put registers after init: Invalid argument
```

且**时好时坏**。

### 5.2 根因

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

### 5.3 验证

同一套配置各跑 3 次：

```text
taskset -c 6-7    ->  3 成功 / 0 失败
不绑核            ->  0 成功 / 3 失败
```

### 5.4 关于 vCPU 数量

绑核之前观察到 `-smp 8` 会让固件断言
（`ASSERT [ArmPlatformPrePeiCore]`），曾误判为"固件不支持 8 核"。

**实测证明并非如此。** 绑核后：

```text
-smp 2 / 4 / 6 / 8   全部启动，assert=0
-smp 8 完整启动到登录提示
guest 内：smp: Brought up 1 node, 8 CPUs
         SMP: Total of 8 processors activated
```

之前的断言是**同一个绑核问题的另一种表现**。

> 注意：8 个 vCPU 压在 2 个物理大核（`CPUSET=6-7`）上属于超卖，吞吐好但
> 单核延迟会变差。

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

**默认是 GitHub 官方地址，不做任何加速或改写。** 加速需显式请求：

#### 为什么 URL 用 `refs/heads/<branch>`

GitHub 的加速镜像按 **URL 路径**缓存。实测同一个仓库、同一份文件：

```text
.../resukisu/kvm_manager/kvm-vm.sh             51871 bytes   stale
.../refs/heads/resukisu/kvm_manager/kvm-vm.sh  56456 bytes   FRESH
```

响应头证实了缓存行为：

```text
cache-control: max-age=300
x-cache: HIT
x-cache-hits: 24
```

裸分支名命中了缓存条目（`HIT`，已命中 24 次），而完整 ref 路径是新的
缓存键。两者内容相同，只是路径写法不同 —— 所以脚本统一使用
`refs/heads/resukisu`。

```bash
install -cn                    # 探测内置列表
install -cn <url>              # 用用户自己的地址
install --repo <url>
CKVM_ACCEL=<url>
```

`-cn <url>` 接受三种形式，都会自动补上仓库路径（`normalise_mirror()`）：

| 输入 | 规范化结果 |
|---|---|
| `https://ghproxy.net/https://raw.githubusercontent.com` | 原样使用（已含完整前缀） |
| `https://ghproxy.net` | `https://ghproxy.net/github.com/ccmx200/...` |
| `ghproxy.net` | `https://ghproxy.net/github.com/ccmx200/...` |
| `https://p/{url}` 或 `https://p/%s` | 占位符替换为真实 GitHub 地址 |

用户给的地址不通时**明确报错并回落 GitHub**，不静默换源。

本机实测：`raw.githubusercontent.com` 与 `github.com` 均
`Connection reset by peer`（TLS 被重置）；`git.yylx.win`、`ghproxy.net`、
`gh-proxy.com` 均返回 200。

### 7.4.1 为什么要校验下载

`install` 之前会把镜像返回的**任何**字节直接写进 `/usr/local/bin/ckvm`。
两种失败都真实发生过：

| 情况 | 症状 |
|---|---|
| 镜像发旧版本 | 缺少新命令（`ckvm versions` 报 usage） |
| 响应被截断（实测抓到 2993 字节的错误响应） | 脚本解析到一半失败，运行时报 `--fwd: command not found` |

现在下载必须通过全部检查才会替换目标文件：

```bash
verify_download() {
    head -1 "$f" | grep -q '^#!/bin/bash'   || return 1
    grep -q 'CKVM_BUILD=' "$f"              || return 1   # 版本标记
    grep -q 'cmd_versions()' "$f"           || return 1   # 特征函数
    bash -n "$f" 2>/dev/null                || return 1   # 能解析
}
```

脚本顶部因此有一个 `CKVM_BUILD` 标记，新功能上线时一并更新。

---

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
设备     小米 MT6833 / everpal
容器     droidspaces Debian 13，systemd 为 PID 1
内核     4.14.356-Everpal-KVM-CuiCanMX-v1.0
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

> **设备代号的说明**：本节的 `evergo` 指 **Redmi Note 11 5G**。本文第 1 章的
> 实测数据来自代号 `everpal` 的设备（同为 MT6833）。两者是**不同的机器**，
> 第 11 章以外的内容与本节没有直接的设备对应关系，请勿混用。

### 11.11 致谢（重申）

再次感谢酷安用户 **jsbsbxjxh66** 开发并开源了
`mtk-soc-disable-geniezone`。该项目的检测脚本准确识别了 preloader 特性，
修改脚本安全高效地完成了 GPT 越界 LBA 改写与 CRC 校验更新，使得在不修改
preloader 代码、不破坏签名验证的前提下，成功禁用 GenieZone 并释放 EL2。

---

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
git.yylx.win                200
ghproxy.net                 200
gh-proxy.com                200
mirror.nju.edu.cn           200
mirrors.ustc.edu.cn         200
```
