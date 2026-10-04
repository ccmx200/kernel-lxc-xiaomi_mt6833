# Everpal / MT6833 Kernel

ReSukiSU + KVM + BBRv2 + zstd/lz4 + Binder 优化内核。

## 基本信息

- 设备：xiaomi MT6833 / everpal
- 内核版本：Linux 4.14.356
- 当前版本号：
  ```text
  4.14.356-Everpal-KVM-CuiCanMX-v1.0
  # uname -r -> 4.14.356-Everpal-KVM-CuiCanMX-v1.0
  ```
- 默认 defconfig：
  ```text
  arch/arm64/configs/everpal_defconfig
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

#### 重要限制：UEFI 固件写 NVRAM 会卡死

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


## 在 KVM 上运行 Ubuntu 26.04（实机验证可用）

下面是本内核在 MT6833 / everpal 上实际跑通 Ubuntu 26.04 guest 的完整方案。

### 为什么不能直接用标准 UEFI 固件

ARM 规定：**带 writeback 的 load/store（如后索引 `ldr x0, [x1], #4`）以及
`LDXR/STXR` 这类指令永不置 `ESR_EL2.ISV` 位**，而 QEMU 的 NISV 处理器不做
指令解码，只能把外部数据中止注入 guest，无法代替真正的指令模拟。
标准 EDK2/AAVMF 在写 pflash NVRAM 变量时恰好使用这类指令，于是：

```text
kvm: load/store instruction decoding not implemented
vCPU -> paused (internal-error)   （旧内核）
        或 活锁（打上 NISV 回移后，CPU 满载但无进展）
```

解决办法是**换一个不写 NVRAM 的 EDK2 固件**。本方案使用 Limbo 项目随 APK
分发的 `edk2_qemu_aarch64_nonvram.fd`。换用后 UEFI 正常启动，`dmesg` 中
NISV abort 计数为 0。

### 文件准备

```text
/root/vm26/disk.qcow2       Ubuntu 26.04 系统盘（qcow2，50G 虚拟）
/root/vm26/uefi-code.fd     非易失变量版 EDK2（edk2_qemu_aarch64_nonvram.fd）
/root/vm26/uefi-vars.fd     NVRAM 变量存储（每次启动前从模板复制一份干净的）
/root/vm26/seed.img         cloud-init，创建用户 u0_207 / 密码 1
```

### 启动脚本

```bash
#!/bin/bash
# 1) 停掉旧 guest（先温柔后强制，务必留出间隔）
for p in $(pgrep -f qemu-system-aarch64); do kill -15 "$p"; done
sleep 5
for p in $(pgrep -f qemu-system-aarch64); do kill -9 "$p"; done
sleep 5

# 2) 干净 NVRAM（关键：被污染的变量存储会让 GRUB 卡死）
cp -f /root/limbo_fw/edk2_vars.fd /root/vm26/uefi-vars.fd

# 3) 预热：首个 KVM guest 常因 EINVAL 启动失败，先跑一个一次性的
/usr/bin/qemu-system-aarch64 -name warm -M virt,gic-version=3 -cpu max \
  -accel kvm -smp 1 -m 512 -display none -serial null >/dev/null 2>&1 &
sleep 5; kill -15 %1 2>/dev/null; sleep 4; kill -9 %1 2>/dev/null; sleep 2

# 4) 正式启动
nohup /usr/bin/qemu-system-aarch64 -name ubuntu2604 \
  -M virt,gic-version=3 -cpu max -accel kvm -smp 4 -m 2048 \
  -drive if=pflash,format=raw,unit=0,file=/root/vm26/uefi-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/root/vm26/uefi-vars.fd \
  -drive if=virtio,format=qcow2,file=/root/vm26/disk.qcow2 \
  -drive if=virtio,format=raw,readonly=on,file=/root/vm26/seed.img \
  -netdev user,id=n0,hostfwd=tcp:0.0.0.0:8023-:22 \
  -device virtio-net-pci,netdev=n0 -device virtio-rng-pci \
  -display none -serial file:/tmp/kvm.log \
  > /tmp/kvm.err 2>&1 &
```

约 30 秒后串口出现登录提示：

```text
ubuntu2604 login:
```

### 登录

容器内 `8023` 即 guest 的 `22`：

```bash
ssh u0_207@127.0.0.1 -p 8023      # 密码 1
```

从局域网访问需要经宿主机转发，或在本地建立隧道：

```bash
plink -pw 1 -N -L 8023:127.0.0.1:8023 -P 22 root@<宿主IP>
ssh u0_207@127.0.0.1 -p 8023
```

### 实测结果

```text
PRETTY_NAME="Ubuntu 26.04.1 LTS"
kernel        7.0.0-38-generic
vCPU          3        (-smp 4，guest 保留 1 个)
Memory        1946 MiB
/dev/root     48G  2% used     (50G 磁盘，cloud-init 已自动扩容)
```

### 已知限制与坑

1. **vCPU 数量**：`-smp 4` 是可用的上限，`-smp 8` 会让固件断言失败
   （`ASSERT [ArmPlatformPrePeiCore]`）。Limbo 的"100% Success Mode"也是
   先跑 4 核。少于 4 核（1/2）在本内核上同样会 `Failed to put registers`。
2. **KVM vCPU 创建是间歇性的**：每次销毁 guest 后紧接着启动，首次常报
   `Failed to put registers after init: Invalid argument`。上面脚本里的
   **间隔 + 预热 guest** 是为规避它，实测有效。
3. **NVRAM 必须每次用干净副本**：反复启动会污染变量存储，表现为 GRUB 加载
   后卡死（CPU 满载、串口不动）。
4. **不要用 `-kernel` 引导该镜像的内核**：26.04 的 `/boot/vmlinuz-*` 是
   PE32+ EFI 应用，QEMU 的 arm64 加载器只接受 gzip 或裸 `Image`。
5. **`-display none`**：本方案只有串口。要图形界面需自行加
   `-device virtio-gpu-pci` 配合 VNC。

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
ReSukiSU-AdrenalinKernel-YYYYMMDD-HHMM.zip
```

## 刷入

请自行使用 fastboot / magiskboot 等方式刷入对应 boot 镜像。

刷机前务必备份原 boot。

## License

内核源码遵循其原始 GPL-2.0 许可证。
ReSukiSU、Linux 内核回移代码等遵循各自原始许可证。
