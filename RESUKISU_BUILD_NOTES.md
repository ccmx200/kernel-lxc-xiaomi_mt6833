# ReSukiSU 内核修改说明

本源码树已将原来的 `KernelSU-Next` 替换为 ReSukiSU。

## 目录/集成方式

- ReSukiSU 源码：`ReSukiSU/`
- 内核构建入口：`drivers/kernelsu -> ../ReSukiSU/kernel`
- 设备 defconfig：`arch/arm64/configs/everpal_defconfig`
- 构建脚本：`build.sh`

## defconfig 关键配置

```text
CONFIG_KSU=y
# CONFIG_KSU_TRACEPOINT_HOOK is not set
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_SUSFS is not set
CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK=y
CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK=y
```

说明：当前使用 ReSukiSU 的 manual hook 模式。原来内核中来自 KernelSU-Next 的旧
SUSFS 补丁与 ReSukiSU 当前的 SUSFS 检查不兼容；SUSFS 官方也已停止 Non-GKI 支持，
因此本构建先禁用 `CONFIG_KSU_SUSFS` 以保证 4.14 MTK 内核可编译、可开机。ReSukiSU
Root 功能正常工作。

## 构建

在 WSL / Linux 下执行：

```sh
cd /root/kernel-lxc_xiaomi_mtk810_mt6833
./build.sh
```

脚本会：

1. 清理旧构建产物；
2. 使用 `ReSukiSU/kernel` 作为 `drivers/kernelsu`；
3. 使用 `everpal_defconfig` 配置；
4. 生成 `vdso-offsets.h`；
5. 编译 `Image.gz`；
6. 使用 AnyKernel3 打包 zip。

输出：

- `out/arch/arm64/boot/Image.gz`
- `ReSukiSU-AdrenalinKernel-YYYYMMDD-HHMM.zip`

## 推送新仓库

```sh
cd /root/kernel-lxc_xiaomi_mtk810_mt6833
git remote add resukisu <你的新仓库地址>
git add -A
git commit -m "kernel: switch to ReSukiSU manual hook"
git push -u resukisu <分支名>
```
