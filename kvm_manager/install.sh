#!/bin/sh
# Kept for compatibility.  The maintained installer is install2.sh.
#
# The mirror caches pinned this path to an older revision, so the current
# script lives at a new URL.  This forwards to it.
set -eu
REPO="ccmx200/kernel-lxc-xiaomi_mt6833"
BRANCH="resukisu"
for u in \
    "https://ghproxy.net/https://raw.githubusercontent.com/$REPO/$BRANCH/kvm_manager/install2.sh" \
    "https://gh-proxy.com/https://raw.githubusercontent.com/$REPO/$BRANCH/kvm_manager/install2.sh"
do
    printf '  转发到 %s\n' "$u"
    if curl -fsSL --max-time 120 "$u" -o /tmp/ckvm-install2.sh 2>/dev/null; then
        exec sh /tmp/ckvm-install2.sh "$@"
    fi
done
printf '  转发失败，直接用新地址：\n' >&2
printf '  curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/%s/%s/kvm_manager/install2.sh | sh\n' "$REPO" "$BRANCH" >&2
exit 1
