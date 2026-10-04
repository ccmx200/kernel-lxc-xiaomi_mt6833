#!/bin/bash
# =============================================================================
#  🚀  ReSukiSU Kernel Builder
#  🎯  Target : kernel-lxc_xiaomi_mtk810_mt6833 (everpal / MT6833)
#  📖  Usage  : ./build.sh [-cn [URL]] [--no-ccache] [--no-update]
#                          [--no-menuconfig] [--save-config] [--check]
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
#  🎨  Colors
# -----------------------------------------------------------------------------
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'; C_WHITE='\033[1;37m'; C_ORANGE='\033[38;5;208m'
C_PINK='\033[38;5;213m'; C_LAVENDER='\033[38;5;183m'; C_SKY='\033[38;5;117m'
C_MINT='\033[38;5;121m'; C_GREY='\033[38;5;245m'
C_BG_RED='\033[48;5;160m'; C_BG_GREEN='\033[48;5;28m'
C_BG_BLUE='\033[48;5;24m'; C_BG_PURPLE='\033[48;5;90m'
C_BG_ORANGE='\033[48;5;208m'

# -----------------------------------------------------------------------------
#  🧠  CLI
# -----------------------------------------------------------------------------
GH_PROXY="https://git.yylx.win/"; NO_CCACHE=""; NO_UPDATE=""; CHECK_ONLY=""
SKIP_MENUCONFIG=""; SAVE_CONFIG=""

usage() {
    printf "${C_ORANGE}${C_BOLD}🚀 ReSukiSU Kernel Builder${C_RESET}\n\n"
    printf "${C_BOLD}Usage:${C_RESET} $0 [options]\n\n"
    printf "  ${C_CYAN}-cn [URL]${C_RESET}            GitHub acceleration\n"
    printf "  ${C_CYAN}--proxy URL${C_RESET}          Same as -cn URL\n"
    printf "  ${C_CYAN}--no-ccache${C_RESET}          Disable ccache\n"
    printf "  ${C_CYAN}-nu, --no-update${C_RESET}     Skip ReSukiSU auto-update\n"
    printf "  ${C_CYAN}--no-menuconfig${C_RESET}      Skip interactive menuconfig\n"
    printf "  ${C_CYAN}-s,  --save-config${C_RESET}   Save final .config to ./kernel.config\n"
    printf "  ${C_CYAN}--check, --test${C_RESET}      Only run sanity check (no compile)\n"
    printf "  ${C_CYAN}-h,  --help${C_RESET}          Show this help\n\n"
    printf "${C_BOLD}Environment:${C_RESET}\n"
    printf "  ${C_DIM}CLEAN_BUILD=true${C_RESET}      Full clean build\n"
    printf "  ${C_DIM}ZIP_ANY_KERNEL=false${C_RESET}  Skip AnyKernel3 packaging\n"
    printf "  ${C_DIM}DEVICE=everpal${C_RESET}        Target device codename\n"
    printf "  ${C_DIM}TC_DIR=/path/clang${C_RESET}    Custom toolchain directory\n"
    printf "  ${C_DIM}ERROR_CTX=200${C_RESET}         Error context lines\n"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -cn|--cn)
            if [ -n "${2:-}" ] && [[ "${2:-}" =~ ^https?:// ]]; then
                GH_PROXY="$2"; shift
            else
                GH_PROXY="https://git.yylx.win/"
            fi
            ;;
        --proxy)         [ -n "${2:-}" ] && { GH_PROXY="$2"; shift; } ;;
        --no-ccache)     NO_CCACHE=1 ;;
        -nu|--no-update) NO_UPDATE=1 ;;
        --no-menuconfig) SKIP_MENUCONFIG=1 ;;
        -s|--save-config) SAVE_CONFIG=1 ;;
        --check|--test)  CHECK_ONLY=1 ;;
        -h|--help)       usage; exit 0 ;;
        *) printf "${C_RED}❌ Unknown option:${C_RESET} %s\n\n" "$1" >&2; usage; exit 1 ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
#  🌐  GitHub URL
# -----------------------------------------------------------------------------
gh_url() {
    [ -z "$GH_PROXY" ] && { printf '%s' "$1"; return; }
    printf '%s' "$1" | sed \
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
#  🎡  Spinner
# -----------------------------------------------------------------------------
SPINNER_PID=""

spin_start() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while :; do
            printf "\r${C_CYAN}  ${frames[$i]}${C_RESET}  ${C_DIM}%s${C_RESET}\033[K" "$msg"
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
        ok)   printf "${C_GREEN}  ✅${C_RESET}  %s\n" "$msg" ;;
        fail) printf "${C_RED}  ❌${C_RESET}  %s\n" "$msg" ;;
        warn) printf "${C_YELLOW}  ⚠️${C_RESET}   %s\n" "$msg" ;;
        *)    printf "  %s\n" "$msg" ;;
    esac
}

# -----------------------------------------------------------------------------
#  📜  Rolling build log (single line, updates in place)
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
                    printf "\r\033[K${C_SKY}  🔨${C_RESET} ${C_DIM}%s${C_RESET}" "$last_line"
                fi
            fi
            sleep 0.15
        done
        printf "\r\033[K"
    ) &
    ROLL_PID=$!
    disown "$ROLL_PID" 2>/dev/null || true
}

roll_stop() {
    if [ -n "$ROLL_PID" ]; then
        : > "$ROLL_STOP_FILE"
        sleep 0.2
        kill "$ROLL_PID" 2>/dev/null || true
        wait "$ROLL_PID" 2>/dev/null || true
        ROLL_PID=""
    fi
    [ -n "$ROLL_STOP_FILE" ] && rm -f "$ROLL_STOP_FILE"
    ROLL_STOP_FILE=""
    printf "\r\033[K"
}

# -----------------------------------------------------------------------------
#  📝  Logging
# -----------------------------------------------------------------------------
log_info()  { printf "${C_SKY}  💡${C_RESET}  %s\n" "$1"; }
log_ok()    { printf "${C_GREEN}  ✅${C_RESET}  %s\n" "$1"; }
log_warn()  { printf "${C_YELLOW}  ⚠️${C_RESET}   %s\n" "$1"; }
log_error() { printf "${C_RED}  ❌${C_RESET}  %s\n" "$1" >&2; }
log_dim()   { printf "${C_DIM}     %s${C_RESET}\n" "$1"; }

hr() {
    printf "${C_GREY}"
    printf '─%.0s' $(seq 1 72)
    printf "${C_RESET}\n"
}

log_section() {
    local num="$1" icon="$2" title="$3"
    echo
    printf "${C_BG_PURPLE}${C_WHITE}${C_BOLD}  %s  %s  ·  %s  ${C_RESET}\n" "$num" "$icon" "$title"
    echo
}

# -----------------------------------------------------------------------------
#  🚨  Error context
# -----------------------------------------------------------------------------
ERROR_CTX="${ERROR_CTX:-200}"

print_error_context() {
    local log_file="$1"
    local ctx="$ERROR_CTX"
    [ -f "$log_file" ] || return 0

    local first_err
    first_err="$(grep -n -m1 -E '([[:space:]]error:|^error:|Error [0-9]+|ERROR:|fatal error:)' "$log_file" 2>/dev/null | cut -d: -f1 || true)"

    if [ -z "$first_err" ]; then
        printf "\n${C_BG_RED}${C_WHITE}${C_BOLD}  ❌ Build failed  ·  no 'error:' marker found  ${C_RESET}\n\n"
        tail -n 40 "$log_file" | sed 's/^/    /'
        return 0
    fi

    local total start end
    total=$(wc -l < "$log_file")
    start=$(( first_err - ctx ))
    end=$(( first_err + ctx ))
    [ "$start" -lt 1 ] && start=1
    [ "$end" -gt "$total" ] && end="$total"

    printf "\n${C_BG_RED}${C_WHITE}${C_BOLD}  ❌ Build failed  ·  first error at line %d / %d  ·  context ±%d lines  ${C_RESET}\n" \
        "$first_err" "$total" "$ctx"
    printf "\n${C_DIM}  ── lines %d..%d ──────────────────────────────${C_RESET}\n\n" "$start" "$end"

    awk -v s="$start" -v e="$end" -v fe="$first_err" '
        NR >= s && NR <= e {
            if (NR == fe) printf "\033[1;31m  ▶ %s\033[0m\n", $0
            else          printf "    %s\n", $0
        }
    ' "$log_file"

    printf "\n${C_DIM}  ──────────────────────────────────────────────${C_RESET}\n"
    printf "  ${C_DIM}Full log:${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$log_file"
}

# -----------------------------------------------------------------------------
#  🎨  Config diff (single-column, full width)
# -----------------------------------------------------------------------------
CFG_BEFORE=""; CFG_AFTER=""

norm_config() {
    grep -E '^(CONFIG_[A-Z0-9_]+=.*|# CONFIG_[A-Z0-9_]+ is not set)' "$1" 2>/dev/null \
        | sed -E 's/^# (CONFIG_[A-Z0-9_]+) is not set$/\1=n/' | sort -u
}

print_config_block() {
    local title="$1" file="$2" fg="$3" bg="$4" count="$5"
    [ ! -s "$file" ] && return 0

    local term_w
    term_w=$(tput cols 2>/dev/null || echo 100)
    [ "$term_w" -lt 40 ] && term_w=100
    local lw=$((term_w - 6))
    [ "$lw" -gt 120 ] && lw=120

    echo
    printf "  ${bg}${C_WHITE}${C_BOLD}  %s  ·  %d items  ${C_RESET}\n" "$title" "$count"
    printf "  ${fg}"; printf '─%.0s' $(seq 1 "$lw"); printf "${C_RESET}\n"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        printf "  ${fg}  %s${C_RESET}\n" "$line"
    done < "$file"
}

show_menuconfig_diff() {
    [ -f "$CFG_BEFORE" ] && [ -f "$CFG_AFTER" ] || return 0
    local b a
    b="$(mktemp)"; a="$(mktemp)"
    norm_config "$CFG_BEFORE" > "$b"
    norm_config "$CFG_AFTER"  > "$a"
    local added removed an=0 rn=0
    added="$(comm -13 "$b" "$a" || true)"
    removed="$(comm -23 "$b" "$a" || true)"
    [ -n "$added" ] && an=$(printf '%s\n' "$added" | grep -c . || true)
    [ -n "$removed" ] && rn=$(printf '%s\n' "$removed" | grep -c . || true)

    echo
    printf "${C_BG_BLUE}${C_WHITE}${C_BOLD}  🎨 Menuconfig Changes  ·  compared with defconfig state  ${C_RESET}\n"

    if [ "$an" -eq 0 ] && [ "$rn" -eq 0 ]; then
        echo
        log_info "没有检测到配置改动"
        rm -f "$b" "$a"
        return 0
    fi

    echo
    printf "  ${C_GREEN}${C_BOLD}➕ Added${C_RESET}   ${C_GREEN}%d${C_RESET}    " "$an"
    printf "${C_RED}${C_BOLD}➖ Removed${C_RESET} ${C_RED}%d${C_RESET}\n" "$rn"

    local lf rf
    lf="$(mktemp)"; rf="$(mktemp)"
    [ -n "$added" ]   && printf '%s\n' "$added"   > "$lf"
    [ -n "$removed" ] && printf '%s\n' "$removed" > "$rf"

    print_config_block "➕ 新增 (Added)"   "$lf" "$C_GREEN" "$C_BG_GREEN" "$an"
    print_config_block "➖ 移除 (Removed)" "$rf" "$C_RED"   "$C_BG_RED"   "$rn"

    rm -f "$b" "$a" "$lf" "$rf"
    echo
}

check_key_configs() {
    echo
    printf "${C_PINK}${C_BOLD}  🔍 Key Configs${C_RESET}\n"
    for key in CONFIG_KSU CONFIG_DOCKER CONFIG_SYSVIPC CONFIG_IPC_NS CONFIG_KVM; do
        if grep -qE "^${key}=y" out/.config 2>/dev/null; then
            printf "  ${C_GREEN}✅${C_RESET}  ${C_WHITE}%-40s${C_RESET} ${C_GREEN}=y${C_RESET}\n" "$key"
        elif grep -qE "^# ${key} is not set" out/.config 2>/dev/null; then
            printf "  ${C_YELLOW}➖${C_RESET}  ${C_WHITE}%-40s${C_RESET} ${C_DIM}not set${C_RESET}\n" "$key"
        else
            printf "  ${C_RED}❓${C_RESET}  ${C_WHITE}%-40s${C_RESET} ${C_DIM}missing${C_RESET}\n" "$key"
        fi
    done
    echo
}

# -----------------------------------------------------------------------------
#  📦  ReSukiSU info
# -----------------------------------------------------------------------------
RSU_VERSION="unknown"; RSU_COMMIT="unknown"
RSU_BRANCH="unknown";  RSU_DATE="unknown"
RSU_DIRTY="clean";     RSU_UPDATED="no"

get_resukisu_info() {
    local dir="$CURRENT_DIR/ReSukiSU"
    RSU_VERSION="unknown"; RSU_COMMIT="unknown"
    RSU_BRANCH="unknown";  RSU_DATE="unknown"
    RSU_DIRTY="clean"

    if [ ! -d "$dir/.git" ] && [ -d "$dir/kernel" ]; then
        RSU_VERSION="vendored"; RSU_COMMIT="vendored"; RSU_BRANCH="main"
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
        local d
        d="$(git -C "$dir" describe --tags --always 2>/dev/null || echo '')"
        [ -n "$d" ] && RSU_VERSION="$d"
    fi
    return 0
}

update_resukisu() {
    local dir="$CURRENT_DIR/ReSukiSU"
    RSU_UPDATED="no"
    [ -d "$dir/.git" ] || return 0
    [ -n "$NO_UPDATE" ] && return 0
    if ! git -C "$dir" diff --quiet 2>/dev/null || \
       ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
        return 2
    fi
    local old new
    old="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo '')"
    git -C "$dir" fetch --depth=1 origin HEAD >/dev/null 2>&1 || \
        git -C "$dir" fetch origin >/dev/null 2>&1 || return 1
    local upstream
    upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo '')"
    if [ -n "$upstream" ]; then
        new="$(git -C "$dir" rev-parse "$upstream" 2>/dev/null || echo '')"
    else
        new="$(git -C "$dir" rev-parse FETCH_HEAD 2>/dev/null || echo '')"
    fi
    [ -z "$new" ] && return 1
    [ "$old" = "$new" ] && return 3
    git -C "$dir" reset --hard "$new" >/dev/null 2>&1 || return 1
    RSU_UPDATED="yes"
    return 0
}

print_rsu_panel() {
    echo
    printf "${C_PINK}${C_BOLD}  📦 ReSukiSU Info${C_RESET}\n"
    printf "  ${C_GREY}├─${C_RESET} ${C_DIM}Version${C_RESET}       ${C_WHITE}%s${C_RESET}\n" "$RSU_VERSION"
    printf "  ${C_GREY}├─${C_RESET} ${C_DIM}Commit${C_RESET}        ${C_WHITE}%s${C_RESET}\n" "$RSU_COMMIT"
    printf "  ${C_GREY}├─${C_RESET} ${C_DIM}Branch${C_RESET}        ${C_WHITE}%s${C_RESET}\n" "$RSU_BRANCH"
    printf "  ${C_GREY}├─${C_RESET} ${C_DIM}Date${C_RESET}          ${C_WHITE}%s${C_RESET}\n" "$RSU_DATE"
    if [ "$RSU_DIRTY" = "dirty" ]; then
        printf "  ${C_GREY}├─${C_RESET} ${C_DIM}Tree${C_RESET}          ${C_YELLOW}🌿 dirty${C_RESET}\n"
    else
        printf "  ${C_GREY}├─${C_RESET} ${C_DIM}Tree${C_RESET}          ${C_GREEN}🌿 clean${C_RESET}\n"
    fi
    if [ "$RSU_UPDATED" = "yes" ]; then
        printf "  ${C_GREY}└─${C_RESET} ${C_DIM}Updated${C_RESET}       ${C_GREEN}✅ yes${C_RESET}\n"
    else
        printf "  ${C_GREY}└─${C_RESET}\n"
    fi
    echo
}

# =============================================================================
#  ⚙️  Config
# =============================================================================
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
    [ -n "$SPINNER_PID" ] && kill "$SPINNER_PID" 2>/dev/null || true
    for f in "${CFG_BEFORE:-}" "${CFG_AFTER:-}"; do
        [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
    done
}
trap cleanup EXIT

# =============================================================================
#  🎬  Main
# =============================================================================

# ---- Banner ----
echo
printf "${C_ORANGE}${C_BOLD}"
cat <<'EOF'
   ╭─────────────────────────────────────────────────────╮
   │  🚀  ReSukiSU Kernel Builder                        │
   │  🎯  everpal / MT6833  ·  Android Kernel 4.14      │
   ╰─────────────────────────────────────────────────────╯
EOF
printf "${C_RESET}\n"

printf "  ${C_LAVENDER}🌐 GitHub proxy${C_RESET}   "
if [ -n "$GH_PROXY" ]; then
    printf "${C_BOLD}%s${C_RESET}\n" "$GH_PROXY"
else
    printf "${C_DIM}disabled${C_RESET}\n"
fi

printf "  ${C_LAVENDER}🔄 Auto-update${C_RESET}    "
if [ -n "$NO_UPDATE" ]; then
    printf "${C_DIM}disabled${C_RESET}\n"
else
    printf "${C_GREEN}enabled${C_RESET}\n"
fi

printf "  ${C_LAVENDER}⚙️  Menuconfig${C_RESET}     "
if [ -n "$SKIP_MENUCONFIG" ]; then
    printf "${C_DIM}skipped${C_RESET}\n"
else
    printf "${C_GREEN}interactive${C_RESET}\n"
fi

[ -n "$SAVE_CONFIG" ] && \
    printf "  ${C_LAVENDER}💾 Save config${C_RESET}    ${C_GREEN}yes${C_RESET}\n"

[ -n "$CHECK_ONLY" ] && \
    printf "  ${C_LAVENDER}🔍 Check only${C_RESET}     ${C_YELLOW}yes${C_RESET}\n"

echo

# =============================================================================
log_section "1 / 6" "🧹" "清理旧构建产物"
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
[ "$CLEAN_BUILD" = true ] && rm -rf out

spin_stop ok "Cleanup complete"

# =============================================================================
log_section "2 / 6" "🔧" "工具链准备"
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

[ -z "${CLANG:-}" ] && { spin_stop fail "clang not found"; exit 1; }

export CC="${CC:-$CLANG}"
export LD="${LD:-ld.lld}"

if [ -z "$NO_CCACHE" ] && command -v ccache >/dev/null 2>&1; then
    CC="ccache $CC"; CCACHE_STATE="enabled ⚡"
else
    [ -z "$NO_CCACHE" ] && CCACHE_STATE="not installed" || CCACHE_STATE="disabled"
fi
spin_stop ok "Toolchain: $TOOLCHAIN_SRC · ccache: $CCACHE_STATE"

# =============================================================================
log_section "3 / 6" "📦" "ReSukiSU 源码准备"
# =============================================================================
if [ ! -d "$CURRENT_DIR/ReSukiSU/kernel" ]; then
    spin_start "Cloning ReSukiSU..."
    CLONE_URL="$(gh_url 'https://github.com/ReSukiSU/ReSukiSU.git')"
    if GIT_SSL_NO_VERIFY=true git clone --depth=1 --branch main \
        "$CLONE_URL" "$CURRENT_DIR/ReSukiSU" >/dev/null 2>&1; then
        spin_stop ok "ReSukiSU cloned"; RSU_UPDATED="yes"
    else
        spin_stop fail "Failed to clone ReSukiSU"; exit 1
    fi
else
    log_ok "ReSukiSU source already present"
    if [ ! -d "$CURRENT_DIR/ReSukiSU/.git" ]; then
        log_ok "Vendored ReSukiSU (no git metadata)"
    elif [ -n "$NO_UPDATE" ]; then
        log_warn "Auto-update disabled (--no-update)"
    else
        spin_start "Checking ReSukiSU updates..."
        set +e; update_resukisu; rc=$?; set -e
        case "$rc" in
            0) spin_stop ok "ReSukiSU updated to latest" ;;
            2) spin_stop warn "Local changes present · skipped" ;;
            3) spin_stop ok "Already up to date" ;;
            *) spin_stop warn "Update failed · using local" ;;
        esac
    fi
fi

if [ -n "$GH_PROXY" ]; then
    spin_start "Rewriting GitHub URLs..."
    rewritten=$(rewrite_gh_links_in "$CURRENT_DIR/ReSukiSU")
    spin_stop ok "Rewrote $rewritten script(s)"
fi

spin_start "Reading version info..."
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
log_section "4 / 6" "⚙️" "内核配置"
# =============================================================================
printf "  ${C_DIM}Using compiler:${C_RESET}\n"
"$CLANG" --version | head -n 2 | sed 's/^/    /'
echo

MAKE_COMMON=(
    O=out ARCH=arm64 CC="$CC" LD="$LD"
    LLVM=1 LLVM_IAS=1 NM=llvm-nm
    CROSS_COMPILE=aarch64-linux-gnu-
)
command -v arm-linux-gnueabi-gcc >/dev/null 2>&1 && \
    MAKE_COMMON+=(CROSS_COMPILE_ARM32=arm-linux-gnueabi-)

spin_start "Configuring $DEFCONFIG ..."
if make "${MAKE_COMMON[@]}" "$DEFCONFIG" >/dev/null 2>&1; then
    spin_stop ok "defconfig written"
else
    spin_stop fail "defconfig failed"; exit 1
fi

spin_start "Running olddefconfig ..."
if make "${MAKE_COMMON[@]}" olddefconfig >/dev/null 2>&1; then
    spin_stop ok "olddefconfig done"
else
    spin_stop fail "olddefconfig failed"; exit 1
fi

# ---- menuconfig ----
if [ -z "$SKIP_MENUCONFIG" ]; then
    CFG_BEFORE="$(mktemp /tmp/kcfg-before-XXXXXX)"
    cp out/.config "$CFG_BEFORE"

    echo
    printf "${C_BG_BLUE}${C_WHITE}${C_BOLD}  🎛️  menuconfig  ·  Interactive Kernel Configuration  ${C_RESET}\n"
    echo
    printf "  ${C_SKY}💡 操作指南${C_RESET}\n"
    printf "     ${C_WHITE}↑ ↓${C_RESET}       ${C_DIM}移动光标${C_RESET}\n"
    printf "     ${C_WHITE}空格${C_RESET}      ${C_DIM}切换 y / n / m${C_RESET}\n"
    printf "     ${C_WHITE}/${C_RESET}         ${C_DIM}搜索配置（例如 DOCKER、SYSVIPC）${C_RESET}\n"
    printf "     ${C_WHITE}Enter${C_RESET}     ${C_DIM}进入子菜单${C_RESET}\n"
    printf "     ${C_WHITE}ESC ESC${C_RESET}   ${C_DIM}返回上级${C_RESET}\n"
    printf "     ${C_WHITE}Save${C_RESET}      ${C_DIM}保存（务必保存！）${C_RESET}\n"
    printf "     ${C_WHITE}Exit${C_RESET}      ${C_DIM}退出${C_RESET}\n"
    echo
    printf "  ${C_YELLOW}⚠️  离开前记得 <Save>，否则改动会丢失${C_RESET}\n"
    echo

    set +e
    (
        unset CC; unset LD
        export CURSES_LOC='ncurses.h'
        make O=out ARCH=arm64 HOSTCC=gcc HOSTLD=ld HOSTCXX=g++ menuconfig
    )
    menu_rc=$?
    set -e

    [ "$menu_rc" -ne 0 ] && log_warn "menuconfig 退出码 $menu_rc (usually normal)"

    if [ ! -f out/.config ]; then
        log_error "menuconfig 后 out/.config 消失了"; exit 1
    fi

    CFG_AFTER="$(mktemp /tmp/kcfg-after-XXXXXX)"
    cp out/.config "$CFG_AFTER"

    show_menuconfig_diff

    rm -f "$CFG_BEFORE" "$CFG_AFTER"
    CFG_BEFORE=""; CFG_AFTER=""
else
    log_info "Skipping menuconfig (--no-menuconfig)"
fi

if [ -n "$SAVE_CONFIG" ]; then
    cp out/.config "$CURRENT_DIR/kernel.config"
    log_ok "Saved final config to $CURRENT_DIR/kernel.config"
fi

check_key_configs

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
log_section "5 / 6" "📐" "VDSO 符号生成"
# =============================================================================
spin_start "Building vdso-offsets.h ..."
if make "${MAKE_COMMON[@]}" arch/arm64/kernel/vdso/ >/dev/null 2>&1; then
    if [ -f out/include/generated/vdso-offsets.h ]; then
        spin_stop ok "vdso-offsets.h generated"
    else
        spin_stop fail "vdso-offsets.h not found"; exit 1
    fi
else
    spin_stop fail "vdso build failed"; exit 1
fi

# =============================================================================
log_section "6 / 6" "🔨" "编译内核"
# =============================================================================
echo
log_info "Starting compilation (rolling log below)..."
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
    log_dim "📦 Image.gz: $CURRENT_DIR/out/arch/arm64/boot/Image.gz"
    hr

    if [ "$ZIP_ANY_KERNEL" = true ]; then
        echo
        spin_start "Packaging AnyKernel3 zip..."
        rm -rf AnyKernel3

        AK_URL="$(gh_url 'https://github.com/ccmx200/AnyKernel3')"
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
    printf "${C_GREEN}${C_BOLD}"
    cat <<'EOF'
     ✨ ═══════════════════════════════════════ ✨
              🎉  B U I L D   D O N E  🎉
     ✨ ═══════════════════════════════════════ ✨
EOF
    printf "${C_RESET}\n"
    printf "  ${C_DIM}⏱  Total time:${C_RESET} ${C_BOLD}%d min %d sec${C_RESET}\n" \
        $((SECONDS / 60)) $((SECONDS % 60))
    hr
    echo

    rm -f "$BUILD_LOG"
else
    roll_stop
    print_error_context "$BUILD_LOG"
    exit 1
fi
