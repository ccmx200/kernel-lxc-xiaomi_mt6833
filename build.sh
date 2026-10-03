#!/bin/bash
# =============================================================================
#  🚀  ReSukiSU Kernel Builder  ·  Dual-Panel v3 (low-flicker)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
#  🎨 Colors
# -----------------------------------------------------------------------------
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'; C_WHITE='\033[1;37m'; C_ORANGE='\033[38;5;208m'
C_PINK='\033[38;5;213m'; C_LAVENDER='\033[38;5;183m'; C_SKY='\033[38;5;117m'
C_GREY='\033[38;5;245m'
C_BG_RED='\033[48;5;160m'; C_BG_GREEN='\033[48;5;28m'
C_BG_BLUE='\033[48;5;24m'; C_BG_PURPLE='\033[48;5;90m'

# -----------------------------------------------------------------------------
#  🧠 CLI
# -----------------------------------------------------------------------------
GH_PROXY=""; NO_CCACHE=""; NO_UPDATE=""; CHECK_ONLY=""
SKIP_MENUCONFIG=""; SAVE_CONFIG=""

usage() {
    printf "${C_ORANGE}${C_BOLD}🚀 ReSukiSU Kernel Builder${C_RESET}\n\n"
    printf "  ${C_CYAN}-cn [URL]${C_RESET}          GitHub acceleration\n"
    printf "  ${C_CYAN}--no-ccache${C_RESET}        Disable ccache\n"
    printf "  ${C_CYAN}-nu${C_RESET}                Skip ReSukiSU update\n"
    printf "  ${C_CYAN}--no-menuconfig${C_RESET}    Skip menuconfig\n"
    printf "  ${C_CYAN}--no-panel${C_RESET}         Disable dual panel\n"
    printf "  ${C_CYAN}-s${C_RESET}                 Save final config\n"
    printf "  ${C_CYAN}--check${C_RESET}            Sanity check only\n"
}

NO_PANEL=""
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
        --no-panel)      NO_PANEL=1 ;;
        -s|--save-config) SAVE_CONFIG=1 ;;
        --check|--test)  CHECK_ONLY=1 ;;
        -h|--help)       usage; exit 0 ;;
        *) printf "${C_RED}Unknown: %s${C_RESET}\n" "$1" >&2; exit 1 ;;
    esac
    shift
done

gh_url() {
    [ -z "$GH_PROXY" ] && { printf '%s' "$1"; return; }
    printf '%s' "$1" | sed \
        -e "s|https://github.com/|${GH_PROXY}github.com/|g" \
        -e "s|https://raw.githubusercontent.com/|${GH_PROXY}raw.githubusercontent.com/|g"
}

# =============================================================================
#  🖼️  Panel
# =============================================================================
PANEL_LOG_FILE=""
PANEL_STATE_FILE=""
PANEL_STOP_FILE=""
PANEL_REFRESH_PID=""
PANEL_ACTIVE=0
PANEL_SUSPEND=0
PANEL_TERM_W=80
PANEL_TERM_H=24
PANEL_USE=1                 # 1=启用双栏, 0=降级普通模式
PANEL_LEFT_W=22
PANEL_TOP_ROWS=8            # 标题1 + 6步 + 分隔线1
PANEL_ROLL_ROW=$((PANEL_TOP_ROWS + 1))

readonly STEP_NAMES=("1/6 Cleanup" "2/6 Toolchain" "3/6 ReSukiSU" "4/6 Config" "5/6 VDSO" "6/6 Compile")
readonly STEP_COUNT=6

# 缓存上一帧（增量重绘）
declare -a _LAST_LINES=()
declare -a _LAST_ICONS=()

# 状态文件读写
panel_set_mark() {
    local idx=$1 state=$2
    [ "$PANEL_USE" = "0" ] && return
    [ -z "$PANEL_STATE_FILE" ] && return
    local -a s
    mapfile -t s < "$PANEL_STATE_FILE" 2>/dev/null || s=()
    while [ "${#s[@]}" -lt "$STEP_COUNT" ]; do s+=("WAIT"); done
    s[$idx]="$state"
    printf '%s\n' "${s[@]}" > "$PANEL_STATE_FILE"
}

panel_log() {
    [ -z "$PANEL_LOG_FILE" ] && return
    printf '%s\n' "$1" >> "$PANEL_LOG_FILE"
    local n
    n=$(wc -l < "$PANEL_LOG_FILE" 2>/dev/null || echo 0)
    if [ "$n" -gt 300 ]; then
        tail -n 300 "$PANEL_LOG_FILE" > "${PANEL_LOG_FILE}.tmp" && \
            mv "${PANEL_LOG_FILE}.tmp" "$PANEL_LOG_FILE"
    fi
}

# 图标
_step_icon() {
    case "$1" in
        DONE) printf '✅' ;;
        RUN)  printf '🔄' ;;
        FAIL) printf '❌' ;;
        *)    printf '⏸ ' ;;
    esac
}
_step_color() {
    case "$1" in
        DONE) printf '%s' "$C_GREEN" ;;
        RUN)  printf '%s' "$C_YELLOW" ;;
        FAIL) printf '%s' "$C_RED" ;;
        *)    printf '%s' "$C_DIM" ;;
    esac
}

# 增量重绘
_panel_render() {
    [ "$PANEL_SUSPEND" = "1" ] && return 0
    [ "$PANEL_ACTIVE" = "0" ] && return 0

    local -a states logs
    mapfile -t states < "$PANEL_STATE_FILE" 2>/dev/null || states=()
    while [ "${#states[@]}" -lt "$STEP_COUNT" ]; do states+=("WAIT"); done

    mapfile -t logs < <(tail -n "$STEP_COUNT" "$PANEL_LOG_FILE" 2>/dev/null || true)

    local rw=$((PANEL_TERM_W - PANEL_LEFT_W - 6))
    [ "$rw" -lt 15 ] && rw=15

    printf '\033[?2026h'

    local i=0
    while [ "$i" -lt "$STEP_COUNT" ]; do
        local state="${states[$i]}"
        local log="${logs[$i]:-}"
        local icon color
        icon="$(_step_icon "$state")"
        color="$(_step_color "$state")"

        # 截断日志
        [ "${#log}" -gt "$rw" ] && log="${log:0:$((rw-3))}..."

        # 只有状态或日志变化才重绘
        if [ "${_LAST_ICONS[$i]:-}" != "$state" ] || [ "${_LAST_LINES[$i]:-}" != "$log" ]; then
            local row=$((i + 2))
            printf '\033[%d;1H\033[K' "$row"
            printf "  ${C_WHITE}%-$((PANEL_LEFT_W - 4))s${C_RESET} ${color}%s${C_RESET} ${C_GREY}│${C_RESET} ${C_DIM}%s${C_RESET}" \
                "${STEP_NAMES[$i]}" "$icon" "$log"
            _LAST_ICONS[$i]="$state"
            _LAST_LINES[$i]="$log"
        fi
        i=$((i + 1))
    done

    printf '\033[?2026l'
}

# 首帧全绘制（标题 + 分隔线 + 全部步骤）
_panel_first_draw() {
    printf '\033[?2026h'

    # 标题栏
    printf '\033[1;1H\033[K'
    printf "${C_BG_PURPLE}${C_WHITE}${C_BOLD}  Build Progress  ${C_RESET} ${C_GREY}│${C_RESET} ${C_BG_BLUE}${C_WHITE}${C_BOLD}  Live Log  ${C_RESET}"

    # 步骤行（初始 WAIT）
    local i=0
    while [ "$i" -lt "$STEP_COUNT" ]; do
        local row=$((i + 2))
        printf '\033[%d;1H\033[K' "$row"
        printf "  ${C_WHITE}%-$((PANEL_LEFT_W - 4))s${C_RESET} ${C_DIM}⏸ ${C_RESET} ${C_GREY}│${C_RESET} " \
            "${STEP_NAMES[$i]}"
        i=$((i + 1))
    done

    # 分隔线
    printf '\033[%d;1H\033[K' "$PANEL_TOP_ROWS"
    printf "${C_GREY}"
    printf '─%.0s' $(seq 1 "$PANEL_TERM_W")
    printf "${C_RESET}"

    printf '\033[?2026l'
}

panel_start() {
    [ "$PANEL_ACTIVE" = "1" ] && return 0
    [ "$NO_PANEL" = "1" ] && { PANEL_USE=0; return 0; }

    # 读终端尺寸（只读一次）
    local size
    size=$(stty size 2>/dev/null || echo "24 80")
    PANEL_TERM_H=${size% *}
    PANEL_TERM_W=${size#* }
    [ "$PANEL_TERM_W" -lt 1 ] && PANEL_TERM_W=80
    [ "$PANEL_TERM_H" -lt 1 ] && PANEL_TERM_H=24

    # 太小就降级
    if [ "$PANEL_TERM_W" -lt 60 ] || [ "$PANEL_TERM_H" -lt 20 ]; then
        PANEL_USE=0
        printf "${C_YELLOW}⚠️  终端太小 (%dx%d)，禁用双栏面板${C_RESET}\n" \
            "$PANEL_TERM_W" "$PANEL_TERM_H"
        return 0
    fi

    # 左栏宽度自适应
    if   [ "$PANEL_TERM_W" -ge 100 ]; then PANEL_LEFT_W=24
    elif [ "$PANEL_TERM_W" -ge 80  ]; then PANEL_LEFT_W=22
    else                                    PANEL_LEFT_W=20
    fi

    PANEL_ACTIVE=1
    PANEL_LOG_FILE="$(mktemp /tmp/panel-log-XXXXXX)"
    PANEL_STATE_FILE="$(mktemp /tmp/panel-state-XXXXXX)"
    PANEL_STOP_FILE="$(mktemp /tmp/panel-stop-XXXXXX)"
    printf 'WAIT\nWAIT\nWAIT\nWAIT\nWAIT\nWAIT\n' > "$PANEL_STATE_FILE"

    clear 2>/dev/null || true
    printf '\033[?25l'

    # 滚动区从第 9 行开始
    printf '\033[%d;%dr' "$PANEL_ROLL_ROW" "$PANEL_TERM_H"

    _panel_first_draw

    # 光标放到滚动区顶部
    printf '\033[%d;1H' "$PANEL_ROLL_ROW"

    # 后台增量刷新（0.3s 间隔）
    (
        while [ ! -s "$PANEL_STOP_FILE" ]; do
            _panel_render 2>/dev/null || true
            sleep 0.3
        done
    ) &
    PANEL_REFRESH_PID=$!
    disown "$PANEL_REFRESH_PID" 2>/dev/null || true
}

panel_stop() {
    [ "$PANEL_ACTIVE" = "0" ] && return 0
    PANEL_ACTIVE=0

    if [ -n "$PANEL_REFRESH_PID" ]; then
        : > "$PANEL_STOP_FILE" 2>/dev/null || true
        sleep 0.4
        kill "$PANEL_REFRESH_PID" 2>/dev/null || true
        wait "$PANEL_REFRESH_PID" 2>/dev/null || true
        PANEL_REFRESH_PID=""
    fi

    printf '\033[r\033[?25h'

    [ -n "$PANEL_STOP_FILE" ] && rm -f "$PANEL_STOP_FILE"
    [ -n "$PANEL_LOG_FILE" ] && rm -f "$PANEL_LOG_FILE"
    [ -n "$PANEL_STATE_FILE" ] && rm -f "$PANEL_STATE_FILE"
    PANEL_STOP_FILE=""; PANEL_LOG_FILE=""; PANEL_STATE_FILE=""
}

panel_suspend() {
    PANEL_SUSPEND=1
    printf '\033[r\033[?25h'
    printf "\033[%d;1H\n\n" "$PANEL_ROLL_ROW"
}

panel_resume() {
    PANEL_SUSPEND=0
    printf '\033[%d;%dr\033[?25l\033[%d;1H' \
        "$PANEL_ROLL_ROW" "$PANEL_TERM_H" "$PANEL_ROLL_ROW"
}

# -----------------------------------------------------------------------------
#  📝 Logging
# -----------------------------------------------------------------------------
log_info()  { panel_log "💡 $1"; }
log_ok()    { panel_log "✅ $1"; }
log_warn()  { panel_log "⚠️  $1"; }
log_error() { panel_log "❌ $1"; }
log_dim()   { panel_log "   $1"; }

# 直接输出到滚动区（不受面板影响）
print_scroll() { printf "%s\n" "$1"; }

# Spinner（滚动区顶行）
SPINNER_PID=""
spin_start() {
    local msg="$1"
    [ "$PANEL_ACTIVE" = "0" ] && { printf "  %s..." "$msg"; return; }
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while :; do
            printf '\033[%d;1H\033[K%s  %s  %s%s%s' \
                "$PANEL_ROLL_ROW" "$C_CYAN" "${frames[$i]}" "$C_RESET" "$C_DIM" "$msg$C_RESET"
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
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
    if [ "$PANEL_ACTIVE" = "1" ]; then
        printf '\033[%d;1H\033[K' "$PANEL_ROLL_ROW"
    else
        printf "\n"
    fi
    case "$status" in
        ok)   log_ok "$msg";   [ "$PANEL_ACTIVE" = "0" ] && printf "${C_GREEN}  ✅${C_RESET}  %s\n" "$msg" ;;
        fail) log_error "$msg"; [ "$PANEL_ACTIVE" = "0" ] && printf "${C_RED}  ❌${C_RESET}  %s\n" "$msg" >&2 ;;
        warn) log_warn "$msg"; [ "$PANEL_ACTIVE" = "0" ] && printf "${C_YELLOW}  ⚠️${C_RESET}   %s\n" "$msg" ;;
        *)    log_info "$msg"; [ "$PANEL_ACTIVE" = "0" ] && printf "${C_SKY}  💡${C_RESET}  %s\n" "$msg" ;;
    esac
}

# -----------------------------------------------------------------------------
#  🚨 Error context
# -----------------------------------------------------------------------------
ERROR_CTX="${ERROR_CTX:-200}"

print_error_context() {
    local log_file="$1"
    local ctx="$ERROR_CTX"
    [ -f "$log_file" ] || return 0

    local first_err
    first_err="$(grep -n -m1 -E '([[:space:]]error:|^error:|Error [0-9]+|ERROR:|fatal error:)' "$log_file" 2>/dev/null | cut -d: -f1 || true)"

    if [ -z "$first_err" ]; then
        printf "\n${C_BG_RED}${C_WHITE}${C_BOLD}  ❌ Build failed  ·  no error marker  ${C_RESET}\n\n"
        tail -n 40 "$log_file" | sed 's/^/    /'
        return 0
    fi

    local total start end
    total=$(wc -l < "$log_file")
    start=$(( first_err - ctx )); end=$(( first_err + ctx ))
    [ "$start" -lt 1 ] && start=1
    [ "$end" -gt "$total" ] && end="$total"

    printf "\n${C_BG_RED}${C_WHITE}${C_BOLD}  ❌ Build failed  ·  line %d/%d  ·  ±%d  ${C_RESET}\n" \
        "$first_err" "$total" "$ctx"
    printf "${C_DIM}  ─── lines %d..%d ───${C_RESET}\n\n" "$start" "$end"

    awk -v s="$start" -v e="$end" -v fe="$first_err" '
        NR>=s && NR<=e { if (NR==fe) printf "\033[1;31m  ▶ %s\033[0m\n",$0; else printf "    %s\n",$0 }
    ' "$log_file"

    printf "\n  ${C_DIM}Full log:${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$log_file"
}

# -----------------------------------------------------------------------------
#  🔧 Config diff
# -----------------------------------------------------------------------------
CFG_BEFORE=""; CFG_AFTER=""

norm_config() {
    grep -E '^(CONFIG_[A-Z0-9_]+=.*|# CONFIG_[A-Z0-9_]+ is not set)' "$1" 2>/dev/null \
        | sed -E 's/^# (CONFIG_[A-Z0-9_]+) is not set$/\1=n/' | sort -u
}

print_config_block() {
    local title="$1" file="$2" fg="$3" bg="$4" count="$5"
    [ ! -s "$file" ] && return 0
    printf "\n  ${bg}${C_WHITE}${C_BOLD}  %s  ·  %d items  ${C_RESET}\n" "$title" "$count"
    printf "  ${fg}"; printf '─%.0s' $(seq 1 $((PANEL_TERM_W - 6))); printf "${C_RESET}\n"
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

    printf "\n${C_BG_BLUE}${C_WHITE}${C_BOLD}  🎨 Menuconfig Changes  ${C_RESET}\n"
    if [ "$an" -eq 0 ] && [ "$rn" -eq 0 ]; then
        printf "  ${C_DIM}no changes${C_RESET}\n"
        rm -f "$b" "$a"; return 0
    fi
    printf "  ${C_GREEN}➕ Added: %d${C_RESET}    ${C_RED}➖ Removed: %d${C_RESET}\n" "$an" "$rn"

    local lf rf
    lf="$(mktemp)"; rf="$(mktemp)"
    [ -n "$added" ]   && printf '%s\n' "$added"   > "$lf"
    [ -n "$removed" ] && printf '%s\n' "$removed" > "$rf"
    print_config_block "➕ Added"   "$lf" "$C_GREEN" "$C_BG_GREEN" "$an"
    print_config_block "➖ Removed" "$rf" "$C_RED"   "$C_BG_RED"   "$rn"
    rm -f "$b" "$a" "$lf" "$rf"
}

check_key_configs() {
    printf "\n${C_PINK}${C_BOLD}  🔍 Key Configs${C_RESET}\n"
    for key in CONFIG_KSU CONFIG_DOCKER CONFIG_SYSVIPC CONFIG_IPC_NS CONFIG_KVM; do
        if grep -qE "^${key}=y" out/.config 2>/dev/null; then
            printf "  ${C_GREEN}✅${C_RESET}  %-40s ${C_GREEN}=y${C_RESET}\n" "$key"
        elif grep -qE "^# ${key} is not set" out/.config 2>/dev/null; then
            printf "  ${C_YELLOW}➖${C_RESET}  %-40s ${C_DIM}not set${C_RESET}\n" "$key"
        else
            printf "  ${C_RED}❓${C_RESET}  %-40s ${C_DIM}missing${C_RESET}\n" "$key"
        fi
    done
}

# -----------------------------------------------------------------------------
#  📦 ReSukiSU info
# -----------------------------------------------------------------------------
RSU_VERSION="unknown"; RSU_COMMIT="unknown"
RSU_BRANCH="unknown";  RSU_DIRTY="clean"; RSU_UPDATED="no"

get_resukisu_info() {
    local dir="$CURRENT_DIR/ReSukiSU"
    RSU_VERSION="unknown"; RSU_COMMIT="unknown"; RSU_BRANCH="unknown"; RSU_DIRTY="clean"
    if [ ! -d "$dir/.git" ] && [ -d "$dir/kernel" ]; then
        RSU_VERSION="vendored"; RSU_COMMIT="vendored"; RSU_BRANCH="main"
        return 0
    fi
    if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
        RSU_COMMIT="$(git -C "$dir" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
        RSU_BRANCH="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
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
    new="$(git -C "$dir" rev-parse FETCH_HEAD 2>/dev/null || echo '')"
    [ -z "$new" ] && return 1
    [ "$old" = "$new" ] && return 3
    git -C "$dir" reset --hard "$new" >/dev/null 2>&1 || return 1
    RSU_UPDATED="yes"
    return 0
}

# =============================================================================
#  ⚙️  Main
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
    printf '\033[r\033[?25h' 2>/dev/null || true
}
trap cleanup EXIT

panel_start

# ---- 1/6 Cleanup ----
panel_set_mark 0 RUN
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

# ---- 2/6 Toolchain ----
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

# ---- 3/6 ReSukiSU ----
panel_set_mark 2 RUN
if [ ! -d "$CURRENT_DIR/ReSukiSU/kernel" ]; then
    spin_start "Cloning ReSukiSU..."
    CLONE_URL="$(gh_url 'https://github.com/ReSukiSU/ReSukiSU.git')"
    if GIT_SSL_NO_VERIFY=true git clone --depth=1 --branch main \
        "$CLONE_URL" "$CURRENT_DIR/ReSukiSU" >/dev/null 2>&1; then
        spin_stop ok "ReSukiSU cloned"; RSU_UPDATED="yes"
    else
        spin_stop fail "Clone failed"; panel_set_mark 2 FAIL; exit 1
    fi
else
    log_ok "ReSukiSU source present"
    if [ ! -d "$CURRENT_DIR/ReSukiSU/.git" ]; then
        log_ok "Vendored ReSukiSU"
    elif [ -n "$NO_UPDATE" ]; then
        log_warn "Auto-update disabled"
    else
        spin_start "Checking updates..."
        set +e; update_resukisu; rc=$?; set -e
        case "$rc" in
            0) spin_stop ok "Updated to latest" ;;
            2) spin_stop warn "Local changes · skipped" ;;
            3) spin_stop ok "Already up to date" ;;
            *) spin_stop warn "Update failed · using local" ;;
        esac
    fi
fi
spin_start "Reading version..."
get_resukisu_info
spin_stop ok "Version: $RSU_VERSION ($RSU_COMMIT)"

rm -f drivers/kernelsu
ln -sfn ../ReSukiSU/kernel drivers/kernelsu
grep -q 'kernelsu' drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
grep -q 'drivers/kernelsu/Kconfig' drivers/Kconfig || \
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
log_ok "ReSukiSU integrated"
panel_set_mark 2 DONE

# ---- 4/6 Config ----
panel_set_mark 3 RUN
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

if [ -z "$SKIP_MENUCONFIG" ]; then
    CFG_BEFORE="$(mktemp /tmp/kcfg-before-XXXXXX)"
    cp out/.config "$CFG_BEFORE"

    panel_suspend
    printf "\n${C_BG_TEAL:-}${C_WHITE}${C_BOLD}  🎛️  menuconfig  ${C_RESET}\n\n"
    printf "  ${C_SKY}↑↓ 移动  空格 切换  / 搜索  Enter 进入  ESC ESC 返回${C_RESET}\n"
    printf "  ${C_YELLOW}⚠️  退出前记得 <Save>${C_RESET}\n\n"

    set +e
    (
        unset CC; unset LD
        export CURSES_LOC='ncurses.h'
        make O=out ARCH=arm64 HOSTCC=gcc HOSTLD=ld HOSTCXX=g++ menuconfig
    )
    menu_rc=$?
    set -e

    [ "$menu_rc" -ne 0 ] && log_warn "menuconfig rc=$menu_rc"
    [ ! -f out/.config ] && { panel_resume; log_error "config gone"; exit 1; }

    CFG_AFTER="$(mktemp /tmp/kcfg-after-XXXXXX)"
    cp out/.config "$CFG_AFTER"

    panel_resume
    show_menuconfig_diff

    rm -f "$CFG_BEFORE" "$CFG_AFTER"
    CFG_BEFORE=""; CFG_AFTER=""
else
    log_info "menuconfig skipped"
fi

if [ -n "$SAVE_CONFIG" ]; then
    cp out/.config "$CURRENT_DIR/kernel.config"
    log_ok "Saved final config"
fi

check_key_configs
panel_set_mark 3 DONE

if [ -n "$CHECK_ONLY" ]; then
    panel_set_mark 4 DONE; panel_set_mark 5 DONE
    spin_start "Sanity check..."
    if make -j"$(nproc --all)" "${MAKE_COMMON[@]}" prepare >/dev/null 2>&1; then
        spin_stop ok "Sanity check passed"
        sleep 0.5; panel_stop; exit 0
    else
        spin_stop fail "Sanity check failed"
        panel_set_mark 5 FAIL; sleep 0.3; panel_stop; exit 1
    fi
fi

# ---- 5/6 VDSO ----
panel_set_mark 4 RUN
spin_start "Building vdso-offsets.h ..."
if make "${MAKE_COMMON[@]}" arch/arm64/kernel/vdso/ >/dev/null 2>&1; then
    if [ -f out/include/generated/vdso-offsets.h ]; then
        spin_stop ok "vdso-offsets.h generated"
    else
        spin_stop fail "vdso-offsets.h missing"; panel_set_mark 4 FAIL; exit 1
    fi
else
    spin_stop fail "vdso build failed"; panel_set_mark 4 FAIL; exit 1
fi
panel_set_mark 4 DONE

# ---- 6/6 Compile ----
panel_set_mark 5 RUN
log_info "Starting compilation..."

BUILD_LOG="$(mktemp /tmp/kernel-build-XXXXXX.log)"
START_TS=$(date +%s)

(
    make -j"$(nproc --all)" "${MAKE_COMMON[@]}" \
        KCFLAGS="-Wno-error=default-const-init-var-unsafe -Wno-default-const-init-var-unsafe" \
        Image.gz >"$BUILD_LOG" 2>&1
    echo "$?" > "${BUILD_LOG}.rc"
) &
BUILD_PID=$!

# 后台喂日志
(
    prev=0
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        if [ -f "$BUILD_LOG" ]; then
            total=$(wc -l < "$BUILD_LOG" 2>/dev/null || echo 0)
            if [ "$total" -gt "$prev" ]; then
                tail -n $((total - prev)) "$BUILD_LOG" | while IFS= read -r line; do
                    [ -n "$line" ] && panel_log "$line"
                done
                prev=$total
            fi
        fi
        sleep 0.4
    done
    if [ -f "$BUILD_LOG" ]; then
        total=$(wc -l < "$BUILD_LOG" 2>/dev/null || echo 0)
        if [ "$total" -gt "$prev" ]; then
            tail -n $((total - prev)) "$BUILD_LOG" | while IFS= read -r line; do
                [ -n "$line" ] && panel_log "$line"
            done
        fi
    fi
) &
LOG_FEED_PID=$!

wait "$BUILD_PID"
make_rc=0
[ -f "${BUILD_LOG}.rc" ] && { make_rc=$(cat "${BUILD_LOG}.rc"); rm -f "${BUILD_LOG}.rc"; }
wait "$LOG_FEED_PID" 2>/dev/null || true

if [ "$make_rc" -eq 0 ]; then
    END_TS=$(date +%s); BUILD_TIME=$(( END_TS - START_TS ))
    panel_set_mark 5 DONE
    sleep 0.5
    panel_stop

    printf "\n${C_GREEN}${C_BOLD}  ✅  Kernel compiled in ${BUILD_TIME}s${C_RESET}\n"
    printf "  ${C_DIM}📦 Image.gz:${C_RESET} ${C_BOLD}%s${C_RESET}\n\n" \
        "$CURRENT_DIR/out/arch/arm64/boot/Image.gz"

    if [ "$ZIP_ANY_KERNEL" = true ]; then
        spin_start "Packaging AnyKernel3..."
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

    printf "\n${C_GREEN}${C_BOLD}"
    cat <<'EOF'
     ✨ ═══════════════════════════════════════ ✨
              🎉  B U I L D   D O N E  🎉
     ✨ ═══════════════════════════════════════ ✨
EOF
    printf "${C_RESET}\n"
    printf "  ${C_DIM}⏱  Total:${C_RESET} ${C_BOLD}%d min %d sec${C_RESET}\n\n" \
        $((SECONDS / 60)) $((SECONDS % 60))

    rm -f "$BUILD_LOG"
else
    panel_set_mark 5 FAIL
    sleep 0.3
    panel_stop
    print_error_context "$BUILD_LOG"
    exit 1
fi
