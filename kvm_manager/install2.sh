#!/bin/sh
# ckvm one-command installer.
#
# From a machine that can reach GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager/install.sh | sh
#
# From mainland China that usually fails, so plain `sh` with no arguments also
# works: this script tries the accelerators that were measured reachable and
# uses the first that answers.
#
#   ghproxy.net    OK
#   gh-proxy.com   OK
#   direct         usually blocked
#
# Pin one if you prefer:
#
#   sh -s -- --from https://ghproxy.net/
#
# Two details that cost time to find:
#   * the raw path must be /<branch>/..., NOT /refs/heads/<branch>/... -
#     the latter returned HTTP 500 from GitHub's raw host.
#   * git.yylx.win proxies `git clone` only; it does NOT serve raw files (404),
#     so a clone-based installer cannot work either.

set -eu

REPO="ccmx200/kernel-lxc-xiaomi_mt6833"
BRANCH="resukisu"
INSTALLER_VERSION="3"
FILE="kvm_manager/ckvm.py"
# ^ bump INSTALLER_VERSION whenever this file changes

FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="${2:-}"; shift 2 ;;
        -cn|--cn) shift ;;
        http*) FROM="$1"; shift ;;
        *) shift ;;
    esac
done
[ -n "${CKVM_FROM:-}" ] && FROM="$CKVM_FROM"

say() { printf '  %s\n' "$*"; }
die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "需要 python3（apt-get install -y python3）"
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "需要 curl 或 wget"
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/ckvm.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 180 -o "$TMP" "$1" 2>/dev/null
    else
        wget -q -O "$TMP" --timeout=180 "$1" 2>/dev/null
    fi
}

looks_valid() {
    [ -s "$TMP" ] || return 1
    head -1 "$TMP" | grep -q python || return 1
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TMP" 2>/dev/null
}

# %R %B %F are substituted below; {u} is the whole GitHub raw url
try_one() {
    url="$1"
    printf '  尝试 %s\n' "$url"
    if fetch "$url" && looks_valid; then
        CHOSEN="$url"
        return 0
    fi
    printf '    不行\n'
    return 1
}

CHOSEN=""
try_list() {
    for tmpl in \
        "https://ghproxy.net/https://raw.githubusercontent.com/%R/%B/%F" \
        "https://gh-proxy.com/https://raw.githubusercontent.com/%R/%B/%F" \
        "https://raw.githubusercontent.com/%R/%B/%F"
    do
        u=$(printf '%s' "$tmpl" | sed -e "s|%R|$REPO|g" -e "s|%B|$BRANCH|g" -e "s|%F|$FILE|g")
        if try_one "$u"; then
            return 0
        fi
    done
    return 1
}

if [ -n "$FROM" ]; then
    case "$FROM" in
        */)  pref="$FROM" ;;
        *)   pref="$FROM/" ;;
    esac
    if try_one "${pref}https://raw.githubusercontent.com/$REPO/$BRANCH/$FILE"; then
        say "来源 $CHOSEN（installer v$INSTALLER_VERSION）"
    else
        printf '  指定的源不行，改用默认列表\n'
        try_list || die "所有源都失败。手动指定： sh -s -- --from https://你的代理/"
        say "来源 $CHOSEN"
    fi
else
    try_list || die "所有源都失败。手动指定： sh -s -- --from https://你的代理/"
    say "来源 $CHOSEN"
fi

say "下载完成，开始安装..."
printf '\n'
exec python3 "$TMP" install
