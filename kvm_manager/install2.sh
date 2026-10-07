#!/bin/sh
# ckvm one-command installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager/install2.sh | sh
#
# From a machine that can reach GitHub that works.  From mainland China it
# usually cannot, so this script also tries the accelerators that were measured
# reachable, in order, and uses the first that answers.
#
#   ghproxy.net    OK
#   gh-proxy.com   OK
#   direct         usually blocked
#
# Pin one if you prefer:
#
#   sh -s -- --from https://ghproxy.net/
#
# Three details that cost time to find:
#   * the raw path must be /<branch>/..., NOT /refs/heads/<branch>/... -
#     the latter returned HTTP 500 from GitHub's raw host.
#   * git.yylx.win proxies `git clone` only; it does NOT serve raw files (404),
#     so a clone-based installer cannot work either.
#   * ckvm is Python, so python3 must exist before anything can run.  A bare
#     Debian container has no python3 at all; this script installs it instead of
#     telling the user to go and do it.

set -eu

REPO="ccmx200/kernel-lxc-xiaomi_mt6833"
BRANCH="resukisu"
FILE="kvm_manager/ckvm.py"
# ckvm imports this for its animations; without it the tool still works but
# silently loses every spinner and progress bar, so it is fetched too
UIFILE="kvm_manager/ckvm_ui.py"
INSTALLER_VERSION="5"

FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:-}"; shift 2 ;;
        -cn|--cn|-y|--yes) shift ;;
        http*) FROM="$1"; shift ;;
        *) shift ;;
    esac
done
[ -n "${CKVM_FROM:-}" ] && FROM="$CKVM_FROM"

say() { printf '  %s\n' "$*"; }
die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

TMP="$(mktemp "${TMPDIR:-/tmp}/ckvm.XXXXXX")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ckvm-src.XXXXXX")"
trap 'rm -f "$TMP"; rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------
# 1. python3 first - nothing can run without it
# --------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    say "没有 python3，先装一个"
    if command -v apt-get >/dev/null 2>&1; then
        # a fresh container may have empty package lists, so update first
        DEBIAN_FRONTEND=noninteractive timeout 300 apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive timeout 900 \
            apt-get install -y python3 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache python3 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm python || true
    fi
fi
if ! command -v python3 >/dev/null 2>&1; then
    die "装不上 python3。手动装好再重跑：
       Debian/Ubuntu:  apt-get update && apt-get install -y python3"
fi
say "python3 $(python3 -V 2>&1 | awk '{print $2}')"

# --------------------------------------------------------------------------
# 2. a downloader
# --------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    say "没有 curl/wget，先装一个"
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive timeout 600 apt-get install -y curl || true
    fi
fi
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "需要 curl 或 wget"
fi

# --------------------------------------------------------------------------
# 3. fetch ckvm.py, trying each mirror
# --------------------------------------------------------------------------
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 180 -o "$TMP" "$1" 2>/dev/null
    else
        wget -q -O "$TMP" --timeout=180 "$1" 2>/dev/null
    fi
}

# fetch to an explicit path, for the second file
fetch_to() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 180 -o "$2" "$1" 2>/dev/null
    else
        wget -q -O "$2" --timeout=180 "$1" 2>/dev/null
    fi
}

looks_valid() {
    [ -s "$TMP" ] || return 1
    head -1 "$TMP" | grep -q python || return 1
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TMP" 2>/dev/null
}

CHOSEN=""
try_one() {
    printf '  尝试 %s\n' "$1"
    if fetch "$1" && looks_valid; then
        CHOSEN="$1"
        return 0
    fi
    printf '    不行\n'
    return 1
}

try_list() {
    for tmpl in \
        "https://ghproxy.net/https://raw.githubusercontent.com/%R/%B/%F" \
        "https://gh-proxy.com/https://raw.githubusercontent.com/%R/%B/%F" \
        "https://raw.githubusercontent.com/%R/%B/%F"
    do
        u=$(printf '%s' "$tmpl" | sed -e "s|%R|$REPO|g" -e "s|%B|$BRANCH|g" -e "s|%F|$FILE|g")
        try_one "$u" && return 0
    done
    return 1
}

if [ -n "$FROM" ]; then
    case "$FROM" in */) pref="$FROM" ;; *) pref="$FROM/" ;; esac
    if ! try_one "${pref}https://raw.githubusercontent.com/$REPO/$BRANCH/$FILE"; then
        printf '  指定的源不行，改用默认列表\n'
        try_list || die "所有源都失败。手动指定： sh -s -- --from https://你的代理/"
    fi
else
    try_list || die "所有源都失败。手动指定： sh -s -- --from https://你的代理/"
fi

say "来源 $CHOSEN（installer v$INSTALLER_VERSION）"

# ---- the animation module, into the same directory ckvm.py will be run from
if [ -n "$FROM" ]; then
    case "$FROM" in */) pref="$FROM" ;; *) pref="$FROM/" ;; esac
    UURL="${pref}https://raw.githubusercontent.com/$REPO/$BRANCH/$UIFILE"
else
    UURL="https://ghproxy.net/https://raw.githubusercontent.com/$REPO/$BRANCH/$UIFILE"
fi
printf '  取动画模块\n'
if fetch_to "$UURL" "$WORK/ckvm_ui.py" \
   && head -1 "$WORK/ckvm_ui.py" | grep -q python; then
    say "动画模块已取到"
else
    say "动画模块没取到（功能不受影响，只是没有动画）"
    rm -f "$WORK/ckvm_ui.py"
fi

# put ckvm.py beside it so `install` finds both, then install from there
cp "$TMP" "$WORK/ckvm.py"
say "下载完成，开始安装..."
printf '\n'

# Do NOT exec here.  exec replaces this shell, so the EXIT trap never runs and
# every install left /tmp/ckvm.XXXXXX and /tmp/ckvm-src.XXXXXX behind - about
# 110KB plus a directory each time.  Run it, then remove both.
python3 "$WORK/ckvm.py" install
rc=$?
rm -f "$TMP"
rm -rf "$WORK"
exit $rc
