# ckvm 2.0 — KVM 虚拟机管理器

在 **MT6833 / evergo**（红米 Note 11T 5G，天玑 810）上跑**硬件加速**的 KVM 虚拟机。
装在 droidspaces 容器里，systemd 管理，**支持多开**，CPU / 内存 / 磁盘随便配。

支持 **Ubuntu · Debian · Fedora · Arch Linux ARM**，装之前可以 `--dry-run` 先看计划。

```
  🚀 ckvm · KVM 虚拟机管理器 · 2.0
     作者  璀璨梦星 · cuicanmx   github.com/ccmx200
```

> 想知道**为什么**这么设计、每处结论的实测依据和出处，看 **[TECHNICAL.md](TECHNICAL.md)**。
> 本文只讲怎么用，所有输出都是本机实测贴的。

---

## 一键安装

```bash
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager/install2.sh | sh
```

脚本按 **ghproxy.net → gh-proxy.com → 直连** 的顺序试，用第一个能通的，
并把实际来源和脚本版本打出来。想指定就加 `--from`：

```bash
curl -fsSL <上面的地址> | sh -s -- --from https://ghproxy.net/
```

装的过程中会问你两件事：

* **用哪个 apt 源** —— 先测速，再让你选
* **用哪个 GitHub 加速** —— 只在要下 UEFI 固件时问

> **为什么是 `install2.sh`**：国内镜像把 `install.sh` 这个路径缓存到了旧版本，
> 加查询参数也绕不过（按路径缓存）。`install.sh` 现在是个转发存根。

装完直接跑：

```bash
ckvm create
```

---

## 可选的发行版

```bash
ckvm versions                 # 三个发行版一起列
ckvm versions debian          # 只看一个
```

| 发行版 | 版本 | 大小 | 说明 |
|---|---|---|---|
| **Ubuntu** | 22.04 – 26.04（9 个） | 584M – 902M | 官方 cloud image |
| **Debian** | 13 trixie / 12 bookworm | 322M / 326M | genericcloud，带 cloud-init |
| **Fedora** | 42 | 600M | Cloud Base Generic |
| **Arch Linux ARM** | latest | 831M | 从 rootfs tarball 建盘，直接内核启动 |

```bash
ckvm create web --distro debian --rel 13
ckvm create web --distro fedora --rel 42
ckvm create web --rel 24.04                 # 不给发行版就是 Ubuntu
```

镜像分开缓存，互不影响：

```
$ ckvm cache

  💾 镜像缓存  /var/lib/ckvm/.cache
  ────────────────────────────────────────────────

    发行版       版本       大小  状态
    ────────────────────────────────────────────────
    Ubuntu      26.04    901.7M  ✓
    Debian      13       321.9M  ✓
    ────────────────────────────────────────────────
    合计                 1.2G
```

### Arch Linux ARM

官方 Arch 镜像树**只有 x86_64**，没有可用的 arm64 云端镜像。Arch Linux ARM 提供的是
**831 MB 的 rootfs tarball**，所以 ckvm 会**自己建盘**：

```bash
ckvm image arch              # 下载 rootfs + 建盘（约 3GB 可用内存）
ckvm create atest --distro arch --rel latest
```

建盘两步（按顺序尝试）：

| 方法 | 条件 |
|---|---|
| `mke2fs -d <tarball>` | 需要 e2fsprogs 编译了 libarchive |
| 解包后 `mke2fs -d <目录>` | 通用回退，任何环境都能用 |

然后**直接内核启动**：QEMU 用 `-kernel` + `-append`，不需要 UEFI 固件，
也不需要 ESP 分区或引导器 —— 因为 Arch 的盘就是一整个 ext4 rootfs。

> **内存要求（重要）**：建盘需要约 **3GB 可用内存**（831MB tarball +
> 约 2GB 解包树 + 5GB 镜像）。ckvm 会先检查 `MemAvailable`，
> **不够就拒绝并给出提示**，不会硬上。
>
> 这不是保守估计 —— 我在只有 803MB 可用时试过一次，
> **整台设备失去响应，只能手动重启**。所以这个检查是必须的。

---

## 快速开始

```bash
ckvm create          # 交互式，一路回车也能建出来
ckvm start web
ckvm ssh web
```

**两种用法都行**：不带给名字和选项就是一步一步问；给了就跳过对应的提问。

```bash
ckvm create web --rel 24.04 --cpus 4 --mem 1536 --disk 30 --pass 你的密码
```

---

## 创建虚拟机

### 交互式

```
  🚀 ckvm · KVM 虚拟机管理器 2.0
     作者  璀璨梦星 · cuicanmx   github.com/ccmx200

  创建 Ubuntu 虚拟机
  ────────────────────────────────────────────────────────────────────

  Ubuntu 版本

     1) 22.04    jammy  LTS  673M
     ...
     9) 26.04    resolute  LTS  902M
     0) 取消

  选择 [9]:
```

> **默认值是 26.04**，直接回车就是它。

接着依次问：**名字 → vCPU → 物理核心 → 内存 → 磁盘 → 磁盘缓存 →
安装后自动优化 → 端口映射 → 登录账号 → 密码**，最后给一份确认摘要：

```
  确认
    ────────────────────────────────────────
    名字     cmd1
    Ubuntu   26.04
    vCPU     3
    物理核   0-2,6-7  (3×A55 + 2×A76)
    内存     1280 MiB
    磁盘     12 GiB
    缓存     writeback
    端口映射 22, 8080:80
    登录     alice / *********
    内部优化 启用
    ────────────────────────────────────────

  开始创建 [Y/n]:
```

### 命令式

```bash
ckvm create cmd1 \
  --rel 26.04 --cpus 3 --cores 0-2,6-7 \
  --mem 1280 --disk 12 --cache writeback \
  --fwd 22,8080:80 --user alice --pass secret123 \
  --tune yes --yes
```

**给了的选项不再问，没给的照常问。** 加 `--yes` 连最后的确认也跳过（适合脚本）。

| 选项 | 含义 | 默认 |
|---|---|---|
| `--distro D` | `ubuntu` / `debian` / `fedora` | 问，默认 ubuntu |
| `--rel V` | 版本号 | 问，默认发行版的最新 |
| `--cpus N` | vCPU 数量 | 问，默认 8 |
| `--cores C` | `all` / `big` / 掩码如 `0-2,6-7` | 问，默认全核 |
| `--mem MB` | 内存，最小 256 | 问，默认 2048 |
| `--disk GB` | 磁盘，最小 2 | 问，默认 50 |
| `--cache M` | `writeback` / `none` / `unsafe` / `writethrough` | 问，默认 writeback |
| `--fwd LIST` | 端口映射，逗号分隔 | 问，默认 `22` |
| `--user U` | 用户名，或 `root` | 问，默认 ubuntu |
| `--pass P` | 密码 | 问（不回显），也可用环境变量 `CKVM_PW` |
| `--tune yes\|no` | 创建后自动优化 guest | 问，默认启用 |
| `--port N` | 宿主机端口 | 自动从 8023 找空闲 |
| `--net M` | `user` / `host` | `user` |
| `--yes` | 跳过确认 | — |
| `--dry-run` | 只打印计划，不问、不下载、不写入 | — |

选项写错会立刻报错并列出可用的：

```
  ❌ 不认识的选项: --bogus
     可用: --rel --cpus --cores --mem --disk --port --net --fwd --user --pass --cache --tune --yes
```

## 先看计划再动手：`--dry-run`

```bash
ckvm create web --distro debian --rel 13 --cpus 2 --mem 1024 --dry-run
```

```
  试运行  不会下载、不会写入
    ────────────────────────────────────────────────────
    配置目录    /var/lib/ckvm/web
    vm.conf     /var/lib/ckvm/web/vm.conf
    基础镜像    https://mirror.nju.edu.cn/debian-cdimage/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2
    镜像状态    需要下载
    磁盘        /var/lib/ckvm/web/disk.qcow2  10 GiB
    固件        /usr/local/share/ckvm/firmware/edk2_qemu_aarch64_nonvram.fd
    cloud-init  /var/lib/ckvm/web/seed.img
    宿主机端口  8023 → guest 22
    ────────────────────────────────────────────────────

    备用镜像源:
      首选  https://mirror.nju.edu.cn/debian-cdimage/cloud/trixie/latest/debian-13-genericcloud-arm6
      备用  https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2

    QEMU 会以这些参数启动:
      taskset -c 0-7 qemu-system-aarch64 -name web -M virt,gic-version=3 -cpu max -accel kvm -smp 2
      -m 1024 -drive if=pflash,format=raw,unit=0,file=/var/lib/ckvm/web/uefi-code.fd,readonly=on
      -netdev user,id=n0,hostfwd=tcp:0.0.0.0:8023-:22
      -device virtio-net-pci,netdev=n0 -device virtio-rng-pci -display none
      -serial file:/var/lib/ckvm/web/serial.log

  ✅ 试运行结束，什么都没改
```

`--dry-run` 也意味着**不再问你任何问题**：命令行没给的选项一律用默认值。

---

### 登录账号

三种都行：

```
  登录账号

     1) ubuntu    推荐，可以 sudo
     2) root      直接用 root 登录
     3) 自定义    自己指定用户名
     0) 取消
```

自定义名字会校验格式（小写字母数字 `_` `-`，不能数字开头）。

**密码会让你输两次（不回显）。** 想脚本化：

```bash
CKVM_PW=你的密码 ckvm create web --rel 24.04 --yes
```

---

## 物理核心

```
  物理核心

     1) 0-7  (6×A55 + 2×A76)  全部 8 核（6×A55 + 2×A76），吞吐优先
     2) 6-7  (2×A76)          仅 2 个大核（A76），单核延迟优先
     3) 0-5  (6×A55)          仅 6 个小核（A55），省电／低发热
     4) 自定义                 想自己指定就用这个，例如 0-2,6-7
     0) 取消
```

选「自定义」可以填任意掩码，**混合大小核没问题**（实测 21 组掩码全通过）：

```text
0-7        全核
0-5        全小核
6-7        全大核
0-2,6-7    3 小 + 2 大      ← 上面 cmd1 用的就是这个
0,7        1 小 + 1 大
```

> 早期内核跨簇会随机失败（`Failed to put registers after init`），必须手工绑核。
> **该问题已在内核侧修复**，细节见 [TECHNICAL.md](TECHNICAL.md) 第 12 章。
> 现在唯一的语义是正常的：**你给几个核，虚拟机就只用这几个核**。

`ckvm status` 能看到实际生效的亲和：

```
    CPU 亲和 0-2,6,7
```

---

## 端口映射

创建时是**可视编辑器**，不用记格式：

```
  端口映射  guest 22 会映射到本机 8025

     1) 宿主机 <本机 8025>  → guest 22     22

     1) 添加常用端口    SSH / HTTP / HTTPS / 数据库 …
     2) 添加自定义映射  例如 8080:80
     3) 删除某一项
     4) 完成
     0) 放弃修改
```

命令行：

| 写法 | 含义 |
|---|---|
| `22` | guest 22 → **本机的 PORT**（多开不抢端口）|
| `80` | 同号映射 |
| `8080:80` | 宿主机 8080 → guest 80 |

建好之后也能改：

```bash
ckvm ports cmd1                  # 看
ckvm ports cmd1 add 8443:443     # 加
ckvm ports cmd1 rm 8080:80       # 删
ckvm restart cmd1                # 生效
```

```
  🌐 cmd1 的端口映射
  ────────────────────────────────────────────────────────────────────

     1) 宿主机 <本机 8025>  → guest 22     22
     2) 宿主机 8080         → guest 80     8080:80
```

---

## 磁盘缓存

创建时可选，对应 PVE 的叫法：

| 模式 | 含义 |
|---|---|
| **writeback**（默认）| 速度最快，断电时可能丢失最近写入 |
| `none` | 每次写入都落盘，最安全但最慢 |
| `unsafe` | 比 writeback 更快，断电容易损坏磁盘 |
| `writethrough` | 读走缓存，写直接落盘 |

实测（guest 内）：顺序写 **776 MB/s**、随机读 4K **38.6k IOPS**、随机写 4K **9.3k IOPS**。

---

## 安装后自动优化

apt 慢不在下载（实测 5.1 MB/s），而在**每次装包后跑的钩子**。
创建时可以选是否启用，之后随时能改：

```bash
ckvm tune cmd1              # 应用
ckvm tune cmd1 --status     # 看状态
ckvm tune cmd1 --revert     # 还原
```

```
  🔧 cmd1 的 guest 内部优化
  ────────────────────────────────────────────────────────────────────

    99update-notifier hook  关
    翻译索引                0
    apt lists               24M
    man-db trigger          已移除
    needrestart             没装
```

| 改了什么 | 为什么 |
|---|---|
| 关掉 `99update-notifier` hook | 每次 apt 后跑 `apt-check` 扫整个 dpkg 库（实测 2.8 秒）|
| 删翻译索引 | apt 用不到，占 32 MB |
| 关 `man-db` trigger | 每次装包重建 man 索引（9777 页 × 26 语言）|
| 卸 `needrestart` | 每次 apt 后扫所有运行中的进程（装了才处理）|

**全部可还原。** `needrestart` 不会被装回来 —— 它本来就是个可选的通知工具。

---

## 命令一览

```bash
# 创建与管理
ckvm create                     # 交互式
ckvm create <名字> [选项]        # 命令式
ckvm create ... --dry-run       # 只打印计划，不下载不写入
ckvm versions [发行版]           # 可选版本（ubuntu/debian/fedora）
ckvm image [版本]                # 只下载/缓存基础镜像
ckvm cache [--clear|--path]     # 镜像缓存

# 运行
ckvm start <名字> [-f]           # 启动（-f 前台）；等到 SSH 真能用才返回
ckvm stop <名字>
ckvm restart <名字>
ckvm rm <名字> [-f]              # 删除

# 查看
ckvm list                       # 所有虚拟机（含连接命令）
ckvm status <名字>               # 状态、CPU 亲和、串口摘要
ckvm show <名字>                 # 配置
ckvm console <名字> [-a|-n N]    # 串口
ckvm ssh <名字> [-p]             # 登进去（-p 只打印命令和密码）
ckvm net [名字]                  # 网络
ckvm ports <名字> [add|rm]       # 端口映射
ckvm edit <名字>                 # 编辑 vm.conf

# 服务与维护
ckvm enable|disable <名字>       # 开机自启
ckvm mirror                     # 换 apt 源（测速后你选）
ckvm selftest                   # 只检查配置，不启动虚拟机
ckvm tune <名字>                 # guest 内部优化
ckvm install / uninstall        # 安装 / 卸载（保留虚拟机数据）
```

### 实测输出

```
$ ckvm list

  虚拟机
  ────────────────────────────────────────────────────────────────────

    名字  状态      vCPU 内存   磁盘   物理核    连接
    cmd1  ● running 3    1280   12G    0-2,6-7   ssh alice@127.0.0.1 -p 8025
```

```
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

```
$ ckvm status cmd1

  📊 cmd1
  ────────────────────────────────────────────────────────────────────

    状态     ● running  pid 9450
    CPU 亲和 0-2,6,7
    配置     3 vCPU, 1280 MiB, 磁盘 12G, 端口 8025
    物理核   0-2,6-7  (3×A55 + 2×A76)
    登录     alice / *********  要看密码： ckvm ssh cmd1 -p
    连接     ssh alice@127.0.0.1 -p 8025
    串口日志 195.1K
    登录提示 已出现
```

```
$ ckvm cache

  💾 镜像缓存  /var/lib/ckvm/.cache
  ────────────────────────────────────────────────────────────────────

    版本             大小  状态
    ────────────────────────────────────────
    26.04          901.7M  ✓
    ────────────────────────────────────────
    合计           901.7M
```

---

## 多开

每台是 `/var/lib/ckvm/<名字>/` 下的独立目录，有自己的磁盘、固件副本、
cloud-init 和端口。

```bash
ckvm create a && ckvm create b
ckvm start a && ckvm start b
```

**端口从 8023 起自动找空闲的**，并且会检查真实占用（不只是别的虚拟机的配置），
不用自己记。

> **内存提醒**：这台机器约 5.5 GB 可用。多开时注意内存之和 ——
> 一次 4 GB 的 guest 加 QEMU 自身开销就要 3.4–3.6 GB RSS。

### 镜像缓存

**基础镜像只下一次，所有虚拟机共用。**

```bash
ckvm cache                 # 看
ckvm cache --clear 24.04   # 删某个版本
ckvm cache --clear         # 全清
```

命中缓存时：

```
  ✅ 使用缓存 Ubuntu 26.04（901.7M，跳过下载）
  从缓存复制基础镜像...
```

**开 3 台同版本只下载 1 次。**

---

## 网络

### user 模式（默认）

QEMU 自己做 NAT，靠端口映射访问。**任何环境都能用。**

```
    宿主机 8025 → guest 22
    宿主机 8080 → guest 80
```

### host 模式（tap）

guest 拿自己的 IP，**自己跑 sshd**，不需要端口映射：

```bash
ckvm create srv --net host
```

guest 在 `172.28.100.2/24`，网关 `172.28.100.1`。

> **⚠️ 局域网访问**：`172.28.100.x` 是**容器内部网段**，不是手机在局域网上的地址，
> 局域网里其他电脑直连不到。想真正暴露到局域网，得在 Android 宿主侧做端口转发
> 或建网桥（见 [TECHNICAL.md](TECHNICAL.md) 第 6.4 节）。

### systemd

```bash
ckvm enable cmd1                  # 启用 + 启动 + 开机自启
systemctl status ckvm@cmd1
journalctl -u    ckvm@cmd1
ckvm disable cmd1
```

---

## 常见问题

**`Failed to put registers after init`**

旧内核的 big.LITTLE 跨簇问题，**当前内核已修复**。看到了说明跑的是旧内核。

**创建时卡在下载**

中断了下次会续传。换源：

```bash
export MIRROR_IMAGE_LIST="https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cloud-images"
```

**GRUB 加载后卡住**

NVRAM 被污染。`ckvm start` 每次都会从模板重建 `uefi-vars.fd`，重启一次即可。

**想换用户名密码**

cloud-init 只在首次启动生效，所以 `ckvm rm` 重建，或进系统 `passwd`。

**`ckvm ssh` 报 `Permission denied`**

先确认 guest 起来了（`ckvm status <名字>` 看有没有登录提示）。
密码在 `vm.conf` 的 `VM_PASS`，或 `ckvm ssh <名字> -p` 看。

**找不到固件**

`ckvm install` 会下载。或从设备拷：

```bash
su -c 'mkdir -p /sdcard/limbo_fw && cp /data/data/com.limbo.emu.main.arm/cache/limbo/edk2/*.fd /sdcard/limbo_fw/'
su -c 'cp /sdcard/limbo_fw/edk2_*.fd /usr/local/share/ckvm/firmware/'
```

---

## 环境

```text
设备    小米 MT6833 / evergo（红米 Note 11T 5G，天玑 810）
        6×A55 @2.0GHz  +  2×A76 @2.4GHz
容器    droidspaces（Debian 13，systemd 作为 PID 1）
内核    4.14.356-Evergo-KVM-cuicanmx-v1.0
guest   Ubuntu 22.04 – 26.04
数据    /var/lib/ckvm        固件 /usr/local/share/ckvm/firmware
```

**性能参考**（guest 内 `openssl speed -multi 8 -evp sha256`，本机实测）：

| 物理核 | 吞吐 |
|---|---|
| 全部 8 核 | **7.4 – 7.7 GB/s** |
| 仅 2 个大核 | 2.9 – 3.0 GB/s |

全核约为大核专用的 **2.6 倍**。

---

## 文档

- **[TECHNICAL.md](TECHNICAL.md)** —— 技术文档：硬件与特权模型、
  `ESR_EL2.ISV == 0` 的架构根因、内核回移的 ABI 细节、固件选择依据、
  big.LITTLE 寄存器快照的完整分析与实测（第 12 章）、完整实测数据集，
  **以及每一处结论的出处**。

---

## 作者与许可

**璀璨梦星 · cuicanmx** · <https://github.com/ccmx200>

`ckvm` 以 **GPL-2.0** 发布，与内核树保持一致。
内核移植来源与各组件出处见 [TECHNICAL.md](TECHNICAL.md) 的出处章节。
