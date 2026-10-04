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
