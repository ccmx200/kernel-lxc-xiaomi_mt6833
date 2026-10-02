#!/bin/bash
# ReSukiSU build script for kernel-lxc_xiaomi_mtk810_mt6833 (everpal / MT6833)
# Vendored ReSukiSU is in ./ReSukiSU, exposed to the kernel as drivers/kernelsu.

set -e

CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$CURRENT_DIR"

# ---------------- options ----------------
CLEAN_BUILD="${CLEAN_BUILD:-false}"
INCLUDE_KSU="${INCLUDE_KSU:-true}"   # kept for compatibility; ReSukiSU is always vendored here
ZIP_ANY_KERNEL="${ZIP_ANY_KERNEL:-true}"

# ---------------- clean ----------------
rm -rf out/arch/arm64/boot
rm -rf .config .config.old .tmp_versions
rm -rf include/generated include/config
rm -rf arch/arm64/include/generated
rm -rf vmlinux* System.map modules.builtin*
rm -f Module.symvers modules.order
rm -rf scripts/kconfig/.tmp*

# Clean stale vdso artifacts in out/ to avoid vdso-offsets.h issues
rm -rf out/include/generated out/include/config
rm -rf out/arch/arm64/kernel/vdso
rm -f out/include/generated/vdso-offsets.h

if [ "$CLEAN_BUILD" = true ]; then
    rm -rf out
fi

# ---------------- toolchain ----------------
TC_DIR="${TC_DIR:-$HOME/toolchains/neutron-clang}"
if [ -x "$TC_DIR/bin/clang" ]; then
    export PATH="$TC_DIR/bin:$PATH"
    CLANG="$TC_DIR/bin/clang"
else
    CLANG="$(command -v clang)"
fi

if [ -z "$CLANG" ]; then
    echo "ERROR: clang not found. Set TC_DIR or install clang." >&2
    exit 1
fi

export CC="${CC:-$CLANG}"
export LD="${LD:-ld.lld}"

# Optional ccache
if command -v ccache >/dev/null 2>&1 && [ -z "${NO_CCACHE:-}" ]; then
    CC="ccache $CC"
fi

# ---------------- device / output ----------------
SECONDS=0
DATE="$(date '+%Y%m%d-%H%M')"
DEVICE="${DEVICE:-everpal}"
DEFCONFIG="${DEVICE}_defconfig"
ZIPNAME="ReSukiSU-AdrenalinKernel-${DATE}.zip"

# ---------------- ReSukiSU setup ----------------
# If the vendored source is missing, fetch it from the requested mirror.
if [ ! -d "$CURRENT_DIR/ReSukiSU/kernel" ]; then
    echo "ReSukiSU source not found; cloning from git.yylx.win ..."
    GIT_SSL_NO_VERIFY=true git clone --depth=1 --branch main \
        https://git.yylx.win/github.com/ReSukiSU/ReSukiSU.git "$CURRENT_DIR/ReSukiSU"
fi

# Expose the ReSukiSU kernel directory to the kernel build system.
rm -f drivers/kernelsu
ln -sfn ../ReSukiSU/kernel drivers/kernelsu

grep -q 'kernelsu' drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || \
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

# ---------------- build ----------------
echo
echo "Using compiler:"
"$CLANG" --version | head -n 2
echo

MAKE_COMMON=(
    O=out
    ARCH=arm64
    CC="$CC"
    LD="$LD"
    LLVM=1
    LLVM_IAS=1
    NM=llvm-nm
    CROSS_COMPILE=aarch64-linux-gnu-
)
if command -v arm-linux-gnueabi-gcc >/dev/null 2>&1; then
    MAKE_COMMON+=(CROSS_COMPILE_ARM32=arm-linux-gnueabi-)
fi

echo "Configuring $DEFCONFIG ..."
make "${MAKE_COMMON[@]}" "$DEFCONFIG"

echo
echo "Generating vdso-offsets.h ..."
make "${MAKE_COMMON[@]}" arch/arm64/kernel/vdso/

if [ -f out/include/generated/vdso-offsets.h ]; then
    echo "vdso-offsets.h:"
    cat out/include/generated/vdso-offsets.h
else
    echo "ERROR: vdso-offsets.h was not generated" >&2
    exit 1
fi

echo
echo "Compiling kernel Image.gz ..."
if make -j"$(nproc --all)" "${MAKE_COMMON[@]}" \
    KCFLAGS="-Wno-error=default-const-init-var-unsafe -Wno-default-const-init-var-unsafe" \
    Image.gz; then

    echo
    echo "Kernel compiled successfully."
    echo "Image.gz: $CURRENT_DIR/out/arch/arm64/boot/Image.gz"

    if [ "$ZIP_ANY_KERNEL" = true ]; then
        echo
        echo "Packaging AnyKernel3 zip ..."
        rm -rf AnyKernel3
        if GIT_SSL_NO_VERIFY=true git clone -q --depth=1 \
            https://git.yylx.win/github.com/weaponmasterjax/AnyKernel3 AnyKernel3; then
            cp out/arch/arm64/boot/Image.gz AnyKernel3/
            (cd AnyKernel3 && zip -r9 "../$ZIPNAME" . -x '*.git*' README.md '*placeholder' >/dev/null)
            rm -rf AnyKernel3
            echo "Zip: $CURRENT_DIR/$ZIPNAME"
        else
            echo "WARNING: AnyKernel3 clone failed; only Image.gz was produced."
            rm -rf AnyKernel3
        fi
    fi

    echo
    echo "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)."
else
    echo "Compilation failed." >&2
    exit 1
fi
