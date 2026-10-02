#!/bin/bash
# =============================================================================
#  ReSukiSU Kernel Build Script
#  Target : kernel-lxc_xiaomi_mtk810_mt6833 (everpal / MT6833)
#  Author : refactored
# =============================================================================

set -euo pipefail

# =============================================================================
#  颜色 / 样式
# =============================================================================
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_RED='\033[1;31m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[1;34m'
readonly C_MAGENTA='\033[1;35m'
readonly C_CYAN='\033[1;36m'
readonly C_WHITE='\033[1;37m'
readonly C_BG_BLUE='\033[44m'

# =============================================================================
#  动画工具
# =============================================================================
SPINNER_PID=""

# 启动旋转动画
spin_start() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while :; do
            printf "\r${C_CYAN}  %s${C_RESET}  ${C_DIM}%s${C_RESET}" "${frames[$i]}" "$msg"
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.08
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
}

# 停止旋转动画
spin_stop() {
    local status="${1:-ok}"
    local msg="${2:-}"
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi
    printf "\r\033[K"
    case "$status" in
        ok)   printf "${C_GREEN}  ✓${C_RESET}  %s\n" "$msg" ;;
        fail) printf "${C_RED}  ✗${C_RESET}  %s\n" "$msg" ;;
        warn) printf "${C_YELLOW}  !${C_RESET}  %s\n" "$msg" ;;
        *)    printf "  %s\n" "$msg" ;;
    esac
}

# 进度条
progress_bar() {
    local current=$1
    local total=$2
    local width=${3:-40}
    local label="${4:-}"
    local percent=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    printf "\r${C_BLUE}  [${C_RESET}"
    printf "${C_GREEN}%${filled}s${C_RESET}" "" | tr ' ' '█'
    printf "${C_DIM}%${empty}s${C_RESET}" "" | tr ' ' '░'
    printf "${C_BLUE}]${C_RESET} ${C_BOLD}%3d%%${C_RESET}  ${C_DIM}%s${C_RESET}" "$percent" "$label"
    if [ "$current" -eq "$total" ]; then
        printf "\n"
    fi
}

# =============================================================================
#  日志工具
# =============================================================================
log_section() {
    echo
    printf "${C_BG_BLUE}${C_WHITE}  %s  ${C_RESET}\n" "$1"
    echo
}

log_info() {
    printf "${C_CYAN}  ▸${C_RESET}  %s\n" "$1"
}

log_ok() {
    printf "${C_GREEN}  ✓${C_RESET}  %s\n" "$1"
}

log_warn() {
    printf "${C_YELLOW}  !${C_RESET}  %s\n" "$1"
}

log_error() {
    printf "${C_RED}  ✗${C_RESET}  %s\n" "$1" >&2
}

log_dim() {
    printf "${C_DIM}     %s${C_RESET}\n" "$1"
}

# 分隔线
hr() {
    printf "${C_DIM}"
    printf '─%.0s' $(seq 1 70)
    printf "${C_RESET}\n"
}

# =============================================================================
#  Banner
# =============================================================================
banner() {
    clear 2>/dev/null || true
    echo
    printf "${C_MAGENTA}"
    cat <<'EOF'
    ╔══════════════════════════════════════════════════════════════╗
    ║                                                              ║
    ║     ██████╗ ███████╗███████╗██╗   ██╗██╗  ██╗██╗             ║
    ║     ██╔══██╗██╔════╝██╔════╝██║   ██║██║ ██╔╝██║             ║
    ║     ██████╔╝█████╗  ███████╗██║   ██║█████╔╝ ██║             ║
    ║     ██╔══██╗██╔══╝  ╚════██║██║   ██║██╔═██╗ ██║             ║
    ║     ██║  ██║███████╗███████║╚██████╔╝██║  ██╗██║             ║
    ║     ╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝             ║
    ║                                                              ║
    ║           Kernel Build System  ·  everpal / MT6833           ║
    ║                                                              ║
    ╚══════════════════════════════════════════════════════════════╝
EOF
    printf "${C_RESET}\n"
}

# =============================================================================
#  配置
# =============================================================================
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$CURRENT_DIR"

CLEAN_BUILD="${CLEAN_BUILD:-false}"
INCLUDE_KSU="${INCLUDE_KSU:-true}"
ZIP_ANY_KERNEL="${ZIP_ANY_KERNEL:-true}"

SECONDS=0
DATE="$(date '+%Y%m%d-%H%M')"
DEVICE="${DEVICE:-everpal}"
DEFCONFIG="${DEVICE}_defconfig"
ZIPNAME="ReSukiSU-AdrenalinKernel-${DATE}.zip"

# =============================================================================
#  Main
# =============================================================================
banner

# -----------------------------------------------------------------------------
log_section "1 / 6  ·  清理旧构建产物"
# -----------------------------------------------------------------------------
spin_start "Removing stale artifacts..."

rm -rf out/arch/arm64/boot
rm -rf .config .config.old .tmp_versions
rm -rf include/generated include/config
rm -rf arch/arm64/include/generated
rm -rf vmlinux* System.map modules.builtin*
rm -f Module.symvers modules.order
rm -rf scripts/kconfig/.tmp*

# vdso 残留
rm -rf out/include/generated out/include/config
rm -rf out/arch/arm64/kernel/vdso
rm -f out/include/generated/vdso-offsets.h

if [ "$CLEAN_BUILD" = true ]; then
    rm -rf out
fi

spin_stop ok "Cleanup complete"

# -----------------------------------------------------------------------------
log_section "2 / 6  ·  工具链准备"
# -----------------------------------------------------------------------------
TC_DIR="${TC_DIR:-$HOME/toolchains/neutron-clang}"

spin_start "Detecting toolchain..."
if [ -x "$TC_DIR/bin/clang" ]; then
    export PATH="$TC_DIR/bin:$PATH"
    CLANG="$TC_DIR/bin/clang"
    TOOLCHAIN_SRC="neutron-clang ($TC_DIR)"
else
    CLANG="$(command -v clang || true)"
    TOOLCHAIN_SRC="system clang"
fi

if [ -z "${CLANG:-}" ]; then
    spin_stop fail "clang not found. Set TC_DIR or install clang."
    exit 1
fi

export CC="${CC:-$CLANG}"
export LD="${LD:-ld.lld}"

if command -v ccache >/dev/null 2>&1 && [ -z "${NO_CCACHE:-}" ]; then
    CC="ccache $CC"
    CCACHE_STATE="enabled"
else
    CCACHE_STATE="disabled"
fi
spin_stop ok "Toolchain: $TOOLCHAIN_SRC  ·  ccache: $CCACHE_STATE"

# -----------------------------------------------------------------------------
log_section "3 / 6  ·  ReSukiSU 源码准备"
# -----------------------------------------------------------------------------
if [ ! -d "$CURRENT_DIR/ReSukiSU/kernel" ]; then
    spin_start "Cloning ReSukiSU..."
    if GIT_SSL_NO_VERIFY=true git clone --depth=1 --branch main \
        https://git.yylx.win/github.com/ReSukiSU/ReSukiSU.git "$CURRENT_DIR/ReSukiSU" >/dev/null 2>&1; then
        spin_stop ok "ReSukiSU cloned"
    else
        spin_stop fail "Failed to clone ReSukiSU"
        exit 1
    fi
else
    log_ok "ReSukiSU source already present"
fi

# 建立软链接
rm -f drivers/kernelsu
ln -sfn ../ReSukiSU/kernel drivers/kernelsu

# 挂载到 Kconfig / Makefile
grep -q 'kernelsu' drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || \
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

log_ok "ReSukiSU integrated into kernel tree"

# -----------------------------------------------------------------------------
log_section "4 / 6  ·  内核配置"
# -----------------------------------------------------------------------------
echo
echo "  Using compiler:"
"$CLANG" --version | head -n 2 | sed 's/^/    /'
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

spin_start "Configuring $DEFCONFIG ..."
if make "${MAKE_COMMON[@]}" "$DEFCONFIG" >/dev/null 2>&1; then
    spin_stop ok "Configuration written"
else
    spin_stop fail "defconfig failed"
    exit 1
fi

# -----------------------------------------------------------------------------
log_section "5 / 6  ·  VDSO 符号生成"
# -----------------------------------------------------------------------------
spin_start "Building vdso-offsets.h ..."
if make "${MAKE_COMMON[@]}" arch/arm64/kernel/vdso/ >/dev/null 2>&1; then
    if [ -f out/include/generated/vdso-offsets.h ]; then
        spin_stop ok "vdso-offsets.h generated"
    else
        spin_stop fail "vdso-offsets.h not found"
        exit 1
    fi
else
    spin_stop fail "vdso build failed"
    exit 1
fi

# -----------------------------------------------------------------------------
log_section "6 / 6  ·  编译内核"
# -----------------------------------------------------------------------------
echo
log_info "Starting compilation (this may take a while)..."
echo

BUILD_LOG="$(mktemp /tmp/kernel-build-XXXXXX.log)"
trap 'rm -f "$BUILD_LOG"' EXIT

START_TS=$(date +%s)

if make -j"$(nproc --all)" "${MAKE_COMMON[@]}" \
    KCFLAGS="-Wno-error=default-const-init-var-unsafe -Wno-default-const-init-var-unsafe" \
    Image.gz >"$BUILD_LOG" 2>&1; then

    END_TS=$(date +%s)
    BUILD_TIME=$(( END_TS - START_TS ))

    echo
    hr
    log_ok "Kernel compiled successfully in ${BUILD_TIME}s"
    log_dim "Image.gz: $CURRENT_DIR/out/arch/arm64/boot/Image.gz"
    hr

    # -------------------------------------------------------------------------
    if [ "$ZIP_ANY_KERNEL" = true ]; then
        echo
        spin_start "Packaging AnyKernel3 zip ..."
        rm -rf AnyKernel3

        if GIT_SSL_NO_VERIFY=true git clone -q --depth=1 \
            https://git.yylx.win/github.com/weaponmasterjax/AnyKernel3 AnyKernel3 >/dev/null 2>&1; then

            cp out/arch/arm64/boot/Image.gz AnyKernel3/
            (cd AnyKernel3 && zip -r9 "../$ZIPNAME" . \
                -x '*.git*' README.md '*placeholder' >/dev/null 2>&1)
            rm -rf AnyKernel3
            spin_stop ok "Zip: $CURRENT_DIR/$ZIPNAME"
        else
            spin_stop warn "AnyKernel3 clone failed; only Image.gz produced"
            rm -rf AnyKernel3
        fi
    fi

    echo
    hr
    printf "${C_GREEN}${C_BOLD}  ██████╗  ██████╗ ███╗   ██╗███████╗${C_RESET}\n"
    printf "${C_GREEN}${C_BOLD}  ██╔══██╗██╔═══██╗████╗  ██║██╔════╝${C_RESET}\n"
    printf "${C_GREEN}${C_BOLD}  ██║  ██║██║   ██║██╔██╗ ██║█████╗  ${C_RESET}\n"
    printf "${C_GREEN}${C_BOLD}  ██║  ██║██║   ██║██║╚██╗██║██╔══╝  ${C_RESET}\n"
    printf "${C_GREEN}${C_BOLD}  ██████╔╝╚██████╔╝██║ ╚████║███████╗${C_RESET}\n"
    printf "${C_GREEN}${C_BOLD}  ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝${C_RESET}\n"
    echo
    printf "  ${C_DIM}Total time:${C_RESET} ${C_BOLD}%d minute(s) %d second(s)${C_RESET}\n" \
        $((SECONDS / 60)) $((SECONDS % 60))
    echo
    hr
else
    echo
    hr
    log_error "Compilation failed"
    hr
    echo
    log_info "Last 40 lines of build log:"
    echo
    tail -n 40 "$BUILD_LOG" | sed 's/^/    /'
    echo
    log_dim "Full log: $BUILD_LOG"
    exit 1
fi
