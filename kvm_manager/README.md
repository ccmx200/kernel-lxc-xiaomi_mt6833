# ckvm — KVM 虚拟机管理器

在 MT6833 / everpal（小米天玑 810 机型）上跑**硬件加速**的 KVM 虚拟机。
装在 droidspaces 容器里，用 systemd 管理，支持多开。

> 想了解**为什么**这么设计、每处改动的依据和实测数据，
> 看 **[TECHNICAL.md](TECHNICAL.md)**。
> 本文只讲怎么用。

---

## 一键安装

```bash
curl -fsSLk https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager/kvm-vm.sh | bash -s -- install
```

**默认走 GitHub 官方源**，脚本不做任何加速、不改写地址。

装完你会得到：

1. `/usr/local/bin/ckvm` —— 命令
2. `/usr/local/share/ckvm/firmware/` —— UEFI 固件
3. `/etc/systemd/system/ckvm@.service` —— systemd 模板单元

### 用加速

```bash
# 用你自己的加速地址（推荐）
install -cn https://你的加速地址

# 只给主机名也行，会自动补上仓库路径
install -cn ghproxy.net

# 模板形式
install -cn "https://你的代理/{url}"

# 不带参数：探测内置列表
install -cn
```

`--repo <url>` 是等价写法，`CKVM_ACCEL=<url>` 也行。

> 为什么建议**先手动抓脚本再 install**：`curl | bash` 那一跳本身也要过网络。
> GitHub 不通时 `curl` 就已经失败，轮不到 `-cn` 生效。
>
> ```bash
> curl -fsSLk <能通的地址>/kvm-vm.sh -o /tmp/ckvm.sh
> bash /tmp/ckvm.sh install -cn https://你的加速地址
> ```

### 卸载

```bash
ckvm uninstall          # 只删命令和服务，虚拟机数据保留
rm -rf /var/lib/ckvm    # 连数据一起删
```

---

## 快速开始

```bash
ckvm create ubuntu26            # 下载镜像、建盘、配置，约 3 分钟
ckvm start ubuntu26             # 启动，约 30 秒到登录
ssh u0@127.0.0.1 -p 8023        # 密码 1
```

`create` 会告诉你怎么连：

```text
  guest 'ubuntu26' created (port 8023, 8 vCPU, 2048 MiB, 50G)
  network: user (forwards: 22)
  download backend: aria2c
  source: https://mirror.nju.edu.cn/ubuntu-cloud-images/...
  image ready
  seed.img written (user u0 / password 1)

  start it with:  ckvm start ubuntu26
```

下载时会有进度条：

```text
  ⠼ ██░░░░░░░░░░░░░░░░░░░░░░   8%  76M
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
| `--net M` | 网络模式 `user` / `host` | `user` |
| `--fwd L` | 要映射的 guest 端口 | `22` |

例子：

```bash
# 小机器
ckvm create small --cpus 2 --mem 1024 --disk 20 --rel 24.04

# 多开两个端口映射
ckvm create web --fwd 22,80,443

# guest 80 映射到宿主机 8080
ckvm create app --fwd 22,8080:80
```

---

## 多开

每台虚拟机是 `/var/lib/ckvm/<名字>/` 下的独立目录，有自己的磁盘、固件副本、
cloud-init 和端口。

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

端口自动分配，不用自己记。

---

## 命令一览

```bash
ckvm install [选项]              # 安装
ckvm uninstall                   # 卸载

ckvm create <名字> [选项]         # 新建
ckvm image <名字>                # 重新下载镜像
ckvm start <名字> [-f]           # 启动（-f 前台）
ckvm stop <名字>
ckvm restart <名字>
ckvm rm <名字> [-f]              # 删除（-f 可删运行中的）

ckvm list                        # 所有虚拟机
ckvm status <名字>               # 详细状态 + 串口末尾
ckvm console <名字>              # 实时看串口，Ctrl-C 退出

ckvm enable <名字>               # systemd 启用 + 启动 + 开机自启
ckvm disable <名字>

ckvm net [名字]                  # 看网络情况
ckvm config [名字]               # 看配置
ckvm edit <名字>                 # 改配置
```

---

## 网络

### user 模式（默认）

QEMU 自己做 NAT，用端口映射访问。任何环境都能用。

```bash
ckvm create web --fwd 22,80,443
ckvm start web
```

```text
  network: user-mode NAT
    ssh u0@127.0.0.1 -p 8023   (password: 1)
    port 80 -> 127.0.0.1:80
    port 443 -> 127.0.0.1:443
```

规则：guest 的 `22` 映射到该机的 `PORT`（多开不抢端口）；其他端口默认同号，
也可写 `宿主机端口:guest端口`。启动前会检查端口占用。

### host 模式（tap）

guest 拿到自己的 IP，**自己跑 sshd**，不需要端口映射，也不经过 droidspaces
的转发，和容器自身的 22 不冲突。

```bash
ckvm create srv --net host
ckvm start srv
```

```text
  network: tap, the guest is on this container's network
    guest ip : 172.28.100.2/24   gateway 172.28.100.1
    ssh      : u0@172.28.100.2   (password: 1)
```

脚本自动建 tap、配 IP、开转发和 NAT，`stop`/`rm` 自动清理。

### ⚠️ 局域网访问

**host 模式的 `172.28.100.x` 是容器内部网段，不是手机在局域网上的地址。**
局域网里其他电脑直连不到。

想真正暴露到局域网：

- **简单**：用 user 模式，在 Android 宿主侧把端口转进容器
- **彻底**：在 Android 宿主侧建网桥（见 [TECHNICAL.md](TECHNICAL.md) 第 6.4 节）

`ckvm net <名字>` 会打印当前布局和下一步提示。

---

## systemd

```bash
ckvm enable ubuntu26
systemctl status  ckvm@ubuntu26
systemctl stop    ckvm@ubuntu26
systemctl restart ckvm@ubuntu26
journalctl -u     ckvm@ubuntu26
```

`enable` 同时设置开机自启。

---

## 配置

### 全局

| 变量 | 默认 | 说明 |
|---|---|---|
| `CKVM_ROOT` | `/var/lib/ckvm` | 数据目录 |
| `CKVM_FWDIR` | `/usr/local/share/ckvm/firmware` | 固件目录 |
| `CKVM_BINDIR` | `/usr/local/bin` | 命令安装位置 |
| `MIRROR_IMAGE_LIST` | NJU + 官方 | 系统镜像源，按顺序回退 |
| `MIRROR_APT` | USTC | 写进 cloud-init 的 apt 源 |
| `CKVM_ACCEL` | `0` | 加速地址，或 `1` 表示探测内置列表 |
| `CKVM_NO_APT` | `0` | 设 `1` 禁止自动 apt 安装 aria2 |
| `NO_COLOR` | — | 设置后关闭颜色 |

### 单个虚拟机

`/var/lib/ckvm/<名字>/vm.conf`，改完 `ckvm restart <名字>` 生效：

```ini
NAME=ubuntu26
UBUNTU_REL=26.04
CPUS=8
MEM=2048
DISK_GB=50
PORT=8023
CPUSET=6-7          # 绑定的物理核，别乱改
NET_MODE=user
FORWARDS=22
VM_USER=u0
VM_PASS=1
VM_HOSTNAME=ubuntu26
```

---

## 镜像源

默认：

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
curl -fsSLk <地址> | bash -s -- install
```

> 实测提醒：USTC 的 `ubuntu-cloud-images` **只镜像了 amd64**，arm64 返回
> 403，所以镜像默认走 NJU。

---

## 三个别踩的坑

### 1. 别去掉 `taskset` 绑核

这台机器是 big.LITTLE（6 个 A55 + 2 个 A76），寄存器值不同。不绑核会随机
启动失败：

```text
Failed to put registers after init: Invalid argument
```

脚本固定 `taskset -c 6-7`，**这就是 `CPUSET`，别乱改**。

> 绑核之后 **8 核也能用**。

### 2. 固件必须是不写 NVRAM 的那份

普通 EDK2 一写变量存储就会让虚拟机卡死（ARM 架构限制，详见
[TECHNICAL.md](TECHNICAL.md) 第 2、4 节）。`kvm_manager/` 里附带的就是正确
的那份，`install` 会自动放好。

### 3. 不能用 `-kernel` 直接引导 Ubuntu 内核

26.04 的 `/boot/vmlinuz-*` 是 PE32+ EFI 应用，QEMU 的 arm64 加载器只接受
gzip 或裸 `Image`。必须走 UEFI。

---

## 自查

```bash
ckvm net                 # 容器网卡、路由、各虚拟机网络模式
ckvm net <名字>          # 单机的 tap、NAT 规则、访问方式
ckvm status <名字>       # 状态 + 串口末尾
ckvm config <名字>       # 该机配置
```

---

## 常见问题

**`Failed to put registers after init`**
绑核没生效。确认 `vm.conf` 里 `CPUSET=6-7`。

**GRUB 加载后卡住不动**
NVRAM 被污染。`ckvm stop <名字>`，删掉该目录下的 `uefi-vars.fd`，再
`ckvm start`（会从模板重建）。

**curl 报 `Connection reset by peer`**
GitHub 被墙。换用加速地址，或先手动抓脚本再用 `install -cn`。

**`ckvm install` 报 `could not download kvm-vm.sh`**
你的加速地址不通，或没给 `-cn`。失败**不会**破坏已装好的 ckvm。

**找不到固件**
```bash
ckvm install            # 会从仓库（或其加速地址）下载
```
或从设备上拷：
```bash
su -c 'mkdir -p /sdcard/limbo_fw && cp /data/data/com.limbo.emu.main.arm/cache/limbo/edk2/*.fd /sdcard/limbo_fw/'
su -c 'cp /sdcard/limbo_fw/edk2_*.fd /usr/local/share/ckvm/firmware/'
```

**想换用户名密码**
改 `vm.conf` 的 `VM_USER`/`VM_PASS` 后 `ckvm rm` 重建（cloud-init 只在首次
启动生效），或进系统 `passwd`。

**想要图形界面**
默认只有串口。自己在 QEMU 参数里加 `-device virtio-gpu-pci` 配 VNC。

---

## 环境

```text
设备    小米 MT6833 / everpal
容器    droidspaces（Debian 13，systemd 作为 PID 1）
内核    4.14.356-Everpal-KVM-CuiCanMX-v1.0
guest   Ubuntu 26.04.1 LTS
```

---

## 文档

- **[TECHNICAL.md](TECHNICAL.md)** —— 技术文档。包含硬件与特权模型、
  `ESR_EL2.ISV == 0` 的架构根因、内核回移的 ABI 细节、固件选择的依据、
  big.LITTLE 绑核分析、网络模式原理、systemd 设计、完整实测数据集，
  以及**每一处结论的出处**。
- **[../docs/KVM.md](../docs/KVM.md)** —— 最初的内核侧调研记录。
