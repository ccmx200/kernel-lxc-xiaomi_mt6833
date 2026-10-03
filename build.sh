#!/bin/bash
# =============================================================================
#  🚀  ReSukiSU Kernel Builder  ·  Dual-Panel Edition
#  🎯  Target : kernel-lxc_xiaomi_mtk810_mt6833 (everpal / MT6833)
#  📖  Usage  : ./build.sh [-cn [URL]] [--no-ccache] [--no-update]
#                          [-m|--menuconfig] [--no-menuconfig]
#                          [--save-config] [--check]
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
#  🎨  Colors
# -----------------------------------------------------------------------------
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_RED='\033[1;31m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_MAGENTA='\033[1;35m'
readonly C_CYAN='\033[1;36m'
readonly C_WHITE='\033[1;37m'
readonly C_ORANGE='\033[38;5;208m'
readonly C_PINK='\033[38;5;213m'
readonly C_LAVENDER='\033[38;5;183m'
readonly C_MINT='\033[38;5;121m'
readonly C_SKY='\033[38;5;117m'
readonly C_GREY='\033[38;5;245m'
readonly C_BG_RED='\033[48;5;160m'
readonly C_BG_GREEN='\033[48;5;28m'
readonly C_BG_BLUE='\033[48;5;24m'
readonly C_BG_PURPLE='\033[48;5;90m'
readonly C_BG_TEAL='\033[48;5;30m'

# -----------------------------------------------------------------------------
#  🧠  CLI arguments
# -----------------------------------------------------------------------------
GH_PROXY=""
NO_CCACHE=""
NO_UPDATE=""
CHECK_ONLY=""
SKIP_MENUCONFIG=""
SAVE_CONFIG=""

usage() {
    printf "${C_ORANGE}${C_BOLD}🚀 ReSukiSU Kernel Builder${C_RESET}\n\n"
    printf "${C_BOLD}Usage:${C_RESET} $0 [options]\n\n"
    printf "  ${C_CYAN}-cn [URL]${C_RESET}            GitHub acceleration\n"
    printf "  ${C_CYAN}--no-ccache${C_RESET}          Disable ccache\n"
    printf "  ${C_CYAN}-nu, --no-update${C_RESET}     Skip ReSukiSU auto-update\n"
    printf "  ${C_CYAN}--no-menuconfig${C_RESET}      Skip menuconfig\n"
    printf "  ${C_CYAN}-s,  --save-config${C_RESET}   Save final .config\n"
    printf "  ${C_CYAN}--check${C_RESET}              Sanity check only\n"
    printf "  ${C_CYAN}-h,  --help${C_RESET}          Show help\n"
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
        -m|--menuconfig) SKIP_MENUCONFIG="" ;;
        --no-menuconfig) SKIP_MENUCONFIG=1 ;;
        -s|--save-config) SAVE_CONFIG=1 ;;
        --check|--test)  CHECK_ONLY=1 ;;
        -h|--help)       usage; exit 0 ;;
        *) printf "${C_RED}❌ Unknown:${C_RESET} %s\n" "$1" >&2; usage; exit 1 ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
#  🌐  GitHub URL rewriting
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

# =============================================================================
#  🖼️  全局双栏面板
# =============================================================================
PANEL_TOP=2              # 面板起始行（第 1 行留给标题栏）
PANEL_STEPS_COUNT=6      # 步骤数量
PANEL_LEFT_WIDTH=24      # 左栏宽度（含边框）
PANEL_HEIGHT=$((PANEL_STEPS_COUNT + 2))  # 面板总高度（标题栏 + 6 步 + 分隔线）
PANEL_LOG_FILE=""
PANEL_REFRESH_PID=""
PANEL_STOP_FILE=""
PANEL_ACTIVE=0           # 1 = 面板正在运行
PANEL_SUSPEND=0          # 1 = 临时挂起（menuconfig 期间）
PANEL_TERM_W=100

# 步骤定义
declare -a PANEL_STEPS=(
    "1/6  Cleanup"
    "2/6  Toolchain"
    "3/6  ReSukiSU"
    "4/6  Config"
    "5/6  VDSO"
    "6/6  Compile"
)
declare -a PANEL_MARKS=("WAIT" "WAIT" "WAIT" "WAIT" "WAIT" "WAIT")

# 光标控制
cursor_hide() { printf "\033[?25l"; }
cursor_show() { printf "\033[?25h"; }
cursor_save() { printf "\033[s"; }
cursor_restore() { printf "\033[u"; }
clear_line()  { printf "\033[K"; }
goto_row()    { printf "\033[%d;1H" "$1"; }

# 更新步骤状态
panel_set_mark() {
    local idx="$1"   # 0-5
    local state="$2" # WAIT / RUN / DONE / FAIL
    PANEL_MARKS[$idx]="$state"
}

# 内部：绘制一行面板
_panel_draw_row() {
    local screen_row="$1"   # 屏幕上的行号（PANEL_TOP 起的偏移）
    local step_text="$2"
    local state="$3"
    local log_text="$4"

    local mark_icon mark_color
    case "$state" in
        DONE) mark_icon="✅"; mark_color="$C_GREEN" ;;
        RUN)  mark_icon="🔄"; mark_color="$C_YELLOW" ;;
        FAIL) mark_icon="❌"; mark_color="$C_RED" ;;
        *)    mark_icon="⏸ "; mark_color="$C_DIM" ;;
    esac

    printf "\033[%d;1H" "$screen_row"
    printf "${C_GREY}│${C_RESET} ${C_WHITE}%-15s${C_RESET} ${mark_color}%s${C_RESET} ${C_GREY}│${C_RESET} " \
        "$step_text" "$mark_icon"

    local right_w=$((PANEL_TERM_W - PANEL_LEFT_WIDTH - 4))
    [ "$right_w" -lt 20 ] && right_w=20

    if [ -n "$log_text" ]; then
        [ "${#log_text}" -gt "$right_w" ] && log_text="${log_text:0:$((right_w-3))}..."
        printf "${C_DIM}%s${C_RESET}" "$log_text"
    fi
    clear_line
}

# 内部：绘制整个面板
_panel_draw() {
    [ "$PANEL_SUSPEND" = "1" ] && return 0

    PANEL_TERM_W=$(tput cols 2>/dev/null || echo 100)
    [ "$PANEL_TERM_W" -lt 60 ] && PANEL_TERM_W=100

    cursor_save

    # 读日志最后 N 行
    local -a tail_lines=()
    if [ -f "$PANEL_LOG_FILE" ]; then
        while IFS= read -r line; do
            tail_lines+=("$line")
        done < <(tail -n "$PANEL_STEPS_COUNT" "$PANEL_LOG_FILE" 2>/dev/null || true)
    fi

    # 标题栏
    printf "\033[1;1H"
    printf "${C_BG_PURPLE}${C_WHITE}${C_BOLD}  %-18s ${C_RESET} ${C_GREY}│${C_RESET} ${C_BG_BLUE}${C_WHITE}${C_BOLD}  Live Log  ${C_RESET}"
    clear_line

    # 6 行面板
    local i=0
    while [ "$i" -lt "$PANEL_STEPS_COUNT" ]; do
        local log_line="${tail_lines[$i]:-}"
        _panel_draw_row $((i + PANEL_TOP)) "${PANEL_STEPS[$i]}" "${PANEL_MARKS[$i]}" "$log_line"
        i=$((i + 1))
    done

    # 分隔线
    local sep_row=$((PANEL_TOP + PANEL_STEPS_COUNT))
    printf "\033[%d;1H" "$sep_row"
    printf "${C_GREY}"
    printf '─%.0s' $(seq 1 $((PANEL_LEFT_WIDTH - 2)))
    printf '┼'
    printf '─%.0s' $(seq 1 $((PANEL_TERM_W - PANEL_LEFT_WIDTH - 2)))
    printf "${C_RESET}"
    clear_line

    cursor_restore
}

# 面板启动
panel_start() {
    [ "$PANEL_ACTIVE" = "1" ] && return 0
    PANEL_ACTIVE=1
    PANEL_LOG_FILE="$(mktemp /tmp/panel-log-XXXXXX)"
    PANEL_STOP_FILE="$(mktemp /tmp/panel-stop-XXXXXX)"
    : > "$PANEL_STOP_FILE"

    # 清屏 + 光标移到面板下方
    clear 2>/dev/null || true
    cursor_hide

    # 先绘制一次空白面板（占据前 8 行）
    local i=1
    while [ "$i" -le $((PANEL_TOP + PANEL_STEPS_COUNT + 1)) ]; do
        printf "\033[%d;1H\033[K" "$i"
        i=$((i + 1))
    done

    # 光标移到面板下方
    printf "\033[%d;1H" $((PANEL_TOP + PANEL_STEPS_COUNT + 2))

    # 后台刷新线程
    (
        while [ ! -s "$PANEL_STOP_FILE" ]; do
            _panel_draw 2>/dev/null || true
            sleep 0.12
        done
    ) &
    PANEL_REFRESH_PID=$!
    disown "$PANEL_REFRESH_PID" 2>/dev/null || true
}

# 面板停止
panel_stop() {
    [ "$PANEL_ACTIVE" = "0" ] && return 0
    PANEL_ACTIVE=0

    if [ -n "$PANEL_REFRESH_PID" ]; then
        : > "$PANEL_STOP_FILE" 2>/dev/null || true
        sleep 0.2
        kill "$PANEL_REFRESH_PID" 2>/dev/null || true
        wait "$PANEL_REFRESH_PID" 2>/dev/null || true
        PANEL_REFRESH_PID=""
    fi

    [ -n "$PANEL_STOP_FILE" ] && rm -f "$PANEL_STOP_FILE"
    [ -n "$PANEL_LOG_FILE" ] && rm -f "$PANEL_LOG_FILE"
    PANEL_STOP_FILE=""
    PANEL_LOG_FILE=""

    cursor_show
    # 光标移到面板下方
    printf "\033[%d;1H" $((PANEL_TOP + PANEL_STEPS_COUNT + 2))
}

# 面板挂起（用于 menuconfig 等全屏交互）
panel_suspend() {
    PANEL_SUSPEND=1
    cursor_show
    # 光标移到最底
    printf "\033[%d;1H\n" "$((PANEL_TOP + PANEL_STEPS_COUNT + 3))"
}

# 面板恢复
panel_resume() {
    PANEL_SUSPEND=0
    cursor_hide
    printf "\033[%d;1H" $((PANEL_TOP + PANEL_STEPS_COUNT + 2))
    _panel_draw
}

# 面板下方普通输出（会正常向下滚）
panel_below() {
    printf "\033[%d;1H" $((PANEL_TOP + PANEL_STEPS_COUNT + 2))
    printf "%s\n" "$1"
}

# -----------------------------------------------------------------------------
#  📝  日志函数（写入面板日志 + 输出到普通区）
# -----------------------------------------------------------------------------
PANEL_LOG_MAX=200

panel_log() {
    local raw="$1"    # 纯文本（无 ANSI）
    [ -z "$PANEL_LOG_FILE" ] && return 0
    # 追加到日志文件，并保留最后 N 行
    printf '%s\n' "$raw" >> "$PANEL_LOG_FILE"
    # 截断文件
    local lines
    lines=$(wc -l < "$PANEL_LOG_FILE" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$PANEL_LOG_MAX" ]; then
        tail -n "$PANEL_LOG_MAX" "$PANEL_LOG_FILE" > "${PANEL_LOG_FILE}.tmp" 2>/dev/null && \
            mv "${PANEL_LOG_FILE}.tmp" "$PANEL_LOG_FILE"
    fi
}

# 高等级日志：写入面板 + 输出到普通区
log_info()  { panel_log "💡 $1"; printf "${C_SKY}  💡${C_RESET}  %s\n" "$1"; }
log_ok()    { panel_log "✅ $1"; printf "${C_GREEN}  ✅${C_RESET}  %s\n" "$1"; }
log_warn()  { panel_log "⚠️  $1"; printf "${C_YELLOW}  ⚠️${C_RESET}   %s\n" "$1"; }
log_error() { panel_log "❌ $1"; printf "${C_RED}  ❌${C_RESET}  %s\n" "$1" >&2; }
log_dim()   { panel_log "   $1"; printf "${C_DIM}     %s${C_RESET}\n" "$1"; }

hr() {
    printf "${C_DIM}"
    printf '─%.0s' $(seq 1 72)
    printf "${C_RESET}\n"
}

# spinner（简短操作）
SPINNER_PID=""
spin_start() {
    local msg="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while :; do
            printf "\033[%d;1H\033[K${C_CYAN}  ${frames[$i]}${C_RESET}  ${C_DIM}%s${C_RESET}" \
                $((PANEL_TOP + PANEL_STEPS_COUNT + 2)) "$msg"
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
    printf "\033[%d;1H\033[K" $((PANEL_TOP + PANEL_STEPS_COUNT + 2))
    case "$status" in
        ok)   log_ok "$msg" ;;
        fail) log_error "$msg" ;;
        warn) log_warn "$msg" ;;
        *)    log_info "$msg" ;;
    esac
}

# -----------------------------------------------------------------------------
#  🚨  错误提取
# -----------------------------------------------------------------------------
ERROR_CTX="${ERROR_CTX:-200}"

print_error_context() {
    local log_file="$1"
    local ctx="$ERROR_CTX"
    [ -f "$log_file" ] || return 0

    local first_err
    first_err="$(grep -n -m1 -E '([[:space:]]error:|^error:|Error [0-9]+|ERROR:|fatal error:)' "$log_file" 2>/dev/null | cut -d: -f1 || true)"

    panel_stop

    if [ -z "$first_err" ]; then
        printf "\n${C_BG_RED}${C_WHITE}${C_BOLD}  ❌ Build failed  ·  no 'error:' marker  ${C_RESET}\n\n"
        tail -n 40 "$log_file" | sed 's/^/    /'
        return 0
    fi

    local total
    total="$(wc -l < "$log_file")"
    local start=$(( first_err - ctx ))
    local end=$(( first_err + ctx ))
    [ "$start" -lt 1 ] && start=1
    [ "$end" -gt "$total" ] && end="$total"

    printf "\n${C_BG_RED}${C_WHITE}${C_BOLD}  ❌ Build failed  ·  line %d / %d  ·  context ±%d  ${C_RESET}\n" \
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
#  📦  ReSukiSU version info
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
        RSU_VERSION="vendored"; RSU_COMMIT="vendored"
        RSU_BRANCH="main"
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
    [ -n "$kver" ] && RSU_VERSION="$kver"
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

# -----------------------------------------------------------------------------
#  🔧  Config diff
# -----------------------------------------------------------------------------
CFG_BEFORE=""; CFG_AFTER=""

norm_config() {
    grep -E '^(CONFIG_[A-Z0-9_]+=.*|# CONFIG_[A-Z0-9_]+ is not set)' "$1" 2>/dev/null \
        | sed -E 's/^# (CONFIG_[A-Z0-9_]+) is not set$/\1=n/' | sort -u
}

print_config_block() {
    local title="$1" file="$2" fg="$3" bg="$4" count="$5"
    [ ! -s "$file" ] && return 0
    local term_width
    term_width=$(tput cols 2>/dev/null || echo 100)
    [ "$term_width" -lt 40 ] && term_width=100
    local lw=$((term_width - 6))
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
    local b_norm a_norm
    b_norm="$(mktemp)"; a_norm="$(mktemp)"
    norm_config "$CFG_BEFORE" > "$b_norm"
    norm_config "$CFG_AFTER"  > "$a_norm"
    local added removed
    added="$(comm -13 "$b_norm" "$a_norm" || true)"
    removed="$(comm -23 "$b_norm" "$a_norm" || true)"
    local added_n=0 removed_n=0
    [ -n "$added" ]   && added_n=$(printf '%s\n' "$added"   | grep -c . || true)
    [ -n "$removed" ] && removed_n=$(printf '%s\n' "$removed" | grep -c . || true)

    echo
    printf "${C_BG_BLUE}${C_WHITE}${C_BOLD}  🎨 Menuconfig Changes  ·  compared with defconfig  ${C_RESET}\n"
    if [ "$added_n" -eq 0 ] && [ "$removed_n" -eq 0 ]; then
        echo; log_info "没有检测到配置改动"
        rm -f "$b_norm" "$a_norm"; return 0
    fi
    echo
    printf "  ${C_GREEN}${C_BOLD}➕ Added${C_RESET}   ${C_GREEN}%d${C_RESET}    " "$added_n"
    printf "${C_RED}${C_BOLD}➖ Removed${C_RESET} ${C_RED}%d${C_RESET}\n" "$removed_n"
    local lf rf
    lf="$(mktemp)"; rf="$(mktemp)"
    [ -n "$added" ]   && printf '%s\n' "$added"   > "$lf"
    [ -n "$removed" ] && printf '%s\n' "$removed" > "$rf"
    print_config_block "➕ 新增 (Added)"   "$lf" "$C_GREEN" "$C_BG_GREEN" "$added_n"
    print_config_block "➖ 移除 (Removed)" "$rf" "$C_RED"   "$C_BG_RED"   "$removed_n"
    rm -f "$b_norm" "$a_norm" "$lf" "$rf"
    echo
}

check_key_configs() {
    echo
    printf "${C_PINK}${C_BOLD}  🔍 Key Configs${C_RESET}\n"
    for key in CONFIG_KSU CONFIG_DOCKER CONFIG_SYSVIPC CONFIG_IPC_NS CONFIG_KVM; do
        if grep -qE "^${key}=y" out/.config 2>/dev/null; then
            printf "  ${C_GREEN}✅${C_RESET}  %-40s ${C_GREEN}=y${C_RESET}\n" "$key"
        elif grep -qE "^# ${key} is not set" out/.config 2>/dev/null; then
            printf "  ${C_YELLOW}➖${C_RESET}  %-40s ${C_DIM}not set${C_RESET}\n" "$key"
        else
            printf "  ${C_RED}❓${C_RESET}  %-40s ${C_DIM}missing${C_RESET}\n" "$key"
        fi
    done
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
    panel_stop 2>/dev/null || true
    [ -n "$SPINNER_PID" ] && kill "$SPINNER_PID" 2>/dev/null || true
    for f in "${CFG_BEFORE:-}" "${CFG_AFTER:-}"; do
        [ -n "$f" ] && [ -f "$f" ] && rm -f "$f"
    done
    cursor_show 2>/dev/null || true
}
trap cleanup EXIT

# =============================================================================
#  🎬  Main
# =============================================================================

# 启动面板
panel_start

# -----------------------------------------------------------------------------
#  1/6 清理
# -----------------------------------------------------------------------------
panel_set_mark 0 RUN
panel_log "🧹 Removing stale artifacts..."
spin_start "Removing stale artifacts..."

rm -rf out/arch/arm64/boot .config .config.old .tmp_versions
rm -rf include/generated include/config arch/arm64/include/generated
rm -rf vmlinux* System.map modules.builtin*
rm -f Module.symvers modules.order
rm -rf scripts/kconfig/.tmp*
rm -rf out/include/generated out/include/config
rm -rf out/arch/arm64/kernel/vdso
rm -f out/include/generated/vdso-offsets.h
[ "$CLEAN_BUILD" = true ] && rm -rf out

spin_stop ok "Cleanup complete"
panel_set_mark 0 DONE

# -----------------------------------------------------------------------------
#  2/6 工具链
# -----------------------------------------------------------------------------
panel_set_mark 1 RUN
TC_DIR="${TC_DIR:-$HOME/toolchains/neutron-clang}"
spin_start "Detecting toolchain..."
if [ -x "$TC_DIR/bin/clang" ]; then
    export PATH="$TC_DIR/bin:$PATH"
    CLANG="$TC_DIR/bin/clang"; TOOLCHAIN_SRC="neutron-clang"
else
    CLANG="$(command -v clang || true)"; TOOLCHAIN_SRC="system clang"
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
panel_set_mark 1 DONE

# -----------------------------------------------------------------------------
#  3/6 ReSukiSU
# -----------------------------------------------------------------------------
panel_set_mark 2 RUN
if [ ! -d "$CURRENT_DIR/ReSukiSU/kernel" ]; then
    spin_start "Cloning ReSukiSU..."
    CLONE_URL="$(gh_url 'https://github.com/ReSukiSU/ReSukiSU.git')"
    if GIT_SSL_NO_VERIFY=true git clone --depth=1 --branch main \
        "$CLONE_URL" "$CURRENT_DIR/ReSukiSU" >/dev/null 2>&1; then
        spin_stop ok "ReSukiSU cloned"; RSU_UPDATED="yes"
    else
        spin_stop fail "Failed to clone ReSukiSU"; panel_set_mark 2 FAIL; exit 1
    fi
else
    log_ok "ReSukiSU source already present"
    if [ ! -d "$CURRENT_DIR/ReSukiSU/.git" ]; then
        log_ok "Vendored ReSukiSU (no git metadata)"
    elif [ -n "$NO_UPDATE" ]; then
        log_warn "Auto-update disabled"
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
spin_stop ok "Version: $RSU_VERSION ($RSU_COMMIT)"

rm -f drivers/kernelsu
ln -sfn ../ReSukiSU/kernel drivers/kernelsu
grep -q 'kernelsu' drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || \
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
log_ok "ReSukiSU integrated"
panel_set_mark 2 DONE

# -----------------------------------------------------------------------------
#  4/6 内核配置
# -----------------------------------------------------------------------------
panel_set_mark 3 RUN
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
    spin_stop fail "defconfig failed"; panel_set_mark 3 FAIL; exit 1
fi

spin_start "Running olddefconfig ..."
if make "${MAKE_COMMON[@]}" olddefconfig >/dev/null 2>&1; then
    spin_stop ok "olddefconfig done"
else
    spin_stop fail "olddefconfig failed"; panel_set_mark 3 FAIL; exit 1
fi

# menuconfig（暂停面板）
if [ -z "$SKIP_MENUCONFIG" ]; then
    CFG_BEFORE="$(mktemp /tmp/kcfg-before-XXXXXX)"
    cp out/.config "$CFG_BEFORE"

    panel_suspend
    printf "\n${C_BG_TEAL}${C_WHITE}${C_BOLD}  🎛️  menuconfig  ·  Interactive Kernel Configuration  ${C_RESET}\n\n"
    printf "  ${C_SKY}💡 操作指南${C_RESET}\n"
    printf "     ${C_WHITE}↑ ↓${C_RESET}       ${C_DIM}移动光标${C_RESET}\n"
    printf "     ${C_WHITE}空格${C_RESET}      ${C_DIM}切换 y / n / m${C_RESET}\n"
    printf "     ${C_WHITE}/${C_RESET}         ${C_DIM}搜索配置${C_RESET}\n"
    printf "     ${C_WHITE}Enter${C_RESET}     ${C_DIM}进入子菜单${C_RESET}\n"
    printf "     ${C_WHITE}ESC ESC${C_RESET}   ${C_DIM}返回上级${C_RESET}\n"
    printf "     ${C_WHITE}Save${C_RESET}      ${C_DIM}保存（务必保存！）${C_RESET}\n"
    printf "     ${C_WHITE}Exit${C_RESET}      ${C_DIM}退出${C_RESET}\n\n"
    printf "  ${C_YELLOW}⚠️  离开前记得 <Save>${C_RESET}\n\n"

    set +e
    (
        unset CC; unset LD
        export CURSES_LOC='ncurses.h'
        make O=out ARCH=arm64 HOSTCC=gcc HOSTLD=ld HOSTCXX=g++ menuconfig
    )
    menu_rc=$?
    set -e

    [ "$menu_rc" -ne 0 ] && log_warn "menuconfig 退出码 $menu_rc"

    if [ ! -f out/.config ]; then
        log_error "out/.config 消失了"; panel_set_mark 3 FAIL; exit 1
    fi

    CFG_AFTER="$(mktemp /tmp/kcfg-after-XXXXXX)"
    cp out/.config "$CFG_AFTER"

    panel_resume
    show_menuconfig_diff

    rm -f "$CFG_BEFORE" "$CFG_AFTER"
    CFG_BEFORE=""; CFG_AFTER=""
else
    log_info "Skipping menuconfig (--no-menuconfig)"
fi

if [ -n "$SAVE_CONFIG" ]; then
    cp out/.config "$CURRENT_DIR/kernel.config"
    log_ok "Saved final config"
fi

check_key_configs
panel_set_mark 3 DONE

if [ -n "$CHECK_ONLY" ]; then
    panel_set_mark 4 DONE
    panel_set_mark 5 DONE
    spin_start "Sanity check..."
    if make -j"$(nproc --all)" "${MAKE_COMMON[@]}" prepare >/dev/null 2>&1; then
        spin_stop ok "Sanity check passed"
        panel_stop
        exit 0
    else
        spin_stop fail "Sanity check failed"
        panel_set_mark 5 FAIL
        panel_stop
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
#  5/6 VDSO
# -----------------------------------------------------------------------------
panel_set_mark 4 RUN
spin_start "Building vdso-offsets.h ..."
if make "${MAKE_COMMON[@]}" arch/arm64/kernel/vdso/ >/dev/null 2>&1; then
    if [ -f out/include/generated/vdso-offsets.h ]; then
        spin_stop ok "vdso-offsets.h generated"
    else
        spin_stop fail "vdso-offsets.h not found"; panel_set_mark 4 FAIL; exit 1
    fi
else
    spin_stop fail "vdso build failed"; panel_set_mark 4 FAIL; exit 1
fi
panel_set_mark 4 DONE

# -----------------------------------------------------------------------------
#  6/6 编译
# -----------------------------------------------------------------------------
panel_set_mark 5 RUN
log_info "Starting compilation..."

BUILD_LOG="$(mktemp /tmp/kernel-build-XXXXXX.log)"
START_TS=$(date +%s)

# 编译日志同时输出到面板日志文件
(
    make -j"$(nproc --all)" "${MAKE_COMMON[@]}" \
        KCFLAGS="-Wno-error=default-const-init-var-unsafe -Wno-default-const-init-var-unsafe" \
        Image.gz >"$BUILD_LOG" 2>&1
    echo "MAKE_EXIT:$?" >> "$BUILD_LOG.exit"
) &
BUILD_PID=$!

# 后台把日志喂给 panel_log
(
    local_prev=0
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        if [ -f "$BUILD_LOG" ]; then
            # 读新增的行，写入 panel_log
            total=$(wc -l < "$BUILD_LOG" 2>/dev/null || echo 0)
            if [ "$total" -gt "$local_prev" ]; then
                tail -n $((total - local_prev)) "$BUILD_LOG" | while IFS= read -r line; do
                    [ -n "$line" ] && panel_log "$line"
                done
                local_prev=$total
            fi
        fi
        sleep 0.2
    done
    # 最后再补一次
    if [ -f "$BUILD_LOG" ]; then
        total=$(wc -l < "$BUILD_LOG" 2>/dev/null || echo 0)
        if [ "$total" -gt "$local_prev" ]; then
            tail -n $((total - local_prev)) "$BUILD_LOG" | while IFS= read -r line; do
                [ -n "$line" ] && panel_log "$line"
            done
        fi
    fi
) &
LOG_FEED_PID=$!

wait "$BUILD_PID"
make_rc=0
[ -f "$BUILD_LOG.exit" ] && { make_rc=$(cut -d: -f2 < "$BUILD_LOG.exit"); rm -f "$BUILD_LOG.exit"; }
wait "$LOG_FEED_PID" 2>/dev/null || true

if [ "$make_rc" -eq 0 ]; then
    END_TS=$(date +%s)
    BUILD_TIME=$(( END_TS - START_TS ))
    panel_set_mark 5 DONE

    sleep 0.5
    panel_stop

    echo
    hr
    log_ok "Kernel compiled successfully in ${BUILD_TIME}s"
    log_dim "📦 Image.gz: $CURRENT_DIR/out/arch/arm64/boot/Image.gz"
    hr

    if [ "$ZIP_ANY_KERNEL" = true ]; then
        echo
        spin_start "Packaging AnyKernel3 zip..."
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
            spin_stop warn "AnyKernel3 clone failed; only Image.gz"
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
    printf "  ${C_DIM}⏱  Total:${C_RESET} ${C_BOLD}%d min %d sec${C_RESET}\n" \
        $((SECONDS / 60)) $((SECONDS % 60))
    hr
    echo
    rm -f "$BUILD_LOG"
else
    panel_set_mark 5 FAIL
    sleep 0.3
    print_error_context "$BUILD_LOG"
    exit 1
fi
