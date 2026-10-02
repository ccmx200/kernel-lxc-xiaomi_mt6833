# ReSukiSU 内核修改说明

本源码树基于 [weaponmasterjax/kernel_xiaomi_mt6833-new](https://github.com/weaponmasterjax/kernel_xiaomi_mt6833-new) `-b pro` 分支，并将原有的 `KernelSU-Next` 替换为 **ReSukiSU**，同时集成 **LXC/Docker 内核支持**。

---

## 📁 目录与集成方式

| 项目 | 路径 |
|------|------|
| ReSukiSU 源码 | `ReSukiSU/` |
| 内核构建入口 | `drivers/kernelsu -> ../ReSukiSU/kernel`（软链接） |
| 设备 defconfig | `arch/arm64/configs/everpal_defconfig` |
| LXC/Docker 支持 | `utils/`（Kconfig + 补丁） |
| 构建脚本 | `b.sh` |
| 输出目录 | `out/` |

---

## ⚙️ 内核配置说明

### ReSukiSU Hook 模式

```text
CONFIG_KSU=y
# CONFIG_KSU_TRACEPOINT_HOOK is not set
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_SUSFS is not set
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y
```

**为什么使用 manual hook？**

当前内核为 4.14（non-GKI），ReSukiSU 的默认 Tracepoint Hook 仅支持 GKI 2.0（5.10+）内核，因此必须切到 **manual hook** 模式。该模式兼容 Linux 3.4 ~ 6.18，正好覆盖本内核。

**为什么禁用 SUSFS？**

原来内核中来自 KernelSU-Next 的旧 SUSFS 补丁与 ReSukiSU 当前的 SUSFS 检查不兼容；SUSFS 官方也已停止 Non-GKI 支持。为保证 4.14 MTK 内核可编译、可开机，本构建先禁用 `CONFIG_KSU_SUSFS`。ReSukiSU 的 Root 功能不受影响。

### LXC / Docker 支持

```text
CONFIG_DOCKER=y
# CONFIG_ANDROID_PARANOID_NETWORK is not set
```

- `CONFIG_DOCKER` 由 `utils/Kconfig` 提供，会自动 `select` 出 namespaces、cgroups、veth、bridge、overlayfs、nf_nat、iptables 等依赖项
- `ANDROID_PARANOID_NETWORK` 必须关闭，否则容器内 `ping`、`apt` 会 `Permission denied`

如需 SysV IPC（PostgreSQL 等程序依赖），额外启用：

```text
CONFIG_SYSVIPC=y
CONFIG_SYSVIPC_SYSCTL=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
```

---

## 🔨 构建

### 前置依赖

```bash
sudo pacman -S --needed base-devel clang llvm lld ccache \
    bc libelf openssl flex bison pahole xmlto kmod inetutils \
    aarch64-linux-gnu-gcc openbsd-netcat git zip
```

### 基本用法

```bash
cd /root/kernel-lxc_xiaomi_mtk810_mt6833-resukisu
./b.sh
```

脚本会依次执行：

1. **清理旧构建产物**（含 `out/` 下的残留）
2. **检测工具链**（优先 neutron-clang，否则系统 clang），自动启用 ccache
3. **准备 ReSukiSU 源码**：不存在则克隆，已存在则自动检查更新
4. **配置内核**：加载 `everpal_defconfig`
5. **生成 vdso-offsets.h**：解决 4.14 并行编译依赖问题
6. **编译 `Image.gz`**：单行滚动日志显示最新编译命令
7. **打包 AnyKernel3**：生成可刷入 zip

### 命令行选项

```bash
# 默认：直连 GitHub，自动更新 ReSukiSU，启用 ccache
./b.sh

# 走加速代理（默认 https://git.yylx.win/）
./b.sh -cn

# 自定义加速代理
./b.sh -cn https://your-proxy.example/

# 跳过 ReSukiSU 自动更新
./b.sh -nu

# 关闭 ccache
./b.sh --no-ccache

# 完全清理后编译 + 加速
CLEAN_BUILD=true ./b.sh -cn

# 调整错误上下文行数（默认前后各 200 行）
ERROR_CTX=300 ./b.sh -cn

# 自定义工具链目录
TC_DIR=/opt/clang ./b.sh
```

### 输出文件

| 文件 | 说明 |
|------|------|
| `out/arch/arm64/boot/Image.gz` | 编译出的内核镜像 |
| `ReSukiSU-AdrenalinKernel-YYYYMMDD-HHMM.zip` | AnyKernel3 打包后的可刷入 zip |

---

## 🧩 ReSukiSU 版本信息

每次构建时脚本会自动从 git 和源码中提取以下信息并显示：

- **Version**：`git describe --tags` 或 `KSU_VERSION` 宏
- **Commit**：当前提交短哈希
- **Branch**：分支名
- **Commit Date**：最后一次提交时间
- **Working Tree**：`clean` 或 `dirty`

如需跳过自动更新（保留本地修改），用 `-nu`。

---

## 🛠 常见问题

### 编译相关

| 问题 | 原因 | 解决 |
|------|------|------|
| `vdso_offset_sigtramp` 未声明 | `out/include/generated/vdso-offsets.h` 是空的旧文件 | 脚本已处理，如需手动：`rm -rf out/include/generated && make ... arch/arm64/kernel/vdso/` |
| `unknown type name 'syscall_fn_t'` | 4.14 内核无此类型定义 | 手动在报错文件头部加 `typedef long (*syscall_fn_t)(const struct pt_regs *);` |
| `timespec` / `timespec64` 不匹配 | btrfs 源码版本混乱 | 在 defconfig 中 `# CONFIG_BTRFS_FS is not set` |
| `too many errors` 后 hugetlbpage.c 崩 | 源码拼写错误 | 关 `CONFIG_HUGETLBFS`，或改 `ptep` 为 `pte` |

### 运行相关

| 问题 | 原因 | 解决 |
|------|------|------|
| 容器内 `ping` 报 `Permission denied` | `CONFIG_ANDROID_PARANOID_NETWORK` 未关 | 重新编译内核 |
| 容器名解析失败 | 默认 bridge 不支持 | 用 `docker network create` 建自定义网络 |
| `dockerd` 报 iptables 错误 | nft/legacy 后端不匹配 | 切 `iptables-legacy` |
| cgroup 限制不可用 | LXC 未透传 cgroup | 宿主 LXC 配置加 `lxc.mount.auto = cgroup:mixed` |

---

## 📦 目录结构

```
kernel-lxc_xiaomi_mtk810_mt6833-resukisu/
├── b.sh                      # 构建脚本
├── ReSukiSU/                 # ReSukiSU 源码（独立 git）
│   └── kernel/               # → 软链到 drivers/kernelsu
├── utils/                    # LXC/Docker 内核支持
│   ├── Kconfig
│   ├── fix_cgroup.patch
│   └── ...
├── arch/arm64/
│   ├── configs/everpal_defconfig
│   └── mm/hugetlbpage.c      # 已修复 ptep 拼写
├── drivers/
│   ├── kernelsu -> ../ReSukiSU/kernel
│   ├── Makefile
│   └── Kconfig
├── Kconfig                   # 已加 source "utils/Kconfig"
└── out/                      # 构建输出
```

---

## 🔗 相关链接

- [ReSukiSU 官方仓库](https://github.com/ReSukiSU/ReSukiSU)
- [LXC/Docker 内核支持（tomxi1997）](https://github.com/tomxi1997/lxc-docker-support-for-android)
- [LXC Magisk 模块](https://github.com/tomxi1997/lxc-magisk-modules-for-android-)
- [AnyKernel3](https://github.com/weaponmasterjax/AnyKernel3)

---

## 📝 许可

本源码树的内核部分遵循原仓库的许可协议。ReSukiSU、LXC/Docker 补丁、AnyKernel3 各自遵循其原始许可。
