#!/bin/bash
# =============================================================================
#  ReSukiSU Kernel Build Script
#  Target : kernel-lxc_xiaomi_mtk810_mt6833 (everpal / MT6833)
#  Usage  : ./b.sh [-cn [URL]] [--no-ccache] [--no-update] [--proxy URL]
#                   [-cf FILE] [-c OPT] [--menuconfig] [--check]
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
#  Colors
# -----------------------------------------------------------------------------
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_RED='\033[1;31m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[1;36m'
readonly C_MAGENTA='\033[1;35m'
readonly C_WHITE='\033[1;37m'
readonly C_ORANGE='\033[38;5;208m'
readonly C_SKY='\033[38;5;117m'
readonly C_BG_ORANGE='\033[48;5;208m'
readonly C_BG_RED='\033[48;5;160m'

# -----------------------------------------------------------------------------
#  CLI arguments
# -----------------------------------------------------------------------------
GH_PROXY=""
NO_CCACHE=""
NO_UPDATE=""
CHECK_ONLY=""
MENUCONFIG=""
CONFIG_FILES=()
CONFIG_OPTS=()

usage() {
    cat <<EOF
ReSukiSU Kernel Build Script

Usage: $0 [options]

General:
  -cn [URL]           Enable GitHub acceleration (default: https://git.yylx.win/)
  --proxy URL         Same as -cn URL
  --no-ccache         Disable ccache (ccache is ON by default)
  -nu, --no-update    Skip ReSukiSU auto-update
  --check, --test     Only run syntax/toolchain/defconfig sanity check
  -h, --help          Show this help

Kernel config (applied AFTER defconfig, BEFORE compile):
  -cf, --config-file FILE   Append a kernel config fragment (repeatable)
  -c,  --config OPT         Append a single config option (repeatable)
                            e.g. -c CONFIG_SYSVIPC=y
                                 -c '# CONFIG_ANDROID_PARANOID_NETWORK is not set'
  -m,  --menuconfig         Launch interactive menuconfig before compile
  -s,  --save-config        Save the final .config to \$CURRENT_DIR/kernel.config

Environment variables:
  CLEAN_BUILD=true       Perform a full clean build
  ZIP_ANY_KERNEL=false   Skip AnyKernel3 packaging
  DEVICE=everpal         Target device codename
  TC_DIR=/path/to/clang  Custom toolchain directory
  ERROR_CTX=200          Lines of context around first error
  KCFG_FILE=path         Same as -cf, can list multiple with colon
  KCFG_OPT="..."         Same as -c, can list multiple with semicolon
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -cn|--cn)
            if [ -n "${2:-}" ] && [[ "${2:-}" =~ ^https?:// ]]; then
                GH_PROXY="$2"
                shift
            else
                GH_PROXY="https://git.yylx.win/"
            fi
            ;;
        --proxy)
            if [ -n "${2:-}" ]; then
                GH_PROXY="$2"
                shift
            fi
            ;;
        --no-ccache)   NO_CCACHE=1 ;;
        -nu|--no-update) NO_UPDATE=1 ;;
        --check|--test)  CHECK_ONLY=1 ;;
        -m|--menuconfig) MENUCONFIG=1 ;;
        -cf|--config-file)
            if [ -n "${2:-}" ]; then
                CONFIG_FILES+=("$2")
                shift
            else
                printf "Missing FILE argument for %s\n" "$1" >&2
                exit 1
            fi
            ;;
        -c|--config)
            if [ -n "${2:-}" ]; then
                CONFIG_OPTS+=("$2")
                shift
            else
                printf "Missing OPT argument for %s\n" "$1" >&2
                exit 1
            fi
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf "Unknown option: %s\n\n" "$1" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

# 环境变量里的额外配置
if [ -n "${KCFG_FILE:-}" ]; then
    IFS=':' read -ra _kf <<< "$KCFG_FILE"
    for f in "${_kf[@]}"; do
        [ -n "$f" ] && CONFIG_FILES+=("$f")
    done
fi
if [ -n "${KCFG_OPT:-}" ]; then
    IFS=';' read -ra _ko <<< "$KCFG_OPT"
    for o in "${_ko[@]}"; do
        [ -n "$o" ] && CONFIG_OPTS+=("$o")
    done
fi

# -----------------------------------------------------------------------------
#  GitHub URL rewriting
# -----------------------------------------------------------------------------
gh_url() {
    local url="$1"
    if [ -z "$GH_PROXY" ]; then
        printf '%s' "$url"
        return
    fi
    printf '%s' "$url" | sed \
        -e "s|https://github.com/|${GH_PROXY}github.com/|g" \
        -e "s|https://raw.githubusercontent.com/|${GH_PROXY}raw.githubusercontent.com/|g" \
        -e "s|https://objects.githubusercontent.com/|${GH_PROXY}objects.githubusercontent.com/|g"
}

rewrite_gh_links_in() {
    local dir="$1"
    [ -z "$GH_PROXY" ] && { printf '0'; return 0; }
    [ -d "$dir" ] || { printf '0'; return 0; }

    local count=0
    while IFS= read -r -d '' file; do
        if grep -q 'github\.com\|githubusercontent\.com' "$file" 2>/dev/null; then
            if ! grep -q "$GH_PROXY" "$file" 2>/dev/null; then
                sed -i \
                    -e "s|https://github.com/|${GH_PROXY}github.com/|g" \
                    -e "s|https://raw.githubusercontent.com/|${GH_PROXY}raw.githubusercontent.com/|g" \
                    -e "s|https://objects.githubusercontent.com/|${GH_PROXY}objects.githubusercontent.com/|g" \
                    "$file"
                count=$((count + 1))
            fi
        fi
    done < <(find "$dir" -type f -name '*.sh' -print0 2>/dev/null || true)
    printf '%d' "$count"
    return 0
}

# -----------------------------------------------------------------------------
#  Spinner animation
# -----------------------------------------------------------------------------
SPINNER_PID=""

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

# -----------------------------------------------------------------------------
#  Single-line rolling build log
# -----------------------------------------------------------------------------
ROLL_PID=""
ROLL_STOP_FILE=""

roll_start() {
    local log_file="$1"
    ROLL_STOP_FILE="$(mktemp /tmp/kernel-roll-stop-XXXXXX)"
    : > "$ROLL_STOP_FILE"
    (
        local last_line=""
        while [ ! -s "$ROLL_STOP_FILE" ]; do
            if [ -s "$log_file" ]; then
                last_line="$(tail -n 1 "$log_file" 2>/dev/null || true)"
                if [ -n "$last_line" ]; then
                    [ "${#last_line}" -gt 100 ] && last_line="${last_line:0:97}..."
                    printf "\r\033[K${C_SKY}  ▸${C_RESET} ${C_DIM}%s${C_RESET}" "$last_line"
                fi
            fi
            sleep 0.12
        done
        printf "\r\033[K"
    ) &
    ROLL_PID=$!
    disown "$ROLL_PID" 2>/dev/null || true
}

roll_stop() {
    if [ -n "$ROLL_PID" ]; then
        : > "$ROLL_STOP_FILE"
        sleep 0.15
        kill "$ROLL_PID" 2>/dev/null || true
        wait "$ROLL_PID" 2>/dev/null || true
        ROLL_PID=""
    fi
    [ -n "$ROLL_STOP_FILE" ] && rm -f "$ROLL_STOP_FILE"
    ROLL_STOP_FILE=""
    printf "\r\033[K"
}

# -----------------------------------------------------------------------------
#  Error extraction with N lines of context
# -----------------------------------------------------------------------------
ERROR_CTX="${ERROR_CTX:-200}"

print_error_context() {
    local log_file="$1"
    local ctx="$ERROR_CTX"

    [ -f "$log_file" ] || return 0

    local first_err
    first_err="$(grep -n -m1 -E '([[:space:]]error:|^error:|Error [0-9]+|ERROR:|fatal error:)' "$log_file" 2>/dev/null | cut -d: -f1 || true)"

    if [ -z "$first_err" ]; then
        echo
        printf "${C_BG_RED}${C_WHITE}${C_BOLD}  Build failed · no 'error:' marker found · showing last 40 lines  ${C_RESET}\n"
        echo
        tail -n 40 "$log_file" | sed 's/^/    /'
        return 0
    fi

    local total
    total="$(wc -l < "$log_file")"
    local start=$(( first_err - ctx ))
    local end=$(( first_err + ctx ))
    [ "$start" -lt 1 ] && start=1
    [ "$end" -gt "$total" ] && end="$total"

    echo
    printf "${C_BG_RED}${C_WHITE}${C_BOLD}  Build failed  ·  first error at line %d of %d  ·  context ±%d lines  ${C_RESET}\n" \
        "$first_err" "$total" "$ctx"
    echo
    printf "${C_DIM}  ── lines %d..%d ──────────────────────────────────────────${C_RESET}\n\n" \
        "$start" "$end"

    awk -v s="$start" -v e="$end" -v fe="$first_err" '
        NR >= s && NR <= e {
            line = $0
            if (NR == fe) {
                printf "\033[1;31m  ▶ %s\033[0m\n", line
            } else {
                printf "    %s\n", line
            }
        }
    ' "$log_file"

    echo
    printf "${C_DIM}  ──────────────────────────────────────────────────────────${C_RESET}\n"
    printf "  ${C_DIM}Full log:${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$log_file"
}

# -----------------------------------------------------------------------------
#  Kernel config helpers
# -----------------------------------------------------------------------------

# 用内核自带的 merge_config.sh 合并配置片段
apply_config_files() {
    local -n _files="$1"
    [ "${#_files[@]}" -eq 0 ] && return 0

    local merge_script="scripts/kconfig/merge_config.sh"
    local tmp_fragment
    tmp_fragment="$(mktemp /tmp/kcfg-frag-XXXXXX)"

    # 把所有片段合并成一个临时文件
    for f in "${_files[@]}"; do
        if [ ! -f "$f" ]; then
            log_warn "Config file not found: $f"
            continue
        fi
        echo "# ---- from $f ----" >> "$tmp_fragment"
        cat "$f" >> "$tmp_fragment"
    done

    if [ ! -s "$tmp_fragment" ]; then
        rm -f "$tmp_fragment"
        return 0
    fi

    if [ -x "$merge_script" ]; then
        # 官方脚本会处理冲突并报告
        "$merge_script" -m -O out out/.config "$tmp_fragment" >/dev/null 2>&1 || true
    else
        # 回退：直接拼接后重跑 olddefconfig
        cat "$tmp_fragment" >> out/.config
    fi

    rm -f "$tmp_fragment"
    return 0
}

# 追加单条配置项到 .config，并记录
apply_config_opts() {
    local -n _opts="$1"
    [ "${#_opts[@]}" -eq 0 ] && return 0

    local tmp
    tmp="$(mktemp /tmp/kcfg-opt-XXXXXX)"
    for o in "${_opts[@]}"; do
        printf '%s\n' "$o" >> "$tmp"
    done

    if [ -x "scripts/kconfig/merge_config.sh" ]; then
        scripts/kconfig/merge_config.sh -m -O out out/.config "$tmp" >/dev/null 2>&1 || true
    else
        cat "$tmp" >> out/.config
    fi

    rm -f "$tmp"
    return 0
}

# 把 .config 中与 defconfig 的差异打印出来
show_config_diff() {
    local base="arch/arm64/configs/$DEFCONFIG"
    [ -f "$base" ] || return 0
    [ -f out/.config ] || return 0

    local diff_count
    diff_count=$(grep -vE '^\s*(#|$)' out/.config | wc -l)
    log_dim "Final .config entries: $diff_count"
}

# -----------------------------------------------------------------------------
#  Logging helpers
# -----------------------------------------------------------------------------
log_section() {
    local title="$1"
    echo
    printf "${C_BG_ORANGE}${C_WHITE}${C_BOLD}  %s  ${C_RESET}\n" "$title"
    echo
}

log_info()  { printf "${C_CYAN}  ▸${C_RESET}  %s\n" "$1"; }
log_ok()    { printf "${C_GREEN}  ✓${C_RESET}  %s\n" "$1"; }
log_warn()  { printf "${C_YELLOW}  !${C_RESET}  %s\n" "$1"; }
log_error() { printf "${C_RED}  ✗${C_RESET}  %s\n" "$1" >&2; }
log_dim()   { printf "${C_DIM}     %s${C_RESET}\n" "$1"; }

hr() {
    printf "${C_DIM}"
    printf '─%.0s' $(seq 1 72)
    printf "${C_RESET}\n"
}

# -----------------------------------------------------------------------------
#  Banner
# -----------------------------------------------------------------------------
banner() {
    clear 2>/dev/null || true
    echo
    printf "${C_ORANGE}${C_BOLD}  ReSukiSU Kernel Builder${C_RESET}\n"
    printf "${C_DIM}  everpal / MT6833${C_RESET}\n"
    echo
    if [ -n "$GH_PROXY" ]; then
        printf "  ${C_CYAN}GitHub proxy${C_RESET}  ${C_BOLD}%s${C_RESET}\n" "$GH_PROXY"
    else
        printf "  ${C_DIM}GitHub proxy: disabled (use -cn to enable)${C_RESET}\n"
    fi
    if [ -n "$NO_UPDATE" ]; then
        printf "  ${C_DIM}ReSukiSU auto-update: disabled${C_RESET}\n"
    fi
    if [ "${#CONFIG_FILES[@]}" -gt 0 ]; then
        printf "  ${C_CYAN}Config fragments${C_RESET}  %d file(s)\n" "${#CONFIG_FILES[@]}"
    fi
    if [ "${#CONFIG_OPTS[@]}" -gt 0 ]; then
        printf "  ${C_CYAN}Config overrides${C_RESET}  %d option(s)\n" "${#CONFIG_OPTS[@]}"
    fi
    [ -n "$MENUCONFIG" ] && printf "  ${C_CYAN}menuconfig${C_RESET}  will launch before compile\n"
    echo
}

# -----------------------------------------------------------------------------
#  ReSukiSU version info
# -----------------------------------------------------------------------------
RSU_VERSION="unknown"
RSU_COMMIT="unknown"
RSU_BRANCH="unknown"
RSU_DATE="unknown"
RSU_DIRTY="clean"

get_resukisu_info() {
    local dir="$CURRENT_DIR/ReSukiSU"

    RSU_VERSION="unknown"
    RSU_COMMIT="unknown"
    RSU_BRANCH="unknown"
    RSU_DATE="unknown"
    RSU_DIRTY="clean"

    if [ ! -d "$dir/.git" ] && [ -d "$dir/kernel" ]; then
        RSU_VERSION="vendored"
        RSU_COMMIT="vendored"
        RSU_BRANCH="main"
        RSU_DATE="unknown"
        RSU_DIRTY="clean"
        return 0
    fi

    if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        RSU_COMMIT="$(git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
        RSU_BRANCH="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
        RSU_DATE="$(git -C "$dir" log -1 --format='%cd' --date=format:'%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)"

        if ! git -C "$dir" diff --quiet 2>/dev/null || \
           ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
            RSU_DIRTY="dirty"
        fi

        local described
        described="$(git -C "$dir" describe --tags --always 2>/dev/null || echo '')"
        [ -n "$described" ] && RSU_VERSION="$described"
    fi

    local kver=""
    if [ -f "$dir/kernel/Makefile" ]; then
        kver="$(grep -E '^KSU_VERSION\s*[:?]?=' "$dir/kernel/Makefile" 2>/dev/null \
            | head -n1 | sed 's/.*=\s*//' || true)"
    fi
    if [ -z "$kver" ]; then
        local vfile
        vfile="$(find "$dir" -maxdepth 4 -type f -name 'version.h' 2>/dev/null | head -n1 || true)"
        if [ -n "$vfile" ]; then
            kver="$(grep -E '#define\s+(KSU|RESUKISU|SUKISU)_VERSION' "$vfile" 2>/dev/null \
                | awk '{print $3}' || true)"
        fi
    fi
    [ -n "$kver" ] && RSU_VERSION="$kver"

    return 0
}

# -----------------------------------------------------------------------------
#  ReSukiSU auto-update
# -----------------------------------------------------------------------------
RSU_UPDATED="no"

update_resukisu() {
    local dir="$CURRENT_DIR/ReSukiSU"

    RSU_UPDATED="no"

    [ -d "$dir/.git" ] || return 0
    [ -n "$NO_UPDATE" ] && return 0

    if ! git -C "$dir" diff --quiet 2>/dev/null || \
       ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
        return 2
    fi

    local old_rev new_rev
    old_rev="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo '')"

    git -C "$dir" fetch --depth=1 origin HEAD >/dev/null 2>&1 || \
        git -C "$dir" fetch origin >/dev/null 2>&1 || return 1

    local upstream
    upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo '')"

    if [ -n "$upstream" ]; then
        new_rev="$(git -C "$dir" rev-parse "$upstream" 2>/dev/null || echo '')"
    else
        new_rev="$(git -C "$dir" rev-parse FETCH_HEAD 2>/dev/null || echo '')"
    fi

    [ -z "$new_rev" ] && return 1
    [ "$old_rev" = "$new_rev" ] && return 3

    git -C "$dir" reset --hard "$new_rev" >/dev/null 2>&1 || return 1
    RSU_UPDATED="yes"
    return 0
}

print_rsu_panel() {
    echo
    printf "${C_MAGENTA}${C_BOLD}  ReSukiSU Info${C_RESET}\n"
    printf "${C_DIM}  Version       ${C_RESET} ${C_WHITE}%s${C_RESET}\n" "$RSU_VERSION"
    printf "${C_DIM}  Commit        ${C_RESET} ${C_WHITE}%s${C_RESET}\n" "$RSU_COMMIT"
    printf "${C_DIM}  Branch        ${C_RESET} ${C_WHITE}%s${C_RESET}\n" "$RSU_BRANCH"
    printf "${C_DIM}  Commit Date   ${C_RESET} ${C_WHITE}%s${C_RESET}\n" "$RSU_DATE"
    if [ "$RSU_DIRTY" = "dirty" ]; then
        printf "${C_DIM}  Working Tree  ${C_RESET} ${C_YELLOW}dirty (local changes)${C_RESET}\n"
    else
        printf "${C_DIM}  Working Tree  ${C_RESET} ${C_GREEN}clean${C_RESET}\n"
    fi
    if [ "$RSU_UPDATED" = "yes" ]; then
        printf "${C_DIM}  Updated       ${C_RESET} ${C_GREEN}yes${C_RESET}\n"
    fi
    echo
}

# -----------------------------------------------------------------------------
#  Config
# -----------------------------------------------------------------------------
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$CURRENT_DIR"

CLEAN_BUILD="${CLEAN_BUILD:-false}"
ZIP_ANY_KERNEL="${ZIP_ANY_KERNEL:-true}"

SECONDS=0
DATE="$(date '+%Y%m%d-%H%M')"
DEVICE="${DEVICE:-everpal}"
DEFCONFIG="${DEVICE}_defconfig"
ZIPNAME="ReSukiSU-AdrenalinKernel-${DATE}.zip"

cleanup() {
    roll_stop 2>/dev/null || true
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
#  Main
# -----------------------------------------------------------------------------
banner

# =============================================================================
log_section "1 / 6  ·  清理旧构建产物"
# =============================================================================
spin_start "Removing stale artifacts..."

rm -rf out/arch/arm64/boot
rm -rf .config .config.old .tmp_versions
rm -rf include/generated include/config
rm -rf arch/arm64/include/generated
rm -rf vmlinux* System.map modules.builtin*
rm -f Module.symvers modules.order
rm -rf scripts/kconfig/.tmp*
rm -rf out/include/generated out/include/config
rm -rf out/arch/arm64/kernel/vdso
rm -f out/include/generated/vdso-offsets.h

if [ "$CLEAN_BUILD" = true ]; then
    rm -rf out
fi

spin_stop ok "Cleanup complete"

# =============================================================================
log_section "2 / 6  ·  工具链准备"
# =============================================================================
TC_DIR="${TC_DIR:-$HOME/toolchains/neutron-clang}"

spin_start "Detecting toolchain..."
if [ -x "$TC_DIR/bin/clang" ]; then
    export PATH="$TC_DIR/bin:$PATH"
    CLANG="$TC_DIR/bin/clang"
    TOOLCHAIN_SRC="neutron-clang"
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

if [ -z "$NO_CCACHE" ] && command -v ccache >/dev/null 2>&1; then
    CC="ccache $CC"
    CCACHE_STATE="enabled"
else
    if [ -z "$NO_CCACHE" ]; then
        CCACHE_STATE="not installed"
    else
        CCACHE_STATE="disabled"
    fi
fi
spin_stop ok "Toolchain: $TOOLCHAIN_SRC · ccache: $CCACHE_STATE"

# =============================================================================
log_section "3 / 6  ·  ReSukiSU 源码准备"
# =============================================================================
if [ ! -d "$CURRENT_DIR/ReSukiSU/kernel" ]; then
    spin_start "Cloning ReSukiSU..."
    CLONE_URL="$(gh_url 'https://github.com/ReSukiSU/ReSukiSU.git')"
    if GIT_SSL_NO_VERIFY=true git clone --depth=1 --branch main \
        "$CLONE_URL" "$CURRENT_DIR/ReSukiSU" >/dev/null 2>&1; then
        spin_stop ok "ReSukiSU cloned"
        RSU_UPDATED="yes"
    else
        spin_stop fail "Failed to clone ReSukiSU"
        exit 1
    fi
else
    log_ok "ReSukiSU source already present"

    if [ ! -d "$CURRENT_DIR/ReSukiSU/.git" ]; then
        spin_stop ok "Vendored ReSukiSU (no git metadata)"
    elif [ -n "$NO_UPDATE" ]; then
        spin_stop warn "Auto-update disabled (--no-update)"
    else
        spin_start "Checking ReSukiSU updates..."
        set +e
        update_resukisu
        rc=$?
        set -e
        case "$rc" in
            0) spin_stop ok "ReSukiSU updated to latest" ;;
            2) spin_stop warn "Local changes present · skipped update" ;;
            3) spin_stop ok "ReSukiSU already up to date" ;;
            *) spin_stop warn "Update failed · using local version" ;;
        esac
    fi
fi

if [ -n "$GH_PROXY" ]; then
    spin_start "Rewriting GitHub URLs in ReSukiSU scripts..."
    rewritten=$(rewrite_gh_links_in "$CURRENT_DIR/ReSukiSU")
    spin_stop ok "Rewrote $rewritten script(s)"
fi

spin_start "Reading ReSukiSU version info..."
get_resukisu_info
spin_stop ok "Version info collected"
print_rsu_panel

rm -f drivers/kernelsu
ln -sfn ../ReSukiSU/kernel drivers/kernelsu

grep -q 'kernelsu' drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || \
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig

log_ok "ReSukiSU integrated into kernel tree"

# =============================================================================
log_section "4 / 6  ·  内核配置"
# =============================================================================
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
    spin_stop ok "defconfig written"
else
    spin_stop fail "defconfig failed"
    exit 1
fi

# ---- 应用额外的配置片段 / 选项（在 defconfig 之后，olddefconfig 之前） ----
if [ "${#CONFIG_FILES[@]}" -gt 0 ] || [ "${#CONFIG_OPTS[@]}" -gt 0 ]; then
    spin_start "Applying extra kernel config ..."
    apply_config_files CONFIG_FILES
    apply_config_opts  CONFIG_OPTS
    spin_stop ok "Extra config applied"
fi

spin_start "Running olddefconfig ..."
if make "${MAKE_COMMON[@]}" olddefconfig >/dev/null 2>&1; then
    spin_stop ok "olddefconfig done"
else
    spin_stop fail "olddefconfig failed"
    exit 1
fi

# ---- menuconfig（可选） ----
if [ -n "$MENUCONFIG" ]; then
    echo
    log_info "Launching menuconfig (save and exit to continue)..."
    echo
    make "${MAKE_COMMON[@]}" menuconfig
fi

# ---- 保存最终配置（可选） ----
if [ -n "${SAVE_CONFIG:-}" ]; then
    cp out/.config "$CURRENT_DIR/kernel.config"
    log_ok "Saved final config to $CURRENT_DIR/kernel.config"
fi

show_config_diff

# ---- 检查关键项是否生效 ----
echo
log_info "Checking key configs..."
for key in CONFIG_KSU CONFIG_DOCKER CONFIG_SYSVIPC CONFIG_IPC_NS; do
    if grep -qE "^${key}=y" out/.config 2>/dev/null; then
        log_ok  "${key}=y"
    elif grep -qE "^# ${key} is not set" out/.config 2>/dev/null; then
        log_warn "${key} is not set"
    else
        log_warn "${key} not present"
    fi
done
echo

if [ -n "$CHECK_ONLY" ]; then
    spin_start "Running prepare sanity check..."
    if make -j"$(nproc --all)" "${MAKE_COMMON[@]}" prepare >/dev/null 2>&1; then
        spin_stop ok "Sanity check passed"
        exit 0
    else
        spin_stop fail "Sanity check failed"
        exit 1
    fi
fi

# =============================================================================
log_section "5 / 6  ·  VDSO 符号生成"
# =============================================================================
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

# =============================================================================
log_section "6 / 6  ·  编译内核"
# =============================================================================
echo
log_info "Starting compilation (single-line rolling log below)..."
echo

BUILD_LOG="$(mktemp /tmp/kernel-build-XXXXXX.log)"
START_TS=$(date +%s)

roll_start "$BUILD_LOG"

if make -j"$(nproc --all)" "${MAKE_COMMON[@]}" \
    KCFLAGS="-Wno-error=default-const-init-var-unsafe -Wno-default-const-init-var-unsafe" \
    Image.gz >"$BUILD_LOG" 2>&1; then

    roll_stop
    END_TS=$(date +%s)
    BUILD_TIME=$(( END_TS - START_TS ))

    echo
    hr
    log_ok "Kernel compiled successfully in ${BUILD_TIME}s"
    log_dim "Image.gz: $CURRENT_DIR/out/arch/arm64/boot/Image.gz"
    hr

    if [ "$ZIP_ANY_KERNEL" = true ]; then
        echo
        spin_start "Packaging AnyKernel3 zip ..."
        rm -rf AnyKernel3

        AK_URL="$(gh_url 'https://github.com/weaponmasterjax/AnyKernel3')"
        if GIT_SSL_NO_VERIFY=true git clone -q --depth=1 \
            "$AK_URL" AnyKernel3 >/dev/null 2>&1; then
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
    printf "${C_GREEN}${C_BOLD}  DONE${C_RESET}\n"
    printf "  ${C_DIM}Total time:${C_RESET} ${C_BOLD}%d minute(s) %d second(s)${C_RESET}\n" \
        $((SECONDS / 60)) $((SECONDS % 60))
    hr
    echo

    rm -f "$BUILD_LOG"
else
    roll_stop
    print_error_context "$BUILD_LOG"
    exit 1
fi
