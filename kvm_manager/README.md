# ckvm — KVM 虚拟机管理器

在 MT6833 / evergo（小米天玑 810 机型）上跑**硬件加速**的 KVM 虚拟机。
装在 droidspaces 容器里，用 systemd 管理，支持多开。

> 想了解**为什么**这么设计、每处改动的依据和实测数据，
> 看 **[TECHNICAL.md](TECHNICAL.md)**。
> 本文只讲怎么用。

---

## 一键安装

```bash
curl -fsSLk https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/refs/heads/resukisu/kvm_manager/kvm-vm.sh | bash -s -- install
```

**默认走 GitHub 官方源**，脚本不做任何加速、不改写地址。

> URL 里用的是 `refs/heads/resukisu` 而不是 `resukisu`。GitHub 的加速镜像
> **按 URL 路径缓存**，实测裸分支名会命中旧缓存（`x-cache: HIT`,
> `x-cache-hits: 24`, `cache-control: max-age=300`），而完整 ref 路径能拿到
> 当前版本。两者是同一份文件，只是路径写法不同。
>
> 装完可以自检：
>
> ```bash
> ckvm help | grep -q 'ckvm ports' && echo 已是最新 || echo 装到了旧版
> ```

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
ckvm create
```

**直接跑 `ckvm create` 就是交互式**，像一个应用商店：

```text
  ckvm  ·  创建 Ubuntu 虚拟机
  ────────────────────────────

  Ubuntu 版本
  ──────  ────────────  ─────  ────────
   1) 22.04    jammy        LTS     673M
   2) 22.10    kinetic              716M
   3) 23.04    lunar                688M
   4) 23.10    mantic               684M
   5) 24.04    noble        LTS     592M
   6) 24.10    oracular             584M
   7) 25.04    plucky               680M
   8) 25.10    questing             843M
   9) 26.04    resolute     LTS     902M
   0) 取消

  选择 [1-9] (默认 26.04): 5
  选择：Ubuntu 24.04 noble (LTS)  ~592M
  虚拟机名字: [ubuntu2404]: srv24
  vCPU 数量: [8]: 4
  内存 (MiB): [2048]: 1536
  磁盘 (GiB): [50]: 30
  网络模式 user/host: [user]:
  映射端口 (逗号分隔): [22]:

  检查镜像可用性...
    可用：Ubuntu 24.04 (noble, LTS)  592M
  已创建 'srv24'  (Ubuntu 24.04, 8025 端口, 4 vCPU, 1536 MiB, 30G)
```

每一步都有默认值，**直接回车就行**。选 `0` 取消。

### 也可以命令式

```bash
ckvm create ubuntu26                       # 全默认
ckvm create web --rel 24.04 --cpus 4       # 指定版本和规格
ckvm create app --rel 22.04 --mem 1024 --disk 20
```

**只要给了名字或任何选项，就是命令模式**，不会有任何提问。

参数：

| 选项 | 含义 | 默认 |
|---|---|---|
| `--rel V` | Ubuntu 版本 | `26.04` |
| `--cpus N` | vCPU 数量 | `8` |
| `--mem MB` | 内存 | `2048` |
| `--disk GB` | 磁盘容量 | `50` |
| `--port N` | 宿主机 SSH 端口 | 从 `8023` 起自动找空位 |
| `--net M` | 网络模式 `user` / `host` | `user` |
| `--user U` | 登录账号，或 `root` | `ubuntu` |
| `--pass P` | 该账号的密码 | `ubuntu` |
| `--fwd L` | 端口映射（见下） | `22` |

### 端口映射怎么写

交互式流程里问你「映射端口」之前会先把用法打出来。命令行等价的是 `--fwd`。

格式是**逗号分隔**的列表，每一项两种写法：

```text
<guest端口>                 宿主机同号映射
<宿主机端口>:<guest端口>     映射到指定端口
```

| 写法 | 含义 |
|---|---|
| `--fwd 22` | 只暴露 ssh。guest 的 22 → 该机的 `--port` |
| `--fwd 22,80,443` | ssh 加上 web，80/443 同号 |
| `--fwd 22,8080:80` | guest 的 80 → 宿主机 8080 |
| `--fwd 22,2222:22` | 额外再把 guest 22 暴露到 2222 |
| `--fwd 22,3306:3306,6379:6379` | mysql 和 redis |

**两条规则要记住**：

1. **guest 的 22 是特例** —— 它映射到这台虚拟机自己的 `--port`（从 8023 起
   自动分配），所以多开不会互相抢，也不会占用容器自己的 22。
2. **宿主机端口不能重复**。启动前会检查并提示是谁占着：

   ```text
   ! host port 8080 is already in use by ckvm guest 'ubuntu26'
   !   pick another one, e.g. --fwd 22,18080:80
   ```

想随时复习：

```bash
ckvm ports          # 或者 ckvm help ports
ckvm net <名字>     # 看某台实际生效的映射
```

> 用 `--net host` 时不需要映射 —— guest 会拿到自己的 IP 并自己跑 sshd。

### 看有哪些版本

```bash
ckvm versions
```

```text
  VERSION  CODENAME     LTS   SIZE
  22.04    jammy        LTS   673M
  22.10    kinetic            716M
  23.04    lunar              688M
  23.10    mantic             684M
  24.04    noble        LTS   592M
  24.10    oracular           584M
  25.04    plucky             680M
  25.10    questing           843M
  26.04    resolute     LTS   902M
```

创建前会先**验证镜像真的能下**（探测 `Content-Length`），不可用会直接报错，
不会让你等半天才发现下不了。

### 每一步都有反馈

创建过程会一路显示进度，不会出现"卡住不动"的观感：

```text
  检查镜像可用性                     ← 转圈
  可用：Ubuntu 24.04 (noble, LTS)  592M
  已创建 'srv24'  (Ubuntu 24.04, 8025 端口, ...)

  ⠼ ██████████████░░░░░░░░░░  58%  Ubuntu 24.04 arm64  345M/592M
  ⠸ ████████████████████████  100%  Ubuntu 24.04 arm64  592M/592M

  ⠋ 扩容到 30G                       ← 转圈（qemu-img resize）
  image ready
  ⠋ 生成 cloud-init 镜像             ← 转圈
  seed.img written (root / password ...)

  启动： ckvm start srv24
```

慢操作（扩容、格式转换、cloud-init 生成）都有转圈动画；下载有进度条 +
百分比 + 已下载/总量。失败时会打印出错的最后几行，而不是静默返回。

> 进度条只在终端上显示。用 `cmd > log` 或没有 PTY 的 ssh 会话跑时，会退化成
> 普通文字输出（避免污染日志）。

### 登录账号和密码

交互流程里会问你**用哪个账号登录**：

```text
  登录账号
  ────────
    输入 root       直接用 root 登录（会设置 root 密码）
    输入其他名字    新建一个带 sudo 的普通用户
    直接回车        用 ubuntu
  账号名: [ubuntu]:
  密码:
  再输一次:
```

**密码由你自己定**，输入时不回显，要输两遍确认。

命令行等价参数：

```bash
ckvm create srv --user root  --pass 'MyPass123'
ckvm create dev --user alice --pass 'alicepw'
ckvm create box                      # 默认账号 ubuntu / 密码 ubuntu
```

> **为什么 root 需要额外处理**：Ubuntu 的 cloud image 自带
> `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`，里面写着
> `PasswordAuthentication no`，而 `sshd_config` 是按字母序 `Include` 该目录的 ——
> 它排在 cloud-init 写的 `50-cloud-init.conf` **后面**，所以会覆盖。
> 结果就是密码设上了但 root 仍然登录不了。ckvm 会再写一个排序更后的
> `99-ckvm-root.conf` 显式打开 root 密码登录，并重启 sshd。

### 启动

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

ckvm create                      # 交互式（应用商店）
ckvm create <名字> [选项]         # 命令式
ckvm versions                    # 列出可选版本
ckvm ports                       # 端口映射怎么写
ckvm image <名字>                # 重新下载镜像
ckvm start <名字> [-f]           # 启动（-f 前台）
ckvm stop <名字>
ckvm restart <名字>
ckvm rm <名字> [-f]              # 删除（-f 可删运行中的）

ckvm list                        # 所有虚拟机
ckvm status <名字>               # 详细状态 + 串口末尾
ckvm console <名字> [-a|-n N]    # 实时看串口，Ctrl-C 断开

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

**`ckvm console` 要 Ctrl-C 才能退出，正常吗**
正常。它默认只显示**新输出**，不会重放开机时的 bootlog。想看历史：

```bash
ckvm console <名字> -n 50    # 先显示最后 50 行
ckvm console <名字> -a       # 显示全部
```

串口里的终端控制序列（DCS / OSC / 私有模式）会被自动剥掉，颜色保留。
**要交互登录用 ssh 更方便** —— `ckvm status <名字>` 会告诉你地址。

**想要图形界面**
默认只有串口。自己在 QEMU 参数里加 `-device virtio-gpu-pci` 配 VNC。

---

## 环境

```text
设备    小米 MT6833 / evergo
容器    droidspaces（Debian 13，systemd 作为 PID 1）
内核    4.14.356-Evergo-KVM-CuiCanMX-v1.0
guest   Ubuntu 26.04.1 LTS
```

---

## 文档

- **[TECHNICAL.md](TECHNICAL.md)** —— 技术文档。包含硬件与特权模型、
  `ESR_EL2.ISV == 0` 的架构根因、内核回移的 ABI 细节、固件选择的依据、
  big.LITTLE 绑核分析、网络模式原理、systemd 设计、完整实测数据集，
  以及**每一处结论的出处**。
- **[../docs/KVM.md](../docs/KVM.md)** —— 最初的内核侧调研记录。
