# KVM on MT6833 / everpal — 技术说明

面向想搞清楚原理或要改这套东西的人。只想用虚拟机的看根目录 `README.md`。

---

## 1. 硬件与特权级前提

- SoC：联发科 MT6833（天玑 810），ARM64 **big.LITTLE**
  （6×Cortex-A55 `0xd05` @2.0GHz + 2×Cortex-A76 `0xd0b` @2.4GHz）
- 厂商固件在移交内核时**占据了 EL2 但没有实现任何功能**，所以内核以
  **nVHE** 方式运行（`CONFIG_ARM64_VHE=y`，内核自身在 EL2）
- 因此**不存在** Pixel pKVM 的 `kvm-arm.mode=protected/nvhe` 开关

配置：

```text
CONFIG_KVM=y
CONFIG_VIRTUALIZATION=y
CONFIG_ARM64_VHE=y
# CONFIG_LTO_CLANG is not set
CONFIG_LTO_NONE=y
```

---

## 2. 核心障碍：`ESR_EL2.ISV == 0`

### 2.1 内核侧原本的行为

4.14 的 stage-2 MMIO 路径：

```c
/* virt/kvm/arm/mmio.c */
if (kvm_vcpu_dabt_isvalid(vcpu)) {
        ret = decode_hsr(vcpu, &is_write, &len);
        ...
} else {
        kvm_err("load/store instruction decoding not implemented\n");
        return -ENOSYS;              /* vCPU -> paused (internal-error) */
}
```

硬件在 ESR 里给出 ISV（有效指令综合征）时，内核能直接读到
读/写方向、访问宽度、目标寄存器。ISV=0 时这些信息**一个都没有**。

### 2.2 为什么 ISV 会是 0

ARM 架构规定，**只有单寄存器、无 writeback、非 exclusive 的
load/store** 才会置 ISV 位。以下情况**必然 ISV=0**：

- 带 writeback 的 load/store（如后索引 `ldr x0, [x1], #4`）
- `LDP/STP`（成对访问）
- `LDXR/STXR`（exclusive）
- 各类原子指令

实测现场（EDK2 写 pflash NVRAM 时）：

```text
esr=920000c7  ec=24 (DABT lower EL)  isv=0  dfsc=07
pc=0000000000004670  pstate=EL1h
far=000000004007c000  ipa=9000
```

`0x4007c000` 正是 QEMU virt 机型 pflash 变量区（64MB 块内偏移 `0x7c000`）。

QEMU 维护者的立场（qemu-arm 邮件列表）：

> "Don't do this -- KVM doesn't support it. For access to MMIO, stick to
> instructions which will set the ISV bit in ESR_EL1."

即：**这不是内核 bug，是架构层面的既有约束。**

---

## 3. 我们做的内核回移

上游的解法不是在内核里解码指令，而是**上报给用户态**。4.14 没有这套
机制，所以补齐了两块：

### 3.1 `KVM_EXIT_ARM_NISV` + `KVM_CAP_ARM_NISV_TO_USER`（177）

内核遇到 ISV=0 时，不再返回 `-ENOSYS`，而是把这次退出交给 VMM：

```c
run->exit_reason = KVM_EXIT_ARM_NISV;
run->arm_nisv.esr_iss   = kvm_vcpu_dabt_iss_nisv_sanitized(vcpu);
run->arm_nisv.fault_ipa = fault_ipa;
```

### 3.2 `KVM_CAP_ARM_INJECT_EXT_DABT`（178）

QEMU 收到 NISV 退出后**不做指令解码**，它需要内核支持把外部数据中止
注入 guest：

```c
/* QEMU target/arm/kvm.c */
if (cap_has_inject_ext_dabt) {
    events.exception.ext_dabt_pending = 1;
    kvm_vcpu_ioctl(CPU(cpu), KVM_SET_VCPU_EVENTS, &events);
    return 0;
} else {
    error_report("KVM unable to emulate faulting instruction.");
}
return -1;      /* 走到这里 QEMU 直接退出 */
```

本内核原本该能力返回 0，所以 QEMU 直接放弃。补齐后返回 1。

### 3.3 涉及文件

```text
include/uapi/linux/kvm.h                    EXIT_ARM_NISV / 两个 CAP
arch/arm64/include/uapi/asm/kvm.h           __KVM_HAVE_VCPU_EVENTS + 结构体
arch/arm64/include/asm/kvm_host.h           return_nisv_io_abort_to_user
arch/arm64/include/asm/kvm_emulate.h        iss_nisv_sanitized()
arch/arm64/kvm/guest.c                      __kvm_arm_vcpu_{get,set}_events
arch/arm64/kvm/reset.c                      上报能力
virt/kvm/arm/arm.c                          ENABLE_CAP / VCPU_EVENTS ioctl
virt/kvm/arm/mmio.c                         ISV=0 改走 NISV
```

### 3.4 ABI 注意

`struct kvm_vcpu_events` 在 4.14 里**不存在**（5.9 才进主线），本次新增。
布局按上游 5.10 对齐，`ext_dabt_pending` 落在原有填充字节内：

```text
size=64  exception=16  serror_esr@8  reserved@16
ext_dabt_pending @2
```

`sizeof` 与所有字段偏移均未改变，QEMU 不会读错位。

### 3.5 效果与局限

| | 之前 | 之后 |
|---|---|---|
| vCPU 状态 | `paused (internal-error)`，cpu 0.2s | 持续运行，cpu 29s / 25 次退出 |
| 结果 | 立即死 | **活锁**（CPU 满载、无进展） |

**关键结论：这套回移不能解决固件问题。** 注入外部数据中止只是告诉 guest
"这个地址有问题"，无法代替真正的访问模拟；固件收到后只能重试，
于是变成活锁。

真正的解法是**换固件**（见下）。

---

## 4. 最终方案：不写 NVRAM 的 EDK2

Limbo 项目（`wasdwasd0105/limbo_tensor`）为 protected KVM 场景专门构建了
一份不写 NVRAM 的固件。其 README 说明：

> **Enable**: Loads a full version UEFI firmware that can save EFI variables
> to NVRAM pflash.
> **Disable**: Loads a modified version that bypasses NVRAM write.

文件从 APK 的 `assets/roms/edk2/` 取出：

```text
edk2_qemu_aarch64_nonvram.fd   sha256 becc95919db490cd819df8ec89f7d51eae1d146b50d44f7a73b6e01905cd8cc4
edk2_vars.fd                   sha256 b3b855c5a80310168051164986855692d1bdb06e67619856177965cd87c6774f
```

换用后：UEFI 正常启动到 shell / 正常引导系统，
**`dmesg` 中 NISV abort 计数为 0** —— 那次访问根本不再发生。

---

## 5. 运行期的三个坑（都已固化进 `kvm-vm.sh`）

### 5.1 vCPU 数量只能是 4

- `-smp 8` → 固件断言失败
  `ASSERT [ArmPlatformPrePeiCore] .../MainUniCore.c(17)`
- `-smp 1/2` → vCPU 创建报 `Failed to put registers after init: Invalid argument`

Limbo 的 "100% Success Mode" 也是先跑 4 核、进系统后再放开。

### 5.2 KVM vCPU 创建是间歇性的

每次 guest 退出后紧接着启动，**第一次几乎必失败**（EINVAL）。规避方式：

1. 先 `kill -15` 优雅退出，等 5s，再 `kill -9`，再等 5s
2. 起一个一次性 1 核小 guest 作预热，退出后再起正式的

### 5.3 NVRAM 变量存储必须每次刷新

反复启动会用旧变量存储，表现为 **GRUB 加载后卡死**（CPU 满载、串口不动）。
每次启动前从模板 `cp` 一份干净的即可。

---

## 6. 为什么不能用 `-kernel`

Ubuntu 26.04 的 `/boot/vmlinuz-*` 是 **PE32+ EFI 应用**：

```text
vmlinuz: PE32+ executable for EFI (application), ARM64
```

QEMU 的 arm64 `-kernel` 加载器只接受 **gzip 压缩的 `Image`** 或**裸 `Image`**
（要求偏移 56 处有 magic `0x644d5241`）。PE32+ 会被拒绝。

`objcopy -O binary` 抠出来的裸镜像会丢掉 arm64 头，需要手工补 64 字节头：

```text
0x00 code0        u32
0x04 code1        u32   (b .+64)
0x08 text_offset  u64
0x10 image_size   u64
0x18 flags        u64
0x20 res4         u64
0x28 res5         u64
0x30 res6         u64
0x38 magic        u32   = 0x644d5241
0x3C res7         u32
```

补完后 `-kernel` 可用（已实测），但仍推荐走 UEFI，因为 UEFI 通用性更好
（能装系统、能跑 ISO / Windows）。

---

## 7. 实测结果

```text
PRETTY_NAME="Ubuntu 26.04.1 LTS"
kernel        7.0.0-38-generic
vCPU          3        (-smp 4，guest 保留 1 个)
Memory        1946 MiB
/dev/root     48G  2% used     (50G 磁盘，cloud-init 已自动扩容)
```

启动约 30 秒到登录提示。完整参数见 `kvm-vm.sh`。
