# ckvm — KVM 虚拟机管理器

在 MT6833 / everpal（小米天玑 810 机型）上跑**硬件加速**的 KVM 虚拟机。
装在 droidspaces 容器里，用 systemd 管理，支持多开。

> 这是 [`docs/KVM.md`](../docs/KVM.md) 里那套方案的成品化工具。

---

## 一键安装

```bash
curl -fsSLk https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager/kvm-vm.sh | bash -s -- install
```

### GitHub 被墙时

这台设备实测**直连 GitHub 会被重置连接**（`raw.githubusercontent.com`
和 `github.com` 都是 `Connection reset by peer`），用镜像即可：

```bash
# 镜像 1
curl -fsSLk https://git.yylx.win/github.com/ccmx200/kernel-lxc-xiaomi_mt6833/raw/resukisu/kvm_manager/kvm-vm.sh | bash -s -- install

# 镜像 2
curl -fsSLk https://ghproxy.net/https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager/kvm-vm.sh | bash -s -- install

# 镜像 3
curl -fsSLk https://gh-proxy.com/https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager/kvm-vm.sh | bash -s -- install
```

`install` 内部**自己也有镜像回退**：下载脚本和固件时会依次尝试上面这些源，
哪个通用哪个。所以只要你的网络能到其中任意一个，第一条命令就能装完。

也可以手动指定源：

```bash
curl -fsSLk <镜像地址>/kvm-vm.sh | bash -s -- install
# 或
REPO_LIST="https://git.yylx.win/github.com/ccmx200/kernel-lxc-xiaomi_mt6833/raw/resukisu" bash kvm-vm.sh install
```

### 想先看脚本内容

```bash
curl -fsSLk <上面任一个地址> -o /tmp/ckvm.sh
less /tmp/ckvm.sh
bash /tmp/ckvm.sh install
```

### 卸载

```bash
ckvm uninstall          # 只删脚本和服务，虚拟机数据保留
rm -rf /var/lib/ckvm    # 连数据一起删
```

---

## 一键安装做了什么

1. 把脚本装到 `/usr/local/bin/ckvm`
2. 下载固件到 `/usr/local/share/ckvm/firmware/`
3. 注册 systemd 模板服务 `/etc/systemd/system/ckvm@.service`

---

## 快速开始

```bash
ckvm create ubuntu26            # 下载镜像、建盘、配置，约 3 分钟
ckvm start ubuntu26             # 启动，约 30 秒到登录
ssh u0@127.0.0.1 -p 8023        # 密码 1
```

`create` 成功后会告诉你怎么连：

```text
  guest 'ubuntu26' created (port 8023, 8 vCPU, 2048 MiB, 50G)
  downloading https://mirror.nju.edu.cn/...
  image ready
  seed.img written (user u0 / password 1)

  start it with:  ckvm start ubuntu26
```

---

## 创建参数

```bash
ckvm create <名字> [选项]
```

| 选项 | 含义 | 默认 |
|---|---|---|
| `--cpus N` | vCPU 数量 | `8` |
| `--mem MB` | 内存 | `2048` |
| `--disk GB` | 磁盘容量 | `50` |
| `--rel V` | Ubuntu 版本 | `26.04` |
| `--port N` | 宿主机 SSH 端口 | 从 `8023` 起自动找空位 |

例如装一个 24.04 的小机器：

```bash
ckvm create small --cpus 2 --mem 1024 --disk 20 --rel 24.04
```

---

## 多开

每个虚拟机是 `/var/lib/ckvm/<名字>/` 下的独立目录，有自己的磁盘、固件副本、
cloud-init 和端口，互不干扰。

```bash
ckvm create a
ckvm create b
ckvm start a && ckvm start b
ckvm list
```

```text
  NAME             STATE    CPUS   MEM      DISK    PORT   SSH
  a                running  8      2048     50G     8023   ssh u0@127.0.0.1 -p 8023
  b                running  8      2048     50G     8024   ssh u0@127.0.0.1 -p 8024
```

端口自动分配，不用自己记，`ckvm list` 里能看到每台的连接方式。

---

## 命令一览

```bash
ckvm install                     # 安装
ckvm uninstall                   # 卸载

ckvm create <名字> [选项]         # 新建
ckvm image <名字>                # 重新下载镜像
ckvm start <名字> [-f]           # 启动（-f 前台运行）
ckvm stop <名字>
ckvm restart <名字>
ckvm rm <名字> [-f]              # 删除（-f 可删运行中的）

ckvm list                        # 所有虚拟机
ckvm status <名字>               # 详细状态 + 串口末尾
ckvm console <名字>              # 实时看串口，Ctrl-C 退出

ckvm enable <名字>               # systemd 启用 + 启动 + 开机自启
ckvm disable <名字>

ckvm config [名字]               # 看全局或单个配置
ckvm edit <名字>                 # 编辑单个配置
```

---

## systemd 管理

```bash
ckvm enable ubuntu26
```

之后用标准 systemd 命令：

```bash
systemctl status  ckvm@ubuntu26
systemctl stop    ckvm@ubuntu26
systemctl restart ckvm@ubuntu26
journalctl -u     ckvm@ubuntu26
```

`enable` 同时设置开机自启，容器重启后虚拟机自动起来。

---

## 配置

### 全局

脚本顶部，也可以用环境变量覆盖：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CKVM_ROOT` | `/var/lib/ckvm` | 虚拟机数据目录 |
| `CKVM_FWDIR` | `/usr/local/share/ckvm/firmware` | 固件目录 |
| `CKVM_BINDIR` | `/usr/local/bin` | 命令安装位置 |
| `MIRROR_IMAGE_LIST` | NJU + 官方 | 系统镜像源，按顺序回退 |
| `MIRROR_APT` | USTC | 写进 cloud-init 的 apt 源 |
| `REPO_LIST` | GitHub + 三个镜像 | 安装时取脚本和固件的源 |

### 单个虚拟机

`/var/lib/ckvm/<名字>/vm.conf`，改完 `ckvm restart <名字>` 生效：

```ini
NAME=ubuntu26
UBUNTU_REL=26.04
CPUS=8              # vCPU 数
MEM=2048            # 内存 MiB
DISK_GB=50
PORT=8023
CPUSET=6-7          # 绑定的物理核，别乱改，见下
VM_USER=u0
VM_PASS=1
VM_HOSTNAME=ubuntu26
```

---

## 镜像源（国内加速）

默认已配好：

```text
系统镜像：https://mirror.nju.edu.cn/ubuntu-cloud-images
         ↓ 失败则
         https://cloud-images.ubuntu.com

apt 源：  https://mirrors.ustc.edu.cn/ubuntu-ports
```

换源：

```bash
export MIRROR_IMAGE_LIST="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images"
export MIRROR_APT="https://mirrors.aliyun.com/ubuntu-ports"
curl -fsSLk <镜像地址>/kvm-vm.sh | bash -s -- install
```

> **实测提醒**：USTC 的 `ubuntu-cloud-images` 目录**只镜像了 amd64**，
> arm64 请求返回 403，所以镜像默认走 NJU。USTC 的 apt 源是正常的。

---

## 四个必须知道的坑

脚本都已处理，但理解它们能省很多时间。

### 1. 必须绑核（big.LITTLE）

这颗 SoC 是 6 个 Cortex-A55 + 2 个 Cortex-A76，**两种核心的 ID 寄存器值
不同**。不绑核时 QEMU 可能在一类核上探测 CPU 特性、在另一类核上写回，
内核发现"常量寄存器值不一致"就返回 `EINVAL`：

```text
Failed to put registers after init: Invalid argument
```

实测（各 3 次）：绑核 `3/3` 成功，不绑核 `0/3`。

脚本固定 `taskset -c 6-7` 绑到两个大核，**这就是 `CPUSET`，别乱改。**

> 绑核之后 **8 核也能用**（guest 内 `SMP: Total of 8 processors activated`）。
> 8 个 vCPU 跑在 2 个物理核上属于超卖，吞吐好但单核延迟一般。

### 2. 固件必须是不写 NVRAM 的那份

ARM 规定：带 writeback 的 load/store（以及 `LDXR/STXR`）**永不置
`ESR_EL2.ISV` 位**，而 KVM 无法解码 ISV=0 的 MMIO。标准 EDK2 写 pflash
变量存储时恰好用这类指令，于是虚拟机直接卡死。

解法是用不写 NVRAM 的 EDK2（本目录的 `edk2_qemu_aarch64_nonvram.fd`）。

### 3. NVRAM 每次要刷新

留着旧变量存储会让 GRUB 加载后卡住不动。脚本每次 `start` 都从模板拷一份
干净的 `edk2_vars.fd`。

### 4. 不能用 `-kernel` 直接引导 Ubuntu 内核

26.04 的 `/boot/vmlinuz-*` 是 **PE32+ EFI 应用**，QEMU 的 arm64 加载器只
接受 gzip 或裸 `Image`。所以必须走 UEFI，也就是上面这套。

---

## 自测环境

```text
设备    小米 MT6833 / everpal
容器    droidspaces（Debian 13，systemd 作为 PID 1）
内核    4.14.356-Everpal-KVM-CuiCanMX-v1.0
guest   Ubuntu 26.04.1 LTS，kernel 7.0.0-38，50G 磁盘自动扩容
```

已验证：单机启动、双机同时运行（8023 + 8024）、`ckvm enable` 后 systemd
单元 `active` 且 `enabled`、干净环境下一键安装（自动取脚本 + 自动取固件）。

---

## 常见问题

**`Failed to put registers after init`**
绑核没生效。确认 `vm.conf` 里 `CPUSET` 是 `6-7`，且脚本用的是
`taskset -c "$CPUSET"`。

**GRUB 加载后卡住不动**
NVRAM 被污染。停掉虚拟机，删掉 `uefi-vars.fd`，再 `start`（会从模板重建）。

**curl 安装时 Connection reset**
GitHub 被墙。换用本文档「GitHub 被墙时」里的镜像地址，或直接给
`REPO_LIST` 指定一个可达的源。

**找不到固件**
```bash
ckvm install        # 会从仓库（或其镜像）下载
```
或从设备上拷：
```bash
su -c 'mkdir -p /sdcard/limbo_fw && cp /data/data/com.limbo.emu.main.arm/cache/limbo/edk2/*.fd /sdcard/limbo_fw/'
su -c 'cp /sdcard/limbo_fw/edk2_*.fd /usr/local/share/ckvm/firmware/'
```

**想换用户名密码**
改 `vm.conf` 里的 `VM_USER` / `VM_PASS`，然后 `ckvm rm` 重建
（cloud-init 只在首次启动生效），或者进系统直接 `passwd`。

**想要图形界面**
脚本只给了串口。自己加 `-device virtio-gpu-pci` 配 VNC，或在 `ckvm start`
的 QEMU 参数里追加。
