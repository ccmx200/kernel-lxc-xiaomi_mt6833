#!/bin/sh
# ckvm one-command installer.
#
#   curl -fsSLk <url>/install.sh | sh
#   curl -fsSLk <url>/install.sh | sh -s -- -cn https://your.accel
#
# It exists because ckvm is Python: the program cannot bootstrap itself before
# it is running, and requiring "download first, then run" was one step too many.
#
# Everything that needs a terminal question (which apt mirror, which GitHub
# accelerator) is asked by ckvm.py install afterwards; this only fetches it.

set -eu

BASE="${CKVM_REPO:-https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/refs/heads/resukisu}"
ACCEL=""

for a in "$@"; do
    case "$a" in
        -cn|--cn)
            # only the bare form here; a URL form needs the next argument
            [ -n "${CKVM_ACCEL:-}" ] && ACCEL="$CKVM_ACCEL" || ACCEL="1"
            ;;
        http*|https*)
            ACCEL="$a" ;;
    esac
done
[ -n "${CKVM_ACCEL:-}" ] && ACCEL="$CKVM_ACCEL"

say()  { printf '  %s\n' "$*"; }
die()  { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
    die "需要 python3（Debian/Ubuntu: apt-get install -y python3）"
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/ckvm.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# try the accelerator first when one was given, then the plain path
try_fetch() {
    url="$1"
    printf '  获取 %s\n' "$url"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSLk --max-time 120 "$url" -o "$TMP"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$TMP" --timeout=120 "$url"
    else
        die "需要 curl 或 wget"
    fi
}

ok=0
if [ -n "$ACCEL" ] && [ "$ACCEL" != "1" ]; then
    case "$ACCEL" in
        *'{url}'*) try_fetch "$(printf '%s' "$ACCEL" | sed "s|{url}|$BASE/kvm_manager/ckvm.py|")" && ok=1 ;;
        */)        try_fetch "${ACCEL}${BASE}/kvm_manager/ckvm.py" && ok=1 ;;
        *)         try_fetch "${ACCEL}${BASE#https://}/kvm_manager/ckvm.py" && ok=1 ;;
    esac
fi
[ "$ok" = 1 ] || try_fetch "$BASE/kvm_manager/ckvm.py" || \
    die "下载失败。试试指定加速： sh -s -- -cn https://你的代理"

# a truncated download would be a syntax error later, so check it is Python
head -1 "$TMP" | grep -q python >/dev/null 2>&1 || die "下载到的不是 ckvm.py"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$TMP" \
    || die "下载到的文件不完整"

say "下载完成，开始安装..."
printf '\n'
if [ -n "$ACCEL" ] && [ "$ACCEL" != "1" ]; then
    exec python3 "$TMP" install -cn "$ACCEL"
fi
exec python3 "$TMP" install
