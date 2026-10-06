# ckvm 2.0 — KVM 虚拟机管理器

在 **MT6833 / evergo**（小米天玑 810 机型）上跑**硬件加速**的 KVM 虚拟机。

装在 droidspaces 容器里，systemd 管理，**支持多开**，CPU / 内存 / 磁盘像正常
虚拟机那样随便配。

```
  ckvm · KVM 虚拟机管理器                              v2.0
  作者  璀璨梦星 · cuicanmx            github.com/ccmx200
```

> 想知道**为什么**这么设计、每处改动的实测依据和出处，
> 看 **[TECHNICAL.md](TECHNICAL.md)**。本文只讲怎么用。

---

## 一键安装

```bash
curl -fsSLk https://git.yylx.win/raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/refs/heads/resukisu/kvm_manager/install.sh | sh
```

国内直连 raw.githubusercontent.com 通常不通，所以带上加速：

```bash
curl -fsSLk https://git.yylx.win/raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/refs/heads/resukisu/kvm_manager/install.sh | sh -s -- -cn https://你的代理/
```

装的过程会问你两件事：**用哪个 apt 源**（先测速再让你选）和
**用哪个 GitHub 加速**（要下 UEFI 固件时）。

装完直接：

```bash
ckvm create
```


## 目录

- [它能做什么](#它能做什么)
- [安装](#安装)
- [快速开始](#快速开始)
- [创建虚拟机](#创建虚拟机)
- [配置 CPU / 内存 / 磁盘](#配置-cpu--内存--磁盘)
- [多开](#多开)
- [镜像缓存](#镜像缓存)
- [网络](#网络)
- [命令一览](#命令一览)
- [常见问题](#常见问题)

---

## 它能做什么

| | |
|---|---|
| **硬件加速** | KVM + EL2，不是纯软件模拟 |
| **完整虚拟机** | UEFI 固件，能装系统、能多开 |
| **Ubuntu 22.04 – 26.04** | 交互式选版本，像一个应用商店 |
| **CPU 自由配置** | 6×A55 + 2×A76，`all` / `big` / 任意掩码 |
| **共享镜像缓存** | 多开只下载一次基础镜像 |
| **systemd 集成** | 开机自启、一键启停 |

### 性能参考

guest 内 `openssl speed -multi 8 -evp sha256`（16 KB 块，本机实测）：

| 物理核 | 吞吐 | 启动耗时 |
|---|---|---|
| 全部 8 核 | **7.4 – 7.7 GB/s** | 42 – 44 s |
| 仅 2 个大核 | 2.9 – 3.0 GB/s | ~34 s |

全核约为大核专用的 **2.6 倍**，代价是启动慢 8 – 12 秒。

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
  物理核心: 全部 8 个物理核（6×A55 + 2×A76）
  网络模式 user/host: [user]:
  映射端口 (逗号分隔): [22]:

  检查镜像可用性
    可用：Ubuntu 24.04 (noble, LTS)  592M
  已创建 'srv24'  (Ubuntu 24.04, 8025 端口, 4 vCPU, 1536 MiB, 30G)
```

**每一步都有默认值，直接回车就行。** 选 `0` 取消。

### 也可以命令式

```bash
ckvm create ubuntu26                       # 全默认
ckvm create web --rel 24.04 --cpus 4       # 指定版本和规格
ckvm create app --rel 22.04 --mem 1024 --disk 20
```

---

## 创建虚拟机

### 每一步都有反馈

下载有进度条和速度，复制有字节进度，失败会告诉你哪一步、为什么：

```text
  检查镜像可用性
    可用：Ubuntu 24.04 (noble, LTS)  592M

  ⠹ ████████████░░░░░░░░░░░░  52%  下载中  310M/592M
  ✓ 使用缓存 Ubuntu 24.04（592M，跳过下载）
  ✓ 镜像就绪
```

**不会静默卡住** —— 每一步都有动画或明确的完成提示。

### 登录账号和密码

```bash
ckvm create web --user root --pass 你的密码    # 直接 root
ckvm create web --user alice --pass secret     # 普通用户（也能 sudo）
```

不指定的话：用户名默认 `ubuntu`，**密码会让你自己输**（不回显）。

### 启动 / 停止

```bash
ckvm start web          # 后台，等到 SSH 就绪才返回
ckvm start web -f       # 前台，Ctrl-C 停止
ckvm stop web
ckvm restart web
ckvm status web         # 详细状态 + 串口末尾
ckvm console web -n 50  # 看串口最后 50 行
```

---

## 配置 CPU / 内存 / 磁盘

**像正常虚拟机一样配，没有隐藏限制。**

```bash
ckvm create big --cores big          # 只用 2 个大核（低延迟）
ckvm create all --cores all          # 全部 8 核（高吞吐，默认）
ckvm create tiny --cpus 2 --mem 1024 --disk 20
```

### `--cores` 怎么选

| 值 | 用到的核 | 适合 |
|---|---|---|
| `all`（默认）| 全部 8 核（6×A55 + 2×A76）| 吞吐优先、跑编译、多开 |
| `big` | 仅 2 个大核（A76）| 单核延迟优先、轻负载 |

### 任意掩码都可以

`CPUSET` 支持任意 CPU 掩码，**混合小核大核也没问题**：

```text
0-7        全核 8 vCPU          ✓
0-5        全小核 6 vCPU        ✓
6-7        全大核 2 vCPU        ✓
0-2,6-7    非对称 3小+2大       ✓
0,7        极端 1小+1大         ✓
0-7        16 vCPU 超配 2x      ✓
```

> **历史说明**：早期内核在 big.LITTLE 上跨簇会随机失败
> （`Failed to put registers after init`），必须手工绑核。
> **该问题已在内核侧修复**（见 [TECHNICAL.md](TECHNICAL.md) 12.11–12.13），
> 现在不需要任何绑核 workaround。
>
> 唯一保留的语义是正常的：**你给几个核，虚拟机的 vCPU 就只能用这几个核**。

### 改已有虚拟机的配置

```bash
ckvm edit web        # 直接改 vm.conf
ckvm config web      # 看当前配置
```

`CPUS` / `MEM` / `DISK` / `CPUSET` / `PORT` / `FORWARDS` / `CACHE_MODE` 都可以改，
改完 `ckvm restart web` 生效（磁盘扩容会自动 `qemu-img resize`）。

`ckvm edit` 默认用 **nano**（找不到才依次退到 micro / vim / vi）。想换：

```bash
EDITOR=vim ckvm edit web
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
  NAME        STATE    CPUS  MEM    DISK  PORT  SSH
  a           running  8     2048   50G   8023  ssh ubuntu@127.0.0.1 -p 8023
  b           running  8     2048   50G   8024  ssh ubuntu@127.0.0.1 -p 8024
```

**端口从 8023 起自动分配，不用自己记。**

> **内存提醒**：这台机器约 5.6 GB 可用，多开时注意 `MEM` 之和。
> `ckvm list` 能一眼看出每台占多少。

---

## 镜像缓存

**基础镜像只下载一次，所有虚拟机共用。**

```bash
ckvm cache              # 看缓存了什么、占多少
ckvm cache --path       # 缓存目录
ckvm cache --clear      # 清空
ckvm cache --clear 24.04   # 只删某个版本
```

```text
  镜像缓存  /var/lib/ckvm/.cache

  版本         大小  完成
  ────────────────────────────────
  24.04            592M  ✓
  26.04            902M  ✓
  ────────────────────────────────
  合计           1.5G

  ckvm cache --clear [版本]   删除缓存
  ckvm cache --path           显示缓存目录
```

### 行为

| 什么时候 | 做什么 |
|---|---|
| 首次创建某版本 | 下载到缓存（有进度条） |
| 再次创建同版本 | **直接命中缓存，跳过下载** |
| 下载中断 | 下次自动续传 |
| `ckvm rm` 删虚拟机 | **缓存保留**，不影响其它机 |
| 缓存被清 | 下次创建重新下载 |

**所以开 3 台 24.04 只需要下载 1 次 592M**，其余两台直接从缓存复制。

---

## 网络

### user 模式（默认）

QEMU 自己做 NAT，用端口映射访问。**任何环境都能用。**

```bash
ckvm create web --fwd 22,80,443
```

```text
  network: user-mode NAT
    ssh ubuntu@127.0.0.1 -p 8023   (password: 你设的)
    port 80  -> 127.0.0.1:80
    port 443 -> 127.0.0.1:443
```

**交互式创建时是可视化选择**，不用记格式：

```text
  常用端口  （输入编号，可多选如 1,3,5；回车跳过）

    1) SSH        22 -> 该机 PORT
    2) HTTP       80
    3) HTTPS      443
    4) MySQL      3306
    5) PostgreSQL 5432
    6) Redis      6379
    7) 常用 Web 栈 80,443,8080,3000
    8) 开发常用   3000,5000,8000,8080

  选择: 1,2

  当前映射
     1) 宿主机 <该机 PORT>  -> guest 22     22
     2) 宿主机 80           -> guest 80     80

  还要加自定义映射吗？ （如 8080:80，直接回车结束）
  >
```

**命令行写法**（`--fwd`）：

| 写法 | 含义 |
|---|---|
| `22` | guest 22 → **该机的 PORT**（多开不抢端口）|
| `80` | 同号映射 |
| `8080:80` | 宿主机 8080 → guest 80 |
| `2222:22` | 额外再把 guest 22 暴露到 2222 |

格式会在添加时校验：`0`、`99999`、非数字都会被拒绝并提示。

### host 模式（tap）

guest 拿到自己的 IP，**自己跑 sshd**，不需要端口映射。

```bash
ckvm create srv --net host
```

```text
  network: tap, the guest is on this container's network
    guest ip : 172.28.100.2/24   gateway 172.28.100.1
    ssh      : root@172.28.100.2
```

脚本自动建 tap、配 IP、开转发和 NAT，`stop` / `rm` 自动清理。


### 磁盘缓存

对上 PVE 的叫法，创建时可选：

| 模式 | 含义 |
|---|---|
| **writeback**（默认）| 宿主页缓存 + 尊重 flush |
| `none` | 绕过宿主缓存（`O_DIRECT`），最保险但最慢 |
| `unsafe` | 同 writeback 但**忽略 flush** —— 最快，断电可能损坏 |
| `writethrough` | 读走缓存，写直通 |

```bash
ckvm create web --cache unsafe
ckvm edit web        # 改 CACHE_MODE=x
ckvm restart web
```

> **先说清楚**：本机 QEMU 打开 `disk.qcow2` 时**本来就没有** `O_DIRECT`
> （`/proc/<pid>/fdinfo` 的 flags 是 `02400002`），也就是**它一直在用宿主
> 页缓存**。所以 `writeback` 是**现状**，不是新增的加速。
>
> 实测的磁盘数据：顺序写 776 MB/s、随机读 4K 38.6k IOPS、随机写 4K 9.3k IOPS。
> 随机写偏弱，但那不是 apt 慢的原因（apt 慢在钩子，见下）。

### ⚠️ 局域网访问

**host 模式的 `172.28.100.x` 是容器内部网段，不是手机在局域网上的地址。**
局域网里其他电脑直连不到。

想真正暴露到局域网：

- **简单**：用 user 模式，在 Android 宿主侧把端口转进容器
- **彻底**：在 Android 宿主侧建网桥（见 [TECHNICAL.md](TECHNICAL.md) 第 6.4 节）

`ckvm net <名字>` 会打印当前布局和下一步提示。

### systemd

```bash
ckvm enable ubuntu26          # 启用 + 启动 + 开机自启
systemctl status ckvm@ubuntu26
journalctl -u    ckvm@ubuntu26
ckvm disable ubuntu26
```

---

## guest 内部优化：`ckvm tune`

apt 慢不在下载 —— 实测下载 5.1 MB/s，而**每次安装后要跑几个钩子**。
`ckvm tune` 一次关掉它们，并**当场测出前后差异**：

```bash
ckvm tune ubuntu2604              # 应用并测速
ckvm tune ubuntu2604 --status     # 看当前状态
ckvm tune ubuntu2604 --revert     # 全部还原
```

```text
  🔧 guest 内部优化
  先测一个基准（装一个小包）
  基准 install: 9.56 秒
  禁用 99update-notifier hook（apt-check 每次 apt 都跑）
  删除翻译索引（apt 用不到）
  禁用 man-db trigger（每次装包重建 man 索引）
  · needrestart 未安装，跳过
  再测一次
  优化后 install: 6.21 秒

  ✅ 快了 3.36 秒（35%）
```

### 它改了什么

| 项 | 为什么 |
|---|---|
| `99update-notifier` hook | 每次 apt 后跑 `apt-check`，扫描整个 dpkg 库（实测 2.8 秒）|
| 翻译索引 | apt 解析用不到，占 32 MB |
| `man-db` trigger | 每次装包重建 man 索引（9777 个页面 × 26 语言）|
| `needrestart` | 每次 apt 后扫描**所有运行中的进程**（装了才处理）|

**全部可还原**，`--revert` 一条命令撤销。`needrestart` 不会被装回来 ——
它本来就是个可选的通知工具。

---

## 命令一览

```bash
# 安装
ckvm install [选项]              # 安装（-cn 用加速）
ckvm uninstall                   # 卸载

# 创建与管理
ckvm create                      # 交互式（应用商店）
ckvm create <名字> [选项]         # 命令式
ckvm versions                    # 列出可选版本
ckvm cache [--clear|--path]      # 镜像缓存
ckvm image <名字>                # 重新下载镜像

# 运行
ckvm start <名字> [-f]           # 启动（-f 前台）
ckvm stop <名字>
ckvm restart <名字>
ckvm rm <名字> [-f]              # 删除（-f 可删运行中的）

# 查看
ckvm list                        # 所有虚拟机
ckvm status <名字>               # 详细状态 + 串口末尾
ckvm console <名字> [-a|-n N]    # 实时看串口，Ctrl-C 断开
ckvm config [名字]               # 看配置
ckvm edit <名字>                 # 改配置
ckvm net [名字]                  # 看网络情况
ckvm ports                       # 端口映射怎么写

# 自检与服务
ckvm selftest [--keep]           # 真启动一台验证整条链路
ckvm enable <名字> / disable <名字>
ckvm mirror                      # 给容器换 apt 源
```

### `ckvm create` 的全部选项

```text
--cpus N    vCPU 数量            默认 8
--cores C   all | big            默认 all
--mem MB    内存                 默认 2048
--disk GB   磁盘                 默认 50
--rel V     Ubuntu 版本          默认 26.04
--port N    SSH 端口             默认从 8023 起找空闲
--net M     user | host          默认 user
--fwd LIST  端口映射，逗号分隔    默认 22
--user U    用户名，或 root       默认 ubuntu
--pass P    密码
```

---

## 常见问题

**`Failed to put registers after init`**

旧内核的 big.LITTLE 跨簇问题，**已在当前内核修复**。
如果你看到这个错误，说明跑的是旧内核 —— 更新内核，或临时在 `vm.conf` 里
把 `CPUSET` 设成 `6-7`。

**创建时卡在下载**

看进度条；中断了下次会自动续传。慢的话换镜像源：

```bash
export MIRROR_IMAGE_LIST="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images"
```

**GRUB 加载后卡住不动**

NVRAM 被污染。`ckvm stop <名字>`，删掉该目录下的 `uefi-vars.fd`，再
`ckvm start`（会从模板重建）。

**想换用户名密码**

改 `vm.conf` 的 `VM_USER`/`VM_PASS` 后 `ckvm rm` 重建（cloud-init 只在首次启动
生效），或进系统 `passwd`。

**`ckvm console` 要 Ctrl-C 才能退出，正常吗**

正常。它默认只显示**新输出**，不重放开机 bootlog。想看历史：

```bash
ckvm console <名字> -n 50    # 先显示最后 50 行
ckvm console <名字> -a       # 显示全部
```

串口里的终端控制序列会被自动剥掉，颜色保留。**要交互登录用 ssh 更方便**。

**curl 报 `Connection reset by peer`**

GitHub 被墙。用加速地址，或先手动抓脚本再用 `install -cn`。

**找不到固件**

```bash
ckvm install            # 会从仓库（或其加速地址）下载
```

或从设备上拷：

```bash
su -c 'mkdir -p /sdcard/limbo_fw && cp /data/data/com.limbo.emu.main.arm/cache/limbo/edk2/*.fd /sdcard/limbo_fw/'
su -c 'cp /sdcard/limbo_fw/edk2_*.fd /usr/local/share/ckvm/firmware/'
```

**想要图形界面**

默认只有串口。自己在 QEMU 参数里加 `-device virtio-gpu-pci` 配 VNC。

---

## 镜像源

```text
系统镜像  https://mirror.nju.edu.cn/ubuntu-cloud-images
          ↓ 失败则
          https://cloud-images.ubuntu.com

apt 源    https://mirrors.ustc.edu.cn/ubuntu-ports
```

换源：

```bash
export MIRROR_IMAGE_LIST="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images"
export MIRROR_APT="https://mirrors.aliyun.com/ubuntu-ports"
```

> **实测提醒**：USTC 的 `ubuntu-cloud-images` **只镜像了 amd64**，arm64 返回 403，
> 所以默认走 NJU。

---

## 环境

```text
设备    小米 MT6833 / evergo（天玑 810）
容器    droidspaces（Debian 13，systemd 作为 PID 1）
内核    4.14.356-Evergo-KVM-cuicanmx-v1.0
guest   Ubuntu 22.04 – 26.04
```

---

## 文档

- **[TECHNICAL.md](TECHNICAL.md)** —— 技术文档。硬件与特权模型、
  `ESR_EL2.ISV == 0` 的架构根因、内核回移的 ABI 细节、固件选择依据、
  big.LITTLE 寄存器快照的完整分析与实测（第 12 章）、网络模式原理、
  systemd 设计、完整实测数据集，**以及每一处结论的出处**。
- **[../docs/KVM.md](../docs/KVM.md)** —— 最初的内核侧调研记录。

---

## 作者与许可

**璀璨梦星 · cuicanmx** · <https://github.com/ccmx200>

`ckvm` 以 **GPL-2.0** 发布，与内核树保持一致。
