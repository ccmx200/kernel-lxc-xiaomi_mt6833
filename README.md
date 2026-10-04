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

内核已经带 KVM，可以直接在这台手机上跑一个完整的 Ubuntu 虚拟机，
而且是**硬件加速**的（不是模拟），装了 UEFI 固件所以**能装系统、能跑 Windows**。

如果你只想用、不想理解原理，照着下面做就行。
想了解"为什么必须这么配"的，看 [`docs/KVM.md`](docs/KVM.md)。

### 一句话原理

虚拟机要有两个东西：**固件**（相当于电脑的 BIOS）和**系统盘**。

- 固件：**必须用不写 NVRAM 的那个版本**。普通固件一写就会让虚拟机卡死，
  这是硬伤，不是配置问题。脚本里已经帮你换好了。
- 系统盘：一个 qcow2 文件，里面是 Ubuntu。

### 准备工作（只需做一次）

把两个文件放到一个目录里，比如 `/root/vm26/`：

| 文件 | 是什么 | 从哪来 |
|---|---|---|
| `disk.qcow2` | Ubuntu 系统盘 | 官方 cloud image 转成 qcow2，可扩容 |
| `uefi-code.fd` | 不写 NVRAM 的固件 | Limbo 项目的 `edk2_qemu_aarch64_nonvram.fd` |
| `seed.img` | 开机自动建账号用 | `cloud-localds` 生成，见下 |

`seed.img` 用来开机自动创建用户名和密码，内容长这样（存成 `user-data`）：

```yaml
#cloud-config
hostname: ubuntu2604
users:
  - name: u0_207
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: <用 openssl passwd -6 '密码' 生成>
ssh_pwauth: true
disable_root: false
```

然后：

```bash
cloud-localds seed.img user-data meta-data
```

### 日常使用

启动脚本已经放在仓库里，也复制到了容器的 `/root/kvm-vm.sh`：

```bash
bash /root/kvm-vm.sh start     # 开机
bash /root/kvm-vm.sh status    # 看状态、看串口
bash /root/kvm-vm.sh console   # 实时看画面（串口文字）
bash /root/kvm-vm.sh stop      # 关机
```

约 30 秒后会出现登录提示。**开机大约需要半分钟**，别急。

### 登录

虚拟机里的 SSH 映射在容器的 `8023` 端口：

```bash
ssh u0_207@127.0.0.1 -p 8023      # 密码：1
```

如果要从电脑（不是容器里）连，先开一条隧道：

```bash
plink -pw 1 -N -L 8023:127.0.0.1:8023 -P 22 root@<手机IP>
ssh u0_207@127.0.0.1 -p 8023
```

### 几个必须知道的坑

1. **别开 8 核**。4 核是上限，开 8 个固件会直接崩。脚本里已经固定成 4。
2. **别用 `-kernel` 直接引导**。这个镜像的内核是 PE32+ 格式，QEMU 不认。
   必须走 UEFI（也就是上面这套）。
3. **启动失败报 `Failed to put registers` 时，看绑核**。这台机器是
   大小核（6 个 A55 + 2 个 A76），QEMU 不绑核会随机失败。脚本里已经用
   `taskset -c 6-7` 绑到大核上了，**别去掉**。
4. **没有图形界面**，现在只有串口文字。要 VNC 自己加
   `-device virtio-gpu-pci`。

### 实测效果

```text
Ubuntu 26.04.1 LTS
内核    7.0.0-38-generic
CPU     3 核
内存    1946 MiB
磁盘    48G（50G 盘，已自动扩容）
```

---

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
