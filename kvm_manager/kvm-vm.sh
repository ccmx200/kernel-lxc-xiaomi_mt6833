#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
# =============================================================================
#  ckvm - KVM guest manager for MT6833 / evergo (nVHE KVM, droidspaces)
#
#  Copyright (C) 2026 璀璨梦星 (cuicanmx) <https://github.com/ccmx200>
#
#  Released under the GNU General Public License v2.0 only, matching the
#  kernel tree this ships with.  Components it downloads or drives keep
#  their own licences; see kvm_manager/README.md.
#
#  Install:   ./kvm-vm.sh install          -> /usr/local/bin/ckvm
#  Then:      ckvm create ubuntu26
#             ckvm start ubuntu26
#             ckvm list
#             ckvm enable ubuntu26          -> systemd autostart
#
#  Multi-VM: each guest lives in its own directory under $CKVM_ROOT and has
#  its own disk, firmware copy, seed and TCP port.
#
#  Two hardware facts are baked in; see kvm_manager/TECHNICAL.md sections 5
#  and 12 for the measurements:
#   * QEMU must not be migrated between the big and little clusters while it
#     initialises vCPUs - the feature registers differ and KVM answers EINVAL
#     ("Failed to put registers after init").  It is therefore started pinned
#     to a single core and widened to the chosen core set afterwards.
#   * The firmware must be the NVRAM-free EDK2 build, otherwise the guest
#     wedges as soon as the firmware writes its variable store.
# =============================================================================
set -u

CKVM_VERSION="1.8"
# 1.8: the mirror picker measures throughput on a 13MB Packages.gz, not
#      latency on a 130KB Release file.  The latency version picked
#      aliyun (lowest ping, slowest mirror) over tuna.
# 1.7: 'ckvm mirror' switches the container's apt sources to the fastest
#      candidate (each timed first), and ensure_deps does it automatically
#      before installing.  Also fixes the apt package names.
# 1.6: dependencies are checked (and installed) up front, and
#      'CC_LEN: unbound variable' no longer aborts the interactive create.
# 1.5: host/tap mode waits for the SSH banner, not just the serial login
#      prompt.  sshd accepts connections a few seconds before it can
#      authenticate, so an immediate ssh got 'Permission denied'.
# 1.3: 'ckvm selftest' boots a throwaway guest to prove the install works.
# 1.2: the core choice is explicit and defaults to ALL cores --cores all|big.
# 1.1: qemu starts pinned to BOOT_CPU and its threads are widened to
#      CPUSET once the guest is up.  Before this, a CPUSET spanning
#      both clusters made QEMU fail at startup about 4 times in 5
#      ("Failed to put registers after init"); now it is reliable and
#      all 8 physical cores are usable (about 2.6x sha256 throughput
#      over the 2-core default, for 8-12s more boot time).
CKVM_AUTHOR="璀璨梦星 · cuicanmx"
CKVM_HOME="github.com/ccmx200"
# Feature marker: bumped whenever the download-and-install path
# changes meaning.  install() refuses a file that lacks it, so a
# caching mirror serving an old revision is caught instead of
# quietly downgrading the installed ckvm.
CKVM_BUILD="store+ports+aria2+console+bootpin+cores+selftest+deps+aptmirror+throughput"
CKVM_ROOT="${CKVM_ROOT:-/var/lib/ckvm}"
CKVM_FWDIR="${CKVM_FWDIR:-/usr/local/share/ckvm/firmware}"
CKVM_BINDIR="${CKVM_BINDIR:-/usr/local/bin}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
QEMU="${QEMU:-/usr/bin/qemu-system-aarch64}"

# ---- mirrors: NJU for images, USTC for apt; official as the last resort ----
MIRROR_IMAGE_LIST="${MIRROR_IMAGE_LIST:-https://mirror.nju.edu.cn/ubuntu-cloud-images https://cloud-images.ubuntu.com}"
MIRROR_APT="${MIRROR_APT:-https://mirrors.ustc.edu.cn/ubuntu-ports}"

# APT mirrors for the CONTAINER itself (distinct from MIRROR_APT, which goes
# into the guest's cloud-init).  Ordered; the first that answers wins.
# Measured on this device, fetching dists/trixie/Release:
#   deb.debian.org 2.35s   mirror.nju.edu.cn 0.53s   tuna 0.60s
APT_MIRROR_LIST="${APT_MIRROR_LIST:-
https://mirror.nju.edu.cn
https://mirrors.tuna.tsinghua.edu.cn
https://mirrors.aliyun.com
}"
# The package names, not the binary names - `aria2c` is not a package.
CKVM_APT_DEPS="qemu-system-arm qemu-utils cloud-image-utils"

# ---- defaults for a new guest ---------------------------------------------
DEF_CPUS=8
DEF_MEM=2048
DEF_DISK_GB=50
# Physical core sets.  The guest is pinned to one of these:
#   FULL  all 8 cores - 6x Cortex-A55 + 2x Cortex-A76.  Best throughput.
#   BIG   the 2 Cortex-A76 only.  Best single-thread latency.
# Names rather than masks, because the numbers are machine specific and
# nobody should have to remember them.
CORESET_FULL="0-7"
CORESET_BIG="6-7"
DEF_CORES="all"          # all | big

# Derived from DEF_CORES below; kept as a variable so a vm.conf can
# override the mask directly if someone really wants to.
DEF_CPUSET="$CORESET_FULL"
# During vCPU initialisation QEMU must not be migrated between the A55 and
# A76 clusters: the feature registers differ, KVM refuses the write-back and
# QEMU dies with "Failed to put registers after init".  So the process is
# pinned to ONE core while it starts and its affinity is widened to CPUSET
# once the guest is running.  Measured: booting 8 vCPU directly on 0-7 worked
# 1/5 times; with this dance, 5/5.
DEF_BOOT_CPU=6
# Empty means "ask" in interactive mode; command mode falls back to
# "ubuntu" (what the Ubuntu cloud images themselves use).
DEF_USER=""
DEF_PASS=""
DEF_REL=26.04
DEF_PORT_BASE=8023

# ---- networking ---------------------------------------------------------
# NET_MODE=user : QEMU user-mode NAT with explicit hostfwd mappings (default)
# NET_MODE=host : a tap device; the guest gets a real IP on this container's
#                 network and runs its own sshd, no port forwards needed
DEF_NET_MODE=user
DEF_FORWARDS="22"            # guest ports to expose, comma separated
TAP_IP_HOST="172.28.100.1"   # container side of the tap (host mode)
TAP_IP_GUEST="172.28.100.2"  # guest address (host mode)
TAP_NETMASK="24"

# --------------------------------------------------------------------------
# output helpers
# --------------------------------------------------------------------------
say()  { printf '  %s\n' "$*"; }

# a brighter tone for the author line.  NOTE: it must be a literal escape,
# not a "\033" string - printf %s does not interpret escapes.
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    C_AUTHOR=$'\033[38;5;213m'
else
    C_AUTHOR=''
fi

# Shown once at startup so the name and author are always visible.
banner() {
    [ -t 1 ] || return 0
    printf '\n  %sckvm%s %s·%s KVM 虚拟机管理器 %s%s%s\n' \
           "$C_B" "$C_RST" "$C_DIM" "$C_RST" "$C_DIM" "$CKVM_VERSION" "$C_RST"
    printf '  %s作者  %s%s璀璨梦星 · cuicanmx%s   %s%s%s\n\n' \
           "$C_DIM" "$C_RST" "$C_AUTHOR" "$C_RST" "$C_DIM" "$CKVM_HOME" "$C_RST"
}


warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '  ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }

# colour only when it makes sense
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
    C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_C=$'\033[36m'
else
    C_RST=''; C_B=''; C_DIM=''; C_G=''; C_Y=''; C_R=''; C_C=''
fi

# a spinner + progress bar, animated on a terminal and silent when piped
UI_ACTIVE=0
# Run a slow command behind a spinner so it does not look hung.  The command's
# output goes to a temp file; on failure the tail of that file is printed.
#   spin <label> <command...>
#   spin_timed <label> <estimated_seconds> <command...>
_progress() {
    # $1 pid, $2 file, $3 label, $4 total (may be empty)
    local pid="$1" file="$2" lbl="$3" tot="$4"
    local i=0 cur pct
    # /dev/null or a missing path means "no measurable progress"
    case "$file" in /dev/null|"") file="";; esac
    while kill -0 "$pid" 2>/dev/null; do
        cur=0
        [ -n "$file" ] && cur=$(stat -c%s "$file" 2>/dev/null || echo 0)
        if [ -n "$tot" ]; then
            [ "$cur" -gt "$tot" ] && cur="$tot"
            pct=$(( cur * 100 / tot ))
            ui_tick $((i++)) "$pct" "$lbl" \
                    "  $(numfmt --to=iec "$cur" 2>/dev/null || echo "$cur")/$(numfmt --to=iec "$tot" 2>/dev/null || echo "$tot")"
        else
            ui_tick $((i++)) "" "$lbl" \
                    "  $(numfmt --to=iec "$cur" 2>/dev/null || echo "$cur")"
        fi
        sleep 0.4
    done
}

# Run a slow command behind a spinner 
spin() {
    local label="$1"; shift
    if [ "$IS_TTY" != 1 ]; then
        say "$label"
        "$@"
        return $?
    fi
    local out; out=$(mktemp "${TMPDIR:-/tmp}/ckvm-spin.XXXXXX")
    "$@" >"$out" 2>&1 &
    local pid=$!
    _progress "$pid" /dev/null "$label" ""
    wait "$pid"; local rc=$?
    ui_stop
    if [ $rc -ne 0 ]; then
        warn "$label 失败"
        tail -5 "$out" 2>/dev/null | sed 's/^/      /' >&2
    fi
    rm -f "$out"
    return $rc
}

# Same, but shows elapsed against an estimate so a long task feels bounded.
spin_timed() {
    local label="$1" est="$2"; shift 2
    if [ "$IS_TTY" != 1 ]; then
        say "$label"
        "$@"
        return $?
    fi
    local out; out=$(mktemp "${TMPDIR:-/tmp}/ckvm-spin.XXXXXX")
    local t0=$SECONDS
    "$@" >"$out" 2>&1 &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null; do
        local el=$(( SECONDS - t0 ))
        local pct=""
        [ "$est" -gt 0 ] && { pct=$(( el * 100 / est )); [ "$pct" -gt 99 ] && pct=99; }
        ui_tick $((i++)) "$pct" "$label" "  ${el}s"
        sleep 0.4
    done
    wait "$pid"; local rc=$?
    ui_stop
    if [ $rc -ne 0 ]; then
        warn "$label 失败"
        tail -5 "$out" 2>/dev/null | sed 's/^/      /' >&2
    fi
    rm -f "$out"
    return $rc
}

ui_stop() {
    [ "$UI_ACTIVE" = 1 ] || return 0
    printf '\r\033[K' 2>/dev/null
    UI_ACTIVE=0
}
ui_tick() {
    # $1 = frame index, $2 = percent (0-100 or empty), $3 = label, $4 = detail
    local i="$1" pct="$2" label="$3" detail="${4:-}"
    [ -t 1 ] || return 0
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local f="${frames[$((i % ${#frames[@]}))]}"
    local bar=""
    if [ -n "$pct" ]; then
        local width=24 filled=$(( pct * 24 / 100 ))
        local j
        for ((j=0; j<24; j++)); do
            if [ "$j" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
        done
        printf '\r\033[K  %s%s%s %s%s%s  %s%3d%%%s  %s%s%s' \
               "$C_C" "$f" "$C_RST" "$C_G" "$bar" "$C_RST" \
               "$C_B" "$pct" "$C_RST" "$C_DIM$label" "$detail" "$C_RST"
    else
        printf '\r\033[K  %s%s%s %s%s%s' \
               "$C_C" "$f" "$C_RST" "$C_B" "$label" "$C_RST"
    fi
    UI_ACTIVE=1
}

# --------------------------------------------------------------------------
# download engine: aria2c when available (multi-connection), else curl
# --------------------------------------------------------------------------
DL_BACKEND=""
download_pick_backend() {
    if command -v aria2c >/dev/null 2>&1; then
        DL_BACKEND="aria2c"
    else
        DL_BACKEND="curl"
    fi
    echo "$DL_BACKEND"
}

# aria2c is strongly preferred: several connections, resumable
ensure_aria2() {
    command -v aria2c >/dev/null 2>&1 && return 0
    [ "${CKVM_NO_APT:-0}" = 1 ] && return 1
    command -v apt-get >/dev/null 2>&1 || return 1
    say "installing aria2 (multi-connection downloads)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq aria2 >/dev/null 2>&1
    command -v aria2c >/dev/null 2>&1
}

# download_url <url> <outfile> <label>
#
# Progress needs the real total size.  Taking it from the file that aria2c is
# writing does NOT work: aria2 writes segments sparsely, so the file size
# jumps far ahead of the bytes actually fetched and "downloaded / size"
# produces nonsense like 12514%.  So ask the server for Content-Length once,
# then clamp.
download_url() {
    local url="$1" out="$2" label="${3:-downloading}"
    download_pick_backend >/dev/null

    local total=""
    total=$(curl -sSLkI --max-time 25 "$url" 2>/dev/null | \
            awk 'BEGIN{IGNORECASE=1} /^content-length:/{gsub(/\r/,"");print $2}' | tail -1)
    case "$total" in ''|*[!0-9]*) total="" ;; esac

    # already complete?
    if [ -n "$total" ] && [ -f "$out" ] && [ "$(stat -c%s "$out" 2>/dev/null)" = "$total" ]; then
        say "$label: already downloaded"
        return 0
    fi


    if [ "$DL_BACKEND" = "aria2c" ]; then
        # aria2 writes straight into $out unless there is a control file to
        # resume from, in which case it may already span the whole length.
        local watch="$out"
        if [ -e "$out.aria2" ] || [ -e "$out" ]; then
            # fall back to counting the aria2 control file's progress is not
            # exposed, so use the smaller of file size vs total (already
            # clamped) - acceptable because a partial file here is only a
            # truncated previous attempt.
            watch="$out"
        fi
        rm -f "$out.aria2.keep"
        if [ -t 1 ]; then
            aria2c -x16 -s16 -k1M -c \
                   --console-log-level=warn --summary-interval=0 \
                   --show-console-readout=false --allow-overwrite=true \
                   --file-allocation=none \
                   -d "$(dirname "$out")" -o "$(basename "$out")" "$url" \
                   >/tmp/ckvm-aria2.log 2>&1 &
            local pid=$!
            _progress "$pid" "$watch" "$label" "$total"
            wait "$pid"; local rc=$?
            ui_stop
            if [ $rc -ne 0 ] || [ ! -s "$out" ]; then
                warn "aria2c failed for $url"
                tail -2 /tmp/ckvm-aria2.log 2>/dev/null | sed 's/^/      /' >&2
                rm -f "$out" "$out.aria2"
                return 1
            fi
            rm -f "$out.aria2"
            return 0
        fi
        aria2c -x16 -s16 -k1M -c --console-log-level=warn \
               --summary-interval=0 --file-allocation=none \
               -d "$(dirname "$out")" -o "$(basename "$out")" "$url" \
               >/dev/null 2>&1 && rm -f "$out.aria2" && return 0
        rm -f "$out" "$out.aria2"
        return 1
    fi

    # curl fallback, measured on a .part file so it starts from zero
    if [ -t 1 ]; then
        rm -f "$out.part"
        curl -fSLk --retry 3 -o "$out.part" "$url" 2>/dev/null &
        local pid=$!
        _progress "$pid" "$out.part" "$label" "$total"
        wait "$pid"; local rc=$?
        ui_stop
        [ $rc -eq 0 ] && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
        rm -f "$out.part"
        return 1
    fi
    rm -f "$out.part"
    curl -fSLk --retry 3 -o "$out.part" "$url" 2>/dev/null && \
        mv -f "$out.part" "$out" && return 0
    rm -f "$out.part"
    return 1
}

# small wrapper used by the installer for script + firmware
download_file() {
    local url="$1" out="$2" label="${3:-downloading}"
    download_url "$url" "$out" "$label"
}

# --------------------------------------------------------------------------
# the NVRAM-free EDK2 ships inside Limbo's APK, so it cannot be downloaded;
# we look for it in the places it can plausibly be staged
# --------------------------------------------------------------------------
firmware_candidates() {
    cat <<EOF
$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd
/root/limbo_fw/edk2_qemu_aarch64_nonvram.fd
/sdcard/limbo_fw/edk2_qemu_aarch64_nonvram.fd
/data/local/ckvm/edk2_qemu_aarch64_nonvram.fd
EOF
}

find_firmware() {
    local c
    while read -r c; do
        [ -f "$c" ] && { echo "$c"; return 0; }
    done < <(firmware_candidates)
    return 1
}

install_firmware() {
    local src="$1"
    mkdir -p "$CKVM_FWDIR"
    # installing from the destination itself is a no-op, not an error
    if [ "$(readlink -f "$src")" = "$(readlink -f "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd" 2>/dev/null)" ]; then
        say "firmware already in $CKVM_FWDIR"
        return 0
    fi
    cp -f "$src" "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd"
    local d; d=$(dirname "$src")
    local v
    for v in "$d/edk2_vars.fd" /root/limbo_fw/edk2_vars.fd; do
        [ -f "$v" ] && { cp -f "$v" "$CKVM_FWDIR/edk2_vars.fd"; break; }
    done
    say "firmware installed into $CKVM_FWDIR"
}


# Tools ckvm shells out to.  qemu-img and cloud-localds are easy to miss on a
# minimal container and were previously only discovered mid-create, after the
# image had already been downloaded.
# Required: ckvm cannot work without these.
CKVM_DEPS="qemu-system-aarch64 qemu-img cloud-localds"
CKVM_APT_DEPS="qemu-system-arm qemu-utils cloud-image-utils"
# Nice to have; things degrade gracefully without them, so they are only
# reported, never fatal.
CKVM_SOFT_DEPS="aria2c openssl python3 numfmt"

# The package names differ between distros; resolve what apt actually has.
ckvm_apt_packages() {
    local out="" p
    for p in $CKVM_APT_DEPS; do
        out="$out $p"
    done
    echo "${out# }"
}

deps_missing() {
    local d out=""
    for d in $CKVM_DEPS; do
        command -v "$d" >/dev/null 2>&1 || out="$out $d"
    done
    echo "${out# }"
}


# ---------------------------------------------------------------------------
# apt mirror
# ---------------------------------------------------------------------------

apt_sources_file() {
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        echo /etc/apt/sources.list.d/debian.sources; return 0
    fi
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        echo /etc/apt/sources.list.d/ubuntu.sources; return 0
    fi
    [ -f /etc/apt/sources.list ] && { echo /etc/apt/sources.list; return 0; }
    return 1
}

# Download the Release file from a mirror and time it.  Prints "<seconds>"
# on success; fails otherwise.
# Measure a mirror by downloading a real index and reporting MB/s.
#
# The first version used time_total on the 130KB Release file and so ranked
# mirrors by latency: aliyun won at 0.27s on a link that was slower than the
# alternatives.  Fetch something sizeable and divide.
#
# $1 = base url.  Echoes "<MB/s> <seconds>".  Fails if the mirror does not
# actually serve this suite.
apt_mirror_speed() {
    local base="$1" suite url
    suite=$(apt_suite)
    [ -n "$suite" ] || return 1
    command -v curl >/dev/null 2>&1 || return 1

    # Sample something apt actually fetches and that is big enough for the
    # number to mean bandwidth rather than round-trip time.  Packages.gz in
    # main/binary-<arch> is ~13 MB here.  (Contents-arm64.gz sounded better
    # but is 146 bytes on these mirrors, so it measured nothing - the same
    # mistake as timing the 130KB Release file.)
    local arch; arch=$(dpkg --print-architecture 2>/dev/null || echo arm64)
    for cand in \
        "dists/$suite/main/binary-$arch/Packages.gz" \
        "dists/$suite/main/binary-all/Packages.gz" \
        "dists/$suite/main/dep11/Components-$arch.yml.gz"
    do
        url="$base/debian/$cand"
        local out
        out=$(curl -sL -m 30 -o /dev/null \
                  -w '%{http_code} %{size_download} %{time_total}' "$url" 2>/dev/null) || continue
        set -- $out
        [ "${1:-0}" = 200 ] || continue
        local bytes="${2:-0}" secs="${3:-0}"
        # below ~1 MB the measurement is noise, not bandwidth
        [ "$bytes" -gt 1000000 ] 2>/dev/null || continue
        awk -v b="$bytes" -v t="$secs" \
            'BEGIN{ if (t > 0) printf "%.2f %.2f\n", (b/1048576)/t, t; else exit 1 }' \
            || continue
        return 0
    done
    return 1
}

apt_suite() {
    local c
    c=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | tr -d '"')
    [ -n "$c" ] && { echo "$c"; return 0; }
    # fall back to what the sources already say
    local f; f=$(apt_sources_file) || return 1
    sed -n 's/^Suites:[[:space:]]*\([^ ]*\).*/\1/p' "$f" 2>/dev/null | head -1
}

# Rewrite every URIs: line to point at $1, keeping the rest of each stanza
# (Suites, Components, Signed-By) untouched.
apt_apply_mirror() {
    local base="$1" f
    f=$(apt_sources_file) || return 1
    [ -f "$f.ckvm.bak" ] || cp -f "$f" "$f.ckvm.bak" 2>/dev/null

    # One awk pass, because two seds do not work: the first would rewrite
    # every URIs line to /debian and destroy the "security" token the second
    # was matching on, leaving "Suites: trixie-security" pointed at /debian.
    #
    # Handles both layouts:
    #   deb822    URIs: http://deb.debian.org/debian-security
    #   one-line  deb http://deb.debian.org/debian trixie main
    awk -v base="$base" '
        /^URIs:/ {
            if ($0 ~ /security/) print "URIs: " base "/debian-security";
            else                 print "URIs: " base "/debian";
            next
        }
        /^deb[[:space:]]/ {
            out = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^https?:\/\//) {
                    if ($i ~ /security/) out = out " " base "/debian-security";
                    else                 out = out " " base "/debian";
                } else {
                    out = out " " $i;
                }
            }
            sub(/^ /, "", out);
            print out;
            next
        }
        { print }
    ' "$f" > "$f.ckvm.new" && mv -f "$f.ckvm.new" "$f"
    return 0
}

# What the sources point at now.
apt_current_mirror() {
    local f; f=$(apt_sources_file) || return 0
    sed -n 's#^URIs:[[:space:]]*\(https\?://[^/]*\).*#\1#p' "$f" 2>/dev/null | head -1
}

# -cn / --mirror: try the list, keep the fastest that answers.
ask_apt_mirror() {
    need_root
    local f base best="" bestt=""
    f=$(apt_sources_file) || die "找不到 apt 源文件"
    local suite; suite=$(apt_suite)
    say "apt 源文件: $f"
    say "当前源:    $(apt_current_mirror)"
    say "发行版:    $(sed -n 's/^ID=//p' /etc/os-release) / ${suite:-unknown}"
    echo
    say "测速中（下载一个几 MB 的索引，算真实吞吐）..."
    say "  源                                         吞吐     耗时"
    for base in $APT_MIRROR_LIST; do
        local res t s_
        if res=$(apt_mirror_speed "$base"); then
            t=$(echo "$res" | awk '{print $1}')
            s_=$(echo "$res" | awk '{print $2}')
            printf '  %-42s %6s MB/s  %ss\n' "$base" "$t" "$s_"
            if [ -z "$bestt" ] || awk -v a="$t" -v b="$bestt" 'BEGIN{exit !(a>b)}'; then
                best="$base"; bestt="$t"
            fi
        else
            printf '  %-42s %s\n' "$base" "不可用（没有该发行版的索引）"
        fi
    done
    echo
    [ -n "$best" ] || die "没有可用的镜像"
    apt_apply_mirror "$best" || die "写入失败"
    say "已切换到: $best  (${bestt} MB/s)"
    say "备份:     $f.ckvm.bak"
    echo
    spin "apt update" apt-get update -qq || warn "apt update 失败"
    say "完成。恢复原源: ckvm mirror --restore"
}

ask_apt_mirror_restore() {
    need_root
    local f; f=$(apt_sources_file) || die "找不到 apt 源文件"
    [ -f "$f.ckvm.bak" ] || die "没有备份可恢复 ($f.ckvm.bak)"
    mv -f "$f.ckvm.bak" "$f"
    say "已恢复: $f"
    spin "apt update" apt-get update -qq || warn "apt update 失败"
}

ensure_deps() {
    local missing; missing=$(deps_missing)
    [ -n "$missing" ] || return 0
    if command -v apt-get >/dev/null 2>&1; then
        say "安装缺少的依赖: $missing"
        # Switch to a nearby mirror first: the stock deb.debian.org took 2.35s
        # per index file here versus 0.53s for mirror.nju.edu.cn.
        if [ "${CKVM_NO_APT_MIRROR:-0}" != 1 ]; then
            local cur t
            cur=$(apt_current_mirror)
            case "$cur" in
                *deb.debian.org*|*archive.ubuntu.com*|*security.ubuntu.com*|"")
                    t=$(apt_mirror_speed "$(echo "$APT_MIRROR_LIST" | head -1)" 2>/dev/null) \
                        && { apt_apply_mirror "$(echo "$APT_MIRROR_LIST" | head -1)"; \
                             say "已换用更快的 apt 源（原源: ${cur:-未知}）"; } ;;
            esac
        fi
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $CKVM_APT_DEPS \
            >/dev/null 2>&1 || true
    fi
    missing=$(deps_missing)
    if [ -n "$missing" ]; then
        printf '  ERROR: 缺少必需依赖: %s\n' "$missing" >&2
        printf '         装一下: apt-get install -y %s\n' "$(ckvm_apt_packages)" >&2
        printf '         或者先跑: ckvm selftest  看看环境缺什么\n' >&2
        return 1
    fi
    # soft deps: mention once, do not block
    local soft="" d
    for d in $CKVM_SOFT_DEPS; do
        command -v "$d" >/dev/null 2>&1 || soft="$soft $d"
    done
    [ -n "$soft" ] && warn "缺少可选工具:${soft}（功能会降级，不影响创建）"
    return 0
}

check_firmware() {
    [ -f "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd" ] && return 0
    local src; src=$(find_firmware) || {
        cat >&2 <<EOF
  ERROR: the NVRAM-free EDK2 firmware was not found.

  It is not in any git repo - Limbo ships it inside its APK - so ckvm
  cannot download it.  Put it in one of these places:

    $CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd
    /root/limbo_fw/edk2_qemu_aarch64_nonvram.fd
    /sdcard/limbo_fw/edk2_qemu_aarch64_nonvram.fd

  From Termux (root) on this device:

    su -c 'mkdir -p /sdcard/limbo_fw && cp \\
      /data/data/com.limbo.emu.main.arm/cache/limbo/edk2/*.fd /sdcard/limbo_fw/'
    su -c 'cp /sdcard/limbo_fw/edk2_qemu_aarch64_nonvram.fd $CKVM_FWDIR/'
    su -c 'cp /sdcard/limbo_fw/edk2_vars.fd                 $CKVM_FWDIR/'
EOF
        return 1
    }
    install_firmware "$src"
}

# --------------------------------------------------------------------------
# guest bookkeeping
# --------------------------------------------------------------------------
vm_dir()  { echo "$CKVM_ROOT/$1"; }
vm_conf() { echo "$CKVM_ROOT/$1/vm.conf"; }
vm_pid()  { echo "$CKVM_ROOT/$1/qemu.pid"; }
vm_log()  { echo "$CKVM_ROOT/$1/serial.log"; }

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] || die "invalid name: $1"; }
exists_vm()  { [ -d "$(vm_dir "$1")" ]; }

load_vm() {
    local n="$1"
    [ -n "$n" ] || die "a guest name is required (see: ckvm list)"
    case "$n" in
        -*) die "'$n' looks like an option, not a guest name (see: ckvm list)" ;;
    esac
    local d; d=$(vm_dir "$n")
    [ -f "$d/vm.conf" ] || die "no such guest: $n  (see: ckvm list)"
    # shellcheck disable=SC1090
    . "$d/vm.conf"
}

next_port() {
    local used p
    used=$(grep -hs '^PORT=' "$CKVM_ROOT"/*/vm.conf 2>/dev/null | cut -d= -f2 | tr '\n' ' ')
    p=$DEF_PORT_BASE
    while :; do
        case " $used " in *" $p "*) p=$((p+1));; *) echo "$p"; return;; esac
    done
}

running_pid() {
    local f; f=$(vm_pid "$1")
    [ -f "$f" ] || return 1
    local p; p=$(cat "$f" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { echo "$p"; return 0; }
    return 1
}

# --------------------------------------------------------------------------
# networking helpers
# --------------------------------------------------------------------------
# FORWARDS is a comma separated list of guest ports.  Each is published on the
# host on the same number by default, or on "hostport:guestport" if given.
# Port 22 is special-cased: it is published as PORT unless overridden.
build_hostfwd() {
    local list="${FORWARDS:-22}" item h g out=""
    local IFS=','
    for item in $list; do
        case "$item" in
            *:*) h="${item%%:*}"; g="${item#*:}" ;;
            *)   g="$item";       h="$item" ;;
        esac
        # 22 maps onto our allocated PORT so several guests can coexist
        [ "$g" = "22" ] && h="$PORT"
        out="$out,hostfwd=tcp:0.0.0.0:${h}-:${g}"
    done
    echo "${out#,}"
}

check_host_port() {
    local p="$1"
    ss -tln 2>/dev/null | grep -q ":$p " && return 1
    return 0
}

# Describe whatever is listening on a host port, to make a clash actionable.
port_owner() {
    local p="$1" pid comm name
    # our own guest?
    local d
    for d in "$CKVM_ROOT"/*/; do
        [ -f "$d/vm.conf" ] || continue
        ( . "$d/vm.conf"
          case "${FORWARDS:-}" in
              *"$p"*|*":$p"*) printf '%s' "ckvm guest '$(basename "$d")'"; exit 0 ;;
          esac
          [ "${PORT:-}" = "$p" ] && { printf '%s' "ckvm guest '$(basename "$d")'"; exit 0; }
        )
    done
    # someone else?
    pid=$(ss -tlnp 2>/dev/null | awk -v P=":$p " '$4 ~ P {print $NF}' \
          | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    if [ -n "$pid" ]; then
        comm=$(cat "/proc/$pid/comm" 2>/dev/null)
        name=$(tr -d '\0' < "/proc/$pid/cmdline" 2>/dev/null | cut -d '' -f1)
        printf '%s' "pid $pid (${comm:-${name:-unknown}})"
        return 0
    fi
    printf '%s' ""
}

tap_name() { echo "ckvm-$1" | cut -c1-15; }

tap_up() {
    local name="$1" tap; tap=$(tap_name "$name")
    command -v ip >/dev/null || { warn "iproute2 missing; cannot use host networking"; return 1; }
    [ -c /dev/net/tun ] || { warn "/dev/net/tun missing; cannot use host networking"; return 1; }

    ip link show "$tap" >/dev/null 2>&1 && ip link del "$tap" 2>/dev/null
    ip tuntap add dev "$tap" mode tap || { warn "cannot create $tap"; return 1; }
    ip addr add "${TAP_IP_HOST}/${TAP_NETMASK}" dev "$tap" 2>/dev/null
    ip link set "$tap" up || return 1

    # let the guest reach the outside world
    sysctl -qw net.ipv4.ip_forward=1 2>/dev/null
    iptables -t nat -C POSTROUTING -s "${TAP_IP_GUEST}/${TAP_NETMASK}" \
        -o eth0 -j MASQUERADE 2>/dev/null \
        || iptables -t nat -A POSTROUTING -s "${TAP_IP_GUEST}/${TAP_NETMASK}" \
        -o eth0 -j MASQUERADE 2>/dev/null
    iptables -C FORWARD -i "$tap" -j ACCEPT 2>/dev/null \
        || iptables -I FORWARD -i "$tap" -j ACCEPT 2>/dev/null
    echo "$tap"
    return 0
}

tap_down() {
    local name="$1" tap; tap=$(tap_name "$name")
    iptables -t nat -D POSTROUTING -s "${TAP_IP_GUEST}/${TAP_NETMASK}" \
        -o eth0 -j MASQUERADE 2>/dev/null
    iptables -D FORWARD -i "$tap" -j ACCEPT 2>/dev/null
    ip link del "$tap" 2>/dev/null
    return 0
}

image_urls() {
    local rel="$1" f="ubuntu-${rel}-server-cloudimg-arm64.img" m
    for m in $MIRROR_IMAGE_LIST; do
        echo "$m/releases/${rel}/release/$f"
    done
}

# --------------------------------------------------------------------------
# release catalogue ("app store")
# --------------------------------------------------------------------------
# version|codename|LTS|size
CATALOGUE="22.04|jammy|LTS|673M
22.10|kinetic||716M
23.04|lunar||688M
23.10|mantic||684M
24.04|noble|LTS|592M
24.10|oracular||584M
25.04|plucky||680M
25.10|questing||843M
26.04|resolute|LTS|902M"

catalogue_versions() { echo "$CATALOGUE" | cut -d'|' -f1; }

catalogue_field() {
    echo "$CATALOGUE" | awk -F'|' -v v="$1" '$1==v{print $'"$2"'}'
}

# Is this release actually downloadable from any configured mirror?
# Sets CC_URL on success.
check_release() {
    local rel="$1" url len
    for url in $(image_urls "$rel"); do
        len=$(curl -sSLkI --max-time 20 "$url" 2>/dev/null | \
              awk 'BEGIN{IGNORECASE=1}/^content-length:/{gsub(/\r/,"");print $2}' | tail -1)
        case "$len" in ''|*[!0-9]*) continue ;; esac
        CC_URL="$url"
        CC_LEN="$len"
        return 0
    done
    return 1
}

# --------------------------------------------------------------------------
# interactive prompt helpers
# --------------------------------------------------------------------------
IS_TTY=0
[ -t 0 ] && [ -t 1 ] && IS_TTY=1

# ask_with_default <prompt> <default>  -> echoes the answer
ask_with_default() {
    local prompt="$1" def="$2" ans=""
    if [ "$IS_TTY" = 1 ]; then
        printf '  %s %s[%s]%s: ' "$prompt" "$C_DIM" "$def" "$C_RST" >&2
        IFS= read -r ans || ans=""
    fi
    [ -z "$ans" ] && ans="$def"
    printf '%s' "$ans"
}

# Ask for a password without echoing.  Empty input keeps the default.
ask_password() {
    local prompt="$1" def="$2" ans=""
    if [ "$IS_TTY" != 1 ]; then
        printf '%s' "$def"
        return 0
    fi
    if [ -n "$def" ]; then
        printf '  %s [留空则用 %s]: ' "$prompt" "$def" >&2
    else
        printf '  %s: ' "$prompt" >&2
    fi
    IFS= read -rs ans 2>/dev/null || ans=""
    printf '\n' >&2
    [ -z "$ans" ] && ans="$def"
    printf '%s' "$ans"
}

# Ask which account to log in as.  Echoes "root" or the chosen user name.
ask_account() {
    [ "$IS_TTY" = 1 ] || { printf '%s' "${DEF_USER:-ubuntu}"; return 0; }
    printf '\n' >&2
    printf '  %s登录账号%s\n' "$C_B" "$C_RST" >&2
    printf '  %s────────%s\n' "$C_DIM" "$C_RST" >&2
    printf '    输入 %sroot%s   直接用 root 登录（会设置 root 密码）\n' "$C_G" "$C_RST" >&2
    printf '    输入其他名字    新建一个带 sudo 的普通用户\n' >&2
    printf '    直接回车        用 %s%s%s\n' "$C_C" "${DEF_USER:-ubuntu}" "$C_RST" >&2
    printf '\n' >&2
    ask_with_default "账号名:" "${DEF_USER:-ubuntu}"
}

confirm_yn() {
    local prompt="$1" def="${2:-n}" ans=""
    [ "$IS_TTY" = 1 ] || { [ "$def" = y ]; return; }
    printf '  %s (y/n) [%s]: ' "$prompt" "$def" >&2
    IFS= read -r ans || ans=""
    [ -z "$ans" ] && ans="$def"
    case "$ans" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# Interactive release picker.  Echoes the chosen version, or nothing if the
# user cancels.
pick_release() {
    local n=0 line ver code lts size mark
    printf '\n' >&2
    printf '  %sUbuntu 版本%s\n' "$C_B" "$C_RST" >&2
    printf '  %s──────  ────────────  ─────  ────────%s\n' "$C_DIM" "$C_RST" >&2
    while IFS='|' read -r ver code lts size; do
        [ -n "$ver" ] || continue
        n=$((n + 1))
        if [ "$lts" = "LTS" ]; then
            mark="${C_G}LTS${C_RST}"
        else
            mark="${C_DIM}   ${C_RST}"
        fi
        printf '  %s%2d)%s %-8s %s%-12s%s %s %8s\n' \
               "$C_C" "$n" "$C_RST" "$ver" "$C_DIM" "$code" "$C_RST" \
               "$mark" "$size" >&2
    done <<EOF
$CATALOGUE
EOF
    printf '  %s 0)%s 取消\n\n' "$C_C" "$C_RST" >&2

    local pick=""
    while :; do
        printf '  选择 [1-%d] (默认 %s): ' "$n" "$DEF_REL" >&2
        IFS= read -r pick || { printf '\n' >&2; return 1; }
        [ -z "$pick" ] && pick="$DEF_REL"
        # accept a number
        case "$pick" in
            0) return 1 ;;
            *[!0-9]*) ;;
            *)
                if [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ]; then
                    sed -n "${pick}p" <<EOF
$CATALOGUE
EOF
                    return 0
                fi
                printf '  %s请输入 0 到 %d%s\n' "$C_Y" "$n" "$C_RST" >&2
                continue
                ;;
        esac
        # accept a version string (22.04, 24.04.1, ...)
        ver=$(echo "$pick" | grep -oE '^[0-9]+\.[0-9]+')
        if [ -n "$ver" ] && catalogue_field "$ver" 1 >/dev/null 2>&1 \
           && [ -n "$(catalogue_field "$ver" 1)" ]; then
            echo "$(catalogue_field "$ver" 1)|$(catalogue_field "$ver" 2)|$(catalogue_field "$ver" 3)|$(catalogue_field "$ver" 4)"
            return 0
        fi
        printf '  %s没有这个版本：%s%s\n' "$C_Y" "$pick" "$C_RST" >&2
    done
}

# Explain the forward syntax once, before asking for it.
explain_forwards() {
    printf '\n' >&2
    printf '  %s端口映射怎么写%s\n' "$C_B" "$C_RST" >&2
    printf '  %s────────────────%s\n' "$C_DIM" "$C_RST" >&2
    printf '    用逗号分隔。写一个数字表示「guest 和宿主机同号」，\n' >&2
    printf '    写 %shost:guest%s 表示「guest 的某端口映射到宿主机的另一个端口」。\n' "$C_DIM" "$C_RST" >&2
    printf '\n' >&2
    printf '    %s22%s            guest 的 22  →  该虚拟机自己的 %sPORT%s（%s）\n' \
           "$C_G" "$C_RST" "$C_C" "$C_RST" "$DEF_PORT_BASE 起自动分配" >&2
    printf '    %s22,80,443%s    再加 80 和 443，同号映射\n' "$C_G" "$C_RST" >&2
    printf '    %s22,8080:80%s   guest 的 80 映射到宿主机的 8080\n' "$C_G" "$C_RST" >&2
    printf '    %s22,2222:22%s   再额外把 22 也暴露到 2222（可选）\n' "$C_G" "$C_RST" >&2
    printf '\n' >&2
    printf '    %s注意%s 宿主机端口不能重复占用；容器自己的 sshd 在 22，\n' \
           "$C_Y" "$C_RST" >&2
    printf '    所以 guest 的 22 默认不会占用宿主机的 22。\n' >&2
    printf '\n' >&2
}

# --------------------------------------------------------------------------
# create
# --------------------------------------------------------------------------
make_seed() {
    local name="$1" d
    d=$(vm_dir "$name")
    load_vm "$name"
    local hash; hash=$(openssl passwd -6 "$VM_PASS")

    # Ubuntu's cloud images ship
    #   /etc/ssh/sshd_config.d/60-cloudimg-settings.conf   (PasswordAuthentication no)
    # and sshd_config Includes that directory in alphabetical order, so it wins
    # over cloud-init's own 50-cloud-init.conf and root password login is
    # refused even when a password is set (verified: `sshd -T` reported
    # permitrootlogin prohibit-password).
    #
    # The fix is written by a script rather than an inline runcmd: quoting a
    # shell command inside cloud-init YAML mangled the file badly.
    local sshfix
    sshfix='write_files:
  - path: /usr/local/sbin/ckvm-ssh-fix
    permissions: "0755"
    content: |
      #!/bin/sh
      # Let root log in with a password (Ubuntu cloud images forbid it).
      sed -i -e "/^PasswordAuthentication/d" \
             -e "/^KbdInteractiveAuthentication/d" \
             /etc/ssh/sshd_config.d/60-cloudimg-settings.conf 2>/dev/null || true
      d=/etc/ssh/sshd_config.d/99-ckvm-root.conf
      printf "%s\n" "PermitRootLogin yes" > "$d"
      printf "%s\n" "PasswordAuthentication yes" >> "$d"
      printf "%s\n" "KbdInteractiveAuthentication yes" >> "$d"
      # Host keys can exist but be EMPTY.  On a real 22.04 guest all three
      # were 0 bytes and created before cloud-init ran, so cloud-init skipped
      # generating them and sshd exited with
      #     sshd: no hostkeys available -- exiting.
      # ssh-keygen -A never overwrites an existing file, empty or not.
      rm -f /etc/ssh/ssh_host_rsa_key /etc/ssh/ssh_host_rsa_key.pub
      rm -f /etc/ssh/ssh_host_ecdsa_key /etc/ssh/ssh_host_ecdsa_key.pub
      rm -f /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub
      ssh-keygen -A >/dev/null 2>&1 || true
      rm -rf /run/sshd
      mkdir -p /run/sshd
      chmod 0755 /run/sshd
      systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
runcmd:
  - [ /usr/local/sbin/ckvm-ssh-fix ]'

    if [ "$VM_USER" = "root" ]; then
        # root-only guest: no extra account
        cat > "$d/user-data" <<EOF
#cloud-config
hostname: $VM_HOSTNAME
manage_etc_hosts: true
ssh_pwauth: true
disable_root: false
ssh:
  allow-pw: true
  permit_root_login: true
chpasswd:
  expire: false
  users:
    - {name: root, password: $hash, type: hash}
$sshfix
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
apt:
  primary:
    - arches: [default]
      uri: "$MIRROR_APT"
  security:
    - arches: [default]
      uri: "$MIRROR_APT"
package_update: false
package_upgrade: false
EOF
    else
        cat > "$d/user-data" <<EOF
#cloud-config
hostname: $VM_HOSTNAME
manage_etc_hosts: true
users:
  - name: $VM_USER
    gecos: $VM_USER
    groups: [sudo, adm]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: $hash
ssh_pwauth: true
disable_root: false
ssh:
  allow-pw: true
chpasswd:
  expire: false
  users:
    - {name: root, password: $hash, type: hash}
$sshfix
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
apt:
  primary:
    - arches: [default]
      uri: "$MIRROR_APT"
  security:
    - arches: [default]
      uri: "$MIRROR_APT"
package_update: false
package_upgrade: false
EOF
    fi

    cat > "$d/meta-data" <<EOF
instance-id: ckvm-$name
local-hostname: $VM_HOSTNAME
EOF

    if [ "${NET_MODE:-user}" = "host" ] || [ "${NET_MODE:-user}" = "tap" ]; then
        cat > "$d/network-config" <<EOF
version: 2
ethernets:
  main:
    match:
      name: "en*"
    dhcp4: false
    addresses: [${TAP_IP_GUEST}/${TAP_NETMASK}]
    routes:
      - to: default
        via: ${TAP_IP_HOST}
    nameservers:
      addresses: [223.5.5.5, 119.29.29.29]
EOF
        spin "生成 cloud-init 镜像" cloud-localds \
             --network-config="$d/network-config" \
             "$d/seed.img" "$d/user-data" "$d/meta-data"
    else
        spin "生成 cloud-init 镜像" cloud-localds \
             "$d/seed.img" "$d/user-data" "$d/meta-data"
    fi
    if [ "$VM_USER" = "root" ]; then
        say "seed.img written (root / password $VM_PASS)"
    else
        say "seed.img written (user $VM_USER / password $VM_PASS, root 同密码)"
    fi
}

fetch_image() {
    local name="$1" d img url ok=0 fmt
    d=$(vm_dir "$name"); img="$d/disk.qcow2"
    load_vm "$name"
    ensure_aria2 >/dev/null 2>&1 || true
    for url in $(image_urls "$UBUNTU_REL"); do
        say "source: $url"
        if download_url "$url" "$d/base.img" "Ubuntu $UBUNTU_REL arm64"; then
            ok=1; break
        fi
        say "  mirror failed, trying the next one"
    done
    [ "$ok" = 1 ] || return 1
    fmt=$(qemu-img info --output=json "$d/base.img" | \
          python3 -c "import sys,json;print(json.load(sys.stdin)['format'])" 2>/dev/null || echo raw)
    if [ "$fmt" = "qcow2" ]; then
        mv -f "$d/base.img" "$img"
    else
        spin "转换镜像格式 ($fmt -> qcow2)" \
             qemu-img convert -f "$fmt" -O qcow2 "$d/base.img" "$img"
        rm -f "$d/base.img"
    fi
    spin "扩容到 ${DISK_GB}G" qemu-img resize "$img" "${DISK_GB}G"
    say "image ready"
    return 0
}

# ckvm create [name] [options]
#   no arguments and a terminal -> the interactive store
#   a name, or any option  -> command mode
cmd_create() {
    need_root

    local name="" cpus="" mem="" disk="" rel="" port=""
    local net_mode="" forwards="" fwd_set=0
    local vm_user="" vm_pass=""
    local cores=""
    local interactive=0

    # decide the mode first: bare "ckvm create" on a TTY is interactive
    if [ $# -eq 0 ] && [ "$IS_TTY" = 1 ]; then
        interactive=1
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --cpus) cpus="$2"; shift 2 ;;
            --cores) cores="$2"; shift 2 ;;
            --mem)  mem="$2";  shift 2 ;;
            --disk) disk="$2"; shift 2 ;;
            --rel)  rel="$2";  shift 2 ;;
            --port) port="$2"; shift 2 ;;
            --net)  net_mode="$2"; shift 2 ;;
            --fwd)  forwards="$2"; fwd_set=1; shift 2 ;;
            --user) vm_user="$2"; shift 2 ;;
            --pass) vm_pass="$2"; shift 2 ;;
            -i|--interactive) interactive=1; shift ;;
            *)      name="$1"; shift ;;
        esac
    done

    printf '\n'
    printf '  %sckvm%s  ·  创建 Ubuntu 虚拟机\n' "$C_B" "$C_RST"
    printf '  %s────────────────────────────%s\n' "$C_DIM" "$C_RST"

    # ---------------- interactive flow ----------------
    if [ "$interactive" = 1 ]; then
        local chosen
        chosen=$(pick_release) || { say "已取消"; return 0; }
        rel=$(echo "$chosen" | cut -d'|' -f1)
        local code lts size
        code=$(echo "$chosen" | cut -d'|' -f2)
        lts=$(echo "$chosen" | cut -d'|' -f3)
        size=$(echo "$chosen" | cut -d'|' -f4)
        say "选择：Ubuntu $rel $code ${lts:+($lts)}  ~$size"

        printf '\n'
        name=$(ask_with_default "虚拟机名字:" "ubuntu${rel%%.*}$(echo "$rel" | cut -d. -f2)")
        cpus=$(ask_with_default "vCPU 数量:" "$DEF_CPUS")
        printf '  %s物理核心:%s  %s1)%s 全部 8 核（6×A55 + 2×A76，吞吐优先）\n' \
               "$C_DIM" "$C_RST" "$C_B" "$C_RST"
        printf '             %s2)%s 仅 2 个大核（A76，单核延迟优先）\n' "$C_B" "$C_RST"
        local core_ans
        core_ans=$(ask_with_default "选择 [1/2]:" "1")
        case "$core_ans" in
            2|big|BIG|大核) cores="big" ;;
            *)              cores="all" ;;
        esac
        mem=$(ask_with_default "内存 (MiB):" "$DEF_MEM")
        disk=$(ask_with_default "磁盘 (GiB):" "$DEF_DISK_GB")
        net_mode=$(ask_with_default "网络模式 user/host:" "$DEF_NET_MODE")
        if [ "$net_mode" = "user" ]; then
            explain_forwards
            forwards=$(ask_with_default "映射端口:" "$DEF_FORWARDS")
            fwd_set=1
        fi

        # account: root, or a named sudo user; then the password
        vm_user=$(ask_account)
        if [ -z "$vm_pass" ]; then
            local p1 p2
            while :; do
                p1=$(ask_password "密码" "")
                if [ -z "$p1" ]; then
                    printf '  %s密码不能为空%s\n' "$C_Y" "$C_RST" >&2
                    continue
                fi
                p2=$(ask_password "再输一次" "")
                if [ "$p1" = "$p2" ]; then
                    vm_pass="$p1"
                    break
                fi
                printf '  %s两次不一致，重新输入%s\n' "$C_Y" "$C_RST" >&2
            done
        fi
        printf '\n'
    fi

    # ---------------- defaults / validation ----------------
    [ -n "$rel" ]       || rel="$DEF_REL"
    [ -n "$name" ]      || name="ubuntu${rel%%.*}$(echo "$rel" | cut -d. -f2)"
    [ -n "$cpus" ]      || cpus="$DEF_CPUS"
    [ -n "$cores" ]     || cores="$DEF_CORES"
    local cpuset; cpuset=$(cores_to_mask "$cores")
    [ -n "$mem" ]       || mem="$DEF_MEM"
    [ -n "$disk" ]      || disk="$DEF_DISK_GB"
    [ -n "$net_mode" ]  || net_mode="$DEF_NET_MODE"
    [ -n "$forwards" ]  || forwards="$DEF_FORWARDS"
    [ -n "$vm_user" ]   || vm_user="${DEF_USER:-ubuntu}"
    [ -n "$vm_pass" ]   || vm_pass="${DEF_PASS:-ubuntu}"
    case "$vm_user" in
        root) : ;;
        *[!A-Za-z0-9_.-]*|"") die "invalid user name: '$vm_user'" ;;
    esac
    [ -n "$vm_pass" ] || die "password must not be empty"

    # is this release in the catalogue at all?
    if [ -z "$(catalogue_field "$rel" 1)" ]; then
        die "unknown release '$rel'  (available: $(catalogue_versions | tr '\n' ' '))"
    fi
    valid_name "$name"
    if [ -f "$(vm_conf "$name")" ]; then
        die "guest '$name' already exists (use: ckvm rm $name)"
    fi
    case "$net_mode" in
        user|host) ;;
        *) die "--net must be 'user' or 'host'" ;;
    esac
    [ "$net_mode" = "host" ] && [ "$fwd_set" = 0 ] && forwards=""

    # verify the image is really fetchable before creating anything
    # $size comes from the catalogue.  Do NOT use CC_LEN here: check_release
    # sets it, but it runs under `spin` in a subshell so the value never
    # comes back - reading it tripped `set -u` and aborted the create.
    local code lts size
    code=$(catalogue_field "$rel" 2)
    lts=$(catalogue_field "$rel" 3)
    size=$(catalogue_field "$rel" 4)
    if ! spin "检查镜像可用性" check_release "$rel"; then
        warn "目录里没有 $rel 的镜像，可用的源都试过了"
        return 1
    fi
    say "  可用：Ubuntu $rel ($code${lts:+, $lts})${size:+  $size}"

    ensure_deps || return 1
    check_firmware || return 1
    mkdir -p "$(vm_dir "$name")"
    local d; d=$(vm_dir "$name")
    [ -n "$port" ] || port=$(next_port)

    cat > "$d/vm.conf" <<EOF
NAME=$name
UBUNTU_REL=$rel
CPUS=$cpus
MEM=$mem
DISK_GB=$disk
PORT=$port
# Pin to one core type.  big.LITTLE: 6x A55 (0xd05) + 2x A76 (0xd0b) expose
# different ID registers, and an unpinned QEMU gets EINVAL when it writes
# them back.  Cores 6,7 are the A76 pair.
# Core choice: all cores (default) or just the big ones.
CPUSET=$cpuset
BOOT_CPU=${BOOT_CPU:-$DEF_BOOT_CPU}
VM_USER=$vm_user
VM_PASS=$vm_pass
VM_HOSTNAME=$name
NET_MODE=$net_mode
FORWARDS=$forwards
EOF

    cp -f "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd" "$d/uefi-code.fd"
    [ -f "$CKVM_FWDIR/edk2_vars.fd" ] || die "missing edk2_vars.fd in $CKVM_FWDIR"
    cp -f "$CKVM_FWDIR/edk2_vars.fd" "$d/uefi-vars.fd"

    printf '\n'
    say "已创建 '$name'  (Ubuntu $rel, $port 端口, ${cpus} vCPU, ${mem} MiB, ${disk}G)"
    say "network: $net_mode${forwards:+ (forwards: $forwards)}"
    say "download backend: $(download_pick_backend)"

    if [ -s "$d/disk.qcow2" ] && qemu-img info "$d/disk.qcow2" >/dev/null 2>&1; then
        say "磁盘已存在，跳过下载"
        spin "扩容到 ${disk}G" qemu-img resize "$d/disk.qcow2" "${disk}G" \
            || { warn "扩容失败"; return 1; }
    else
        fetch_image "$name" || { warn "镜像下载失败；稍后可跑 'ckvm image $name'"; return 1; }
    fi
    make_seed "$name"
    say "物理核心: $(cores_to_label "$cpuset")"
    printf '\n'
    say "启动： ckvm start $name"
}

cmd_help_ports() {
    cat <<'EOF'
端口映射（--fwd / 交互式里的「映射端口」）

  格式：逗号分隔的列表，每一项是

      <guest端口>            宿主机同号映射
      <宿主机端口>:<guest端口>   映射到指定端口

  规则

    · guest 的 22 是个特例：它映射到这台虚拟机自己的 --port
      （默认从 8023 起自动分配），所以多开时不会互相抢端口，
      也不会占用容器自己的 22。
    · 其他端口默认同号映射。
    · 启动前会检查宿主机端口是否已被占用并给出提示。

  例子

    --fwd 22              只暴露 ssh（guest 22 -> 该机的 PORT）
    --fwd 22,80,443       ssh 加上 80 和 443（同号）
    --fwd 22,8080:80      guest 的 80 -> 宿主机 8080
    --fwd 22,2222:22      额外再把 guest 22 暴露到 2222
    --fwd 22,3306:3306,6379:6379   mysql 和 redis

  如果改用 --net host，guest 会拿到自己的 IP 并自己跑 sshd，
  这时不需要任何端口映射。

  相关：ckvm net <名字>   查看某台虚拟机实际生效的映射
EOF
}

# Always a plain listing.  The interactive picker lives in `ckvm create`,
# so calling versions from a script must never block on stdin.
cmd_versions() {
    printf '  %-8s %-12s %-5s %s\n' VERSION CODENAME LTS SIZE
    while IFS='|' read -r ver code lts size; do
        [ -n "$ver" ] || continue
        printf '  %-8s %-12s %-5s %s\n' "$ver" "$code" "${lts:-}" "$size"
    done <<EOF
$CATALOGUE
EOF
}

cmd_image() {
    need_root
    load_vm "$1"
    fetch_image "$1" || die "all mirrors failed"
}

# --------------------------------------------------------------------------
# start / stop
# --------------------------------------------------------------------------
cmd_start() {
    need_root
    local name="$1" fg=0
    [ "${2:-}" = "-f" ] && fg=1
    load_vm "$name"
    local d; d=$(vm_dir "$name")

    running_pid "$name" >/dev/null && { say "already running"; return 0; }
    local f
    for f in "$d/uefi-code.fd" "$d/uefi-vars.fd" "$d/disk.qcow2" "$d/seed.img"; do
        [ -f "$f" ] || die "missing $f  (try: ckvm image $name)"
    done

    # fresh NVRAM from the pristine template: a stale store makes GRUB hang
    [ -f "$CKVM_FWDIR/edk2_vars.fd" ] && cp -f "$CKVM_FWDIR/edk2_vars.fd" "$d/uefi-vars.fd"

    # ---- networking ------------------------------------------------------
    local net_args=() tap=""
    case "${NET_MODE:-user}" in
        user)
            # warn about port clashes before QEMU does, it is much clearer
            local hfwd item h
            hfwd=$(build_hostfwd)
            local IFS=','
            for item in $hfwd; do
                h=$(echo "$item" | sed 's/.*0\.0\.0\.0:\([0-9]*\)-.*/\1/')
                if ! check_host_port "$h"; then
                    local who
                    who=$(port_owner "$h")
                    warn "host port $h is already in use${who:+ by $who}"
                    warn "  pick another one, e.g. --fwd 22,18080:80"
                fi
            done
            net_args=(-netdev "user,id=n0${hfwd:+,$hfwd}"
                       -device virtio-net-pci,netdev=n0)
            ;;
        host|tap)
            tap=$(tap_up "$name") || die "could not set up tap networking"
            net_args=(-netdev "tap,id=n0,script=no,downscript=no,ifname=$tap"
                       -device virtio-net-pci,netdev=n0)
            say "tap $tap up: host ${TAP_IP_HOST} / guest ${TAP_IP_GUEST}"
            ;;
        none)
            net_args=()
            ;;
        *)
            die "unknown NET_MODE '${NET_MODE}' in the vm.conf"
            ;;
    esac

    rm -f "$(vm_log "$name")" "$d/qemu.err"
    local args=(
        "$QEMU" -name "$name"
        -M virt,gic-version=3 -cpu max -accel kvm -smp "$CPUS" -m "$MEM"
        -drive if=pflash,format=raw,unit=0,file="$d/uefi-code.fd",readonly=on
        -drive if=pflash,format=raw,unit=1,file="$d/uefi-vars.fd"
        -drive if=virtio,format=qcow2,file="$d/disk.qcow2"
        -drive if=virtio,format=raw,readonly=on,file="$d/seed.img"
        "${net_args[@]}"
        -device virtio-rng-pci
        -display none -serial file:"$(vm_log "$name")"
    )

    if [ "$fg" = 1 ]; then
        exec taskset -c "${BOOT_CPU:-$CPUSET}" "${args[@]}"
    fi

    # start on a single core, widen once QEMU is up
    local bootc="${BOOT_CPU:-$CPUSET}"
    nohup taskset -c "$bootc" "${args[@]}" > "$d/qemu.err" 2>&1 &
    echo $! > "$(vm_pid "$name")"
    sleep 6
    local p; p=$(cat "$(vm_pid "$name")")
    if ! kill -0 "$p" 2>/dev/null; then
        [ -n "$tap" ] && tap_down "$name"
        die "failed to start: $(head -1 "$d/qemu.err")"
    fi
    widen_affinity "$p"
    say "guest '$name' running (pid $p, ${CPUS} vCPU, ${MEM} MiB, cpuset $CPUSET)"

    # Boot takes ~30s, and until sshd is up an immediate `ssh` gets
    # "Connection reset by peer".  Wait for the banner so start only reports
    # success when the guest is actually usable.
    case "${NET_MODE:-user}" in
        user)
            if spin_timed "等待启动完成（SSH 就绪）" 45 wait_for_ssh "$PORT" 300; then
                say "SSH 已就绪"
            else
                warn "等待 SSH 超时；guest 可能起得慢： ckvm console $name -n 40"
            fi
            ;;
        host|tap)
            # Waiting for the serial login prompt is not enough: sshd may be
            # listening without being able to authenticate yet, and an
            # immediate ssh then fails with "Permission denied".  Probe the
            # guest's own address for the SSH banner instead.
            if spin_timed "等待启动完成（SSH 就绪）" 45 \
                 wait_for_ssh 22 300 "$TAP_IP_GUEST"; then
                say "SSH 已就绪"
            elif grep -aq "login:" "$(vm_log "$name")" 2>/dev/null; then
                say "已出现登录提示（SSH 未确认，可能还要等几秒）"
            else
                warn "等待启动超时： ckvm console $name -n 40"
            fi
            ;;
    esac

    show_access "$name"
}

# host mode helper: wait for "login:" to appear in the serial log
_wait_login_prompt() {
    local name="$1" timeout="${2:-300}" elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        grep -aq "login:" "$(vm_log "$name")" 2>/dev/null && return 0
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}


# Wait until the guest's sshd actually answers.
#
# Without this, `ckvm start` reported success the moment QEMU was alive and
# an immediate `ssh` failed with "Connection reset by peer" - the port
# forward existed but nothing was listening behind it yet.
#
# $1 = host port to probe, $2 = optional timeout in seconds
wait_for_ssh() {
    local port="$1" timeout="${2:-300}" probe_host="${3:-127.0.0.1}" elapsed=0
    command -v python3 >/dev/null 2>&1 || return 1
    while [ "$elapsed" -lt "$timeout" ]; do
        if python3 -c '
import socket,sys
for _ in range(3):
    try:
        s=socket.socket(); s.settimeout(1)
        s.connect((sys.argv[2], int(sys.argv[1])))
        s.settimeout(2)
        b=s.recv(64); s.close()
        if b.startswith(b"SSH-"):
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
' "$port" "$probe_host" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}
# how to reach this guest

# Widen a running QEMU's affinity from its single boot core to $CPUSET.
# vCPU threads inherit the process mask at creation, so each thread has to be
# set individually - taskset on the process alone does not move them.
widen_affinity() {
    local p="$1" t
    [ -n "${BOOT_CPU:-}" ] || return 0
    [ "$CPUSET" = "$BOOT_CPU" ] && return 0
    for t in /proc/"$p"/task/*; do
        [ -e "$t" ] || continue
        taskset -pc "$CPUSET" "$(basename "$t")" >/dev/null 2>&1 || true
    done
    return 0
}


# Map a user-facing core choice to a mask.  Accepts the names, or a raw
# mask for anyone who wants something else.
cores_to_mask() {
    case "${1:-}" in
        all|ALL|full|FULL) echo "$CORESET_FULL" ;;
        big|BIG|a76|A76)   echo "$CORESET_BIG" ;;
        "")                echo "$DEF_CPUSET" ;;
        *)                 echo "$1" ;;
    esac
}

# Human description for the choice, for the confirmation line.
cores_to_label() {
    case "$1" in
        "$CORESET_FULL") echo "全部 8 个物理核（6×A55 + 2×A76）" ;;
        "$CORESET_BIG")  echo "仅 2 个大核（A76）" ;;
        *)               echo "自定义掩码 $1" ;;
    esac
}

show_access() {
    local name="$1"; load_vm "$name"
    case "${NET_MODE:-user}" in
        user)
            local hfwd item h g
            hfwd=$(build_hostfwd)
            say "network: user-mode NAT"
            local IFS=','
            for item in $hfwd; do
                h=$(echo "$item" | sed 's/.*0\.0\.0\.0:\([0-9]*\)-.*/\1/')
                g=$(echo "$item" | sed 's/.*-:\([0-9]*\).*/\1/')
                if [ "$g" = "22" ]; then
                    say "  ssh ${VM_USER}@127.0.0.1 -p ${h}   (password: ${VM_PASS})"
                else
                    say "  port $g -> 127.0.0.1:$h"
                fi
            done
            ;;
        host|tap)
            say "network: tap, the guest is on this container's network"
            say "  guest ip : ${TAP_IP_GUEST}/24   gateway ${TAP_IP_HOST}"
            say "  ssh      : ${VM_USER}@${TAP_IP_GUEST}   (password: ${VM_PASS})"
            say "  from the container, no port forward needed."
            if ! ip -4 addr show eth0 2>/dev/null | grep -q "inet "; then :; fi
            say "  NOTE: this is the container's network (inside droidspaces)."
            say "        It is NOT the phone's LAN address."
            say "        To reach the guest from the LAN, forward on the Android"
            say "        side (see: ckvm net $name) or use user mode."
            ;;
        none) say "network: none" ;;
    esac
}
cmd_stop() {
    need_root
    local name="$1" p
    if p=$(running_pid "$name"); then
        kill -15 "$p" 2>/dev/null; sleep 4
        kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
        rm -f "$(vm_pid "$name")"
        tap_down "$name" >/dev/null 2>&1
        say "guest '$name' stopped"
    else
        say "guest '$name' is not running"
        rm -f "$(vm_pid "$name")"
    fi
}

cmd_restart() { cmd_stop "$1"; sleep 2; cmd_start "$1"; }

# --------------------------------------------------------------------------
# list / status / console
# --------------------------------------------------------------------------
cmd_list() {
    [ -d "$CKVM_ROOT" ] || { say "no guests yet (ckvm create <name>)"; return 0; }
    printf '  %-16s %-8s %-6s %-8s %-7s %-6s %s\n' \
           NAME STATE CPUS MEM DISK PORT SSH
    local d name state p
    for d in "$CKVM_ROOT"/*/; do
        [ -f "$d/vm.conf" ] || continue
        name=$(basename "$d")
        if p=$(running_pid "$name"); then state="running"; else state="stopped"; fi
        ( . "$d/vm.conf"
          local how
          case "${NET_MODE:-user}" in
              host|tap) how="ssh ${VM_USER}@${TAP_IP_GUEST}" ;;
              none)     how="(no network)" ;;
              *)        how="ssh ${VM_USER}@127.0.0.1 -p ${PORT}" ;;
          esac
          printf '  %-16s %-8s %-6s %-8s %-7s %-6s %s\n' \
                 "$name" "$state" "$CPUS" "$MEM" "${DISK_GB}G" "$PORT" "$how" )
    done
}

cmd_status() {
    local name="$1" p
    load_vm "$name"
    if p=$(running_pid "$name"); then
        local aff
        aff=$(taskset -pc "$p" 2>/dev/null | sed 's/.*: //')
        say "guest:   running (pid $p, affinity $aff)"
    else
        say "guest:   stopped"
    fi
    say "config:  ${CPUS} vCPU, ${MEM} MiB, disk ${DISK_GB}G, port ${PORT}"
    say "user:    ${VM_USER} / ${VM_PASS}"
    say "serial:  $(wc -c < "$(vm_log "$name")" 2>/dev/null || echo 0) bytes"
    grep -aq "login:" "$(vm_log "$name")" 2>/dev/null && say "login prompt: present"
    say "--- serial tail ---"
    tail -n 8 "$(vm_log "$name")" 2>/dev/null | strip_serial
}

# Strip the terminal-control traffic that UEFI, GRUB and the kernel emit on a
# serial port: DCS, OSC, private mode setters (ESC[!p, ESC[?7h), cursor moves,
# position reports.  SGR colour sequences are preserved so a console stays
# readable.
#
# Implemented in Python on purpose: doing this correctly with sed/awk is a
# trap.  GNU sed 4.9 has no -u (so it buffers a live stream), BRE cannot
# express the CSI parameter ranges, and the awk version silently mis-parsed
# private-mode sequences.
SERIAL_SAN_PY='
import re, sys
SGR  = rb"\x1b\[[0-9;]*m"
DROP = re.compile(
    rb"\x1b\[[0-9:;<=>?!]*[a-ln-zA-LN-Z]"
    rb"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
    rb"|\x1bP[^\x1b]*\x1b\\"
    rb"|\x1b[()][A-Z0-9]"
    rb"|\x1b[=>]"
    rb"|\x1b")
def sanitize(b):
    out, pos = [], 0
    for m in re.finditer(SGR, b):
        out.append(DROP.sub(b"", b[pos:m.start()]))
        out.append(m.group(0))
        pos = m.end()
    out.append(DROP.sub(b"", b[pos:]))
    return b"".join(out)
import errno
data = sys.stdin.buffer.read()
try:
    sys.stdout.buffer.write(sanitize(data))
    sys.stdout.buffer.flush()
except BrokenPipeError:
    pass
except OSError as e:
    if e.errno != errno.EPIPE:
        raise
'

strip_serial() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -u -c "$SERIAL_SAN_PY"
    else
        # no python3: drop every escape (colour is lost, text stays clean)
        tr -d '\000' | sed -e 's/'$(printf '\033')'\[[0-9;]*[a-zA-Z]//g'
    fi
}

# usage: ckvm console <name> [-a] [-n N]
#   default: attach and only show NEW output (no boot-log replay)
#   -a     : replay the whole log first
#   -n N   : replay the last N lines first
cmd_console() {
    local name="$1"; shift || true
    local replay=-1
    while [ $# -gt 0 ]; do
        case "$1" in
            -a|--all) replay=0; shift ;;
            -n)       replay="${2:-40}"; shift 2 ;;
            *)        shift ;;
        esac
    done

    load_vm "$name"
    local log; log=$(vm_log "$name")
    if [ ! -f "$log" ]; then
        warn "no serial log for '$name' (is it running? try: ckvm start $name)"
        return 1
    fi
    if ! running_pid "$name" >/dev/null; then
        warn "guest '$name' is not running; showing the stale log"
    fi

    say "serial console for '$name'  (Ctrl-C to detach; the guest keeps running)"
    say "  log: $log"
    say "  tip: an interactive login is easier over ssh - see 'ckvm status $name'"
    printf '\n'

    local lines
    if [ "$replay" -eq 0 ]; then
        lines=$(wc -l < "$log")
    elif [ "$replay" -gt 0 ]; then
        lines="$replay"
    else
        lines=0                    # attach only: skip everything already there
    fi

    if [ "$lines" -gt 0 ]; then
        tail -n "$lines" "$log" | strip_serial
    fi
    # tail -F (capital) survives log rotation/recreation
    tail -c +$(( $(stat -c%s "$log") + 1 )) -F "$log" 2>/dev/null | strip_serial
}

cmd_rm() {
    need_root
    local name="$1" force="${2:-}"
    load_vm "$name"
    if running_pid "$name" >/dev/null; then
        [ "$force" = "-f" ] || die "guest is running; use 'ckvm stop $name' or 'ckvm rm $name -f'"
        cmd_stop "$name"
    fi
    systemctl disable --now "ckvm@$name.service" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/ckvm@$name.service"
    rm -rf "$(vm_dir "$name")"
    systemctl daemon-reload >/dev/null 2>&1 || true
    say "guest '$name' removed"
}

# --------------------------------------------------------------------------
# systemd
# --------------------------------------------------------------------------
write_unit() {
    mkdir -p "$SYSTEMD_DIR"
    cat > "$SYSTEMD_DIR/ckvm@.service" <<EOF
[Unit]
Description=ckvm KVM guest %i
After=network.target

[Service]
Type=forking
ExecStart=$CKVM_BINDIR/ckvm start %i
ExecStop=$CKVM_BINDIR/ckvm stop %i
PIDFile=$CKVM_ROOT/%i/qemu.pid
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    say "wrote $SYSTEMD_DIR/ckvm@.service"
}

cmd_enable() {
    need_root
    local name="$1"
    load_vm "$name"
    [ -f "$SYSTEMD_DIR/ckvm@.service" ] || write_unit
    systemctl daemon-reload
    systemctl enable --now "ckvm@$name.service"
    say "systemd: ckvm@$name.service enabled and started"
    say "control it with: systemctl {status,stop,restart} ckvm@$name"
}

cmd_disable() {
    need_root
    systemctl disable --now "ckvm@$1.service" 2>/dev/null || true
    say "systemd: ckvm@$1.service disabled"
}

# --------------------------------------------------------------------------
# config / install
# --------------------------------------------------------------------------
cmd_config() {
    if [ $# -eq 0 ]; then
        say "root:     $CKVM_ROOT"
        say "firmware: $CKVM_FWDIR"
        say "images:   $MIRROR_IMAGE_LIST"
        say "apt:      $MIRROR_APT"
        return 0
    fi
    load_vm "$1"
    say "config file: $(vm_conf "$1")"
    say ""
    cat "$(vm_conf "$1")"
}

cmd_edit() { load_vm "$1"; ${EDITOR:-vi} "$(vm_conf "$1")"; }

# --------------------------------------------------------------------------
# network report
# --------------------------------------------------------------------------
cmd_net() {
    local name="${1:-}" d
    if [ -z "$name" ]; then
        say "container network:"
        ip -4 -o addr show 2>/dev/null | awk '{print "  "$2"  "$4}'
        say "default route: $(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
        say ""
        say "guests:"
        for d in "$CKVM_ROOT"/*/; do
            [ -f "$d/vm.conf" ] || continue
            ( . "$d/vm.conf"
              printf '  %-14s mode=%-6s forwards=%s\n' \
                     "$(basename "$d")" "${NET_MODE:-user}" "${FORWARDS:--}" )
        done
        return 0
    fi
    load_vm "$name"
    say "guest:   $name"
    say "mode:    ${NET_MODE:-user}"
    say "forwards:${FORWARDS:- (none)}"
    say ""
    show_access "$name"
    say ""
    if [ "${NET_MODE:-user}" = "host" ] || [ "${NET_MODE:-user}" = "tap" ]; then
        local tap; tap=$(tap_name "$name")
        say "tap device $tap:"
        ip -4 addr show "$tap" 2>/dev/null | sed 's/^/  /' || say "  (not up)"
        say ""
        say "NAT rules:"
        iptables -t nat -S POSTROUTING 2>/dev/null | grep -- "$TAP_IP_GUEST" | sed 's/^/  /' || true
        iptables -S FORWARD 2>/dev/null | grep -- "$tap" | sed 's/^/  /' || true
        say ""
        say "This address lives inside the droidspaces container, so it is not"
        say "visible on the phone's LAN.  Two ways to expose it:"
        say ""
        say "  a) keep it simple - use user mode with explicit forwards:"
        say "       ckvm config $name     # set NET_MODE=user FORWARDS=22,80"
        say "       ckvm restart $name"
        say ""
        say "  b) bridge on the Android side (needs the host's root shell):"
        say "       # on the phone, as root:"
        say "       ip link add br-ckvm type bridge"
        say "       ip link set eth0 master br-ckvm    # container's veth peer"
        say "       ip link set br-ckvm up"
        say "     then the guest is reachable as ${TAP_IP_GUEST} from anywhere"
        say "     that can route to the phone."
        say ""
        say "  Port 22 on this container is its own sshd; the guest's sshd is"
        say "  separate and does not conflict in host mode."
    fi
}

# Where ckvm fetches itself and the firmware from.
#
# The default is plain GitHub.  Acceleration is opt-in: pass -cn to install,
# or set CKVM_ACCEL=1, and the well-known GitHub-frontend mirrors are used
# instead.  Nothing here silently rewrites the source.
#
# NOTE: use the full ref path "refs/heads/<branch>", not the bare branch name.
# The GitHub frontends cache by URL path, and a bare "resukisu" was serving a
# revision several commits old (observed: x-cache: HIT, x-cache-hits: 24,
# cache-control: max-age=300) while "refs/heads/resukisu" returned the current
# file.  The path difference is enough to miss that cache.
REPO_BRANCH="refs/heads/resukisu"
REPO_GITHUB="https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/${REPO_BRANCH}/kvm_manager"
REPO_GITHUB_CN="https://git.yylx.win/github.com/ccmx200/kernel-lxc-xiaomi_mt6833/raw/${REPO_BRANCH}/kvm_manager"
# name=url pairs so `-cn` can fall through them in order if one is down
REPO_MIRRORS_CN="git.yylx.win=https://git.yylx.win/raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/${REPO_BRANCH}/kvm_manager ghproxy.net=https://ghproxy.net/https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/${REPO_BRANCH}/kvm_manager gh-proxy.com=https://gh-proxy.com/https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/${REPO_BRANCH}/kvm_manager"

CKVM_REPO=""          # resolved by resolve_repo()
CKVM_USING_CN=0       # 1 when any acceleration is in play
GH_UPSTREAM="https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager"
GH_UPSTREAM_PATH="github.com/ccmx200/kernel-lxc-xiaomi_mt6833/raw/refs/heads/resukisu/kvm_manager"

# Turn whatever the user typed into a usable "base + file" prefix.
# Accepted forms:
#   https://ghproxy.net/https://raw.githubusercontent.com/...   (full prefix)
#   https://ghproxy.net                                         (we append the upstream path)
#   ghproxy.net                                                 (scheme assumed https)
#   https://my.mirror/{url}                                     (placeholder, {url} or %s)
normalise_mirror() {
    local m="$1"
    case "$m" in
        *'%s'*)  m="${m//\%s/$GH_UPSTREAM}"; echo "$m"; return ;;
    esac
    case "$m" in
        *'{url}'*) m="${m//\{url\}/$GH_UPSTREAM}"; echo "$m"; return ;;
    esac
    case "$m" in
        *'raw.githubusercontent.com'*) echo "$m"; return ;;
    esac
    case "$m" in
        *github.com/ccmx200*) echo "$m"; return ;;
    esac
    case "$m" in
        http://*|https://*) echo "${m%/}/$GH_UPSTREAM_PATH" ;;
        *)                  echo "https://$m/$GH_UPSTREAM_PATH" ;;
    esac
}

# $1 = acceleration request, which may be:
#      ""       -> plain GitHub
#      1 / cn   -> probe the built-in accelerator list
#      <URL>    -> use the user's own mirror, alone
resolve_repo() {
    local req="${1:-${CKVM_ACCEL:-0}}" pair name url

    # an explicit URL (a user-supplied accelerator)
    case "$req" in
        ""|0|no|off) ;;
        1|cn|yes)
            CKVM_USING_CN=1
            for pair in $REPO_MIRRORS_CN; do
                name=${pair%%=*}; url=${pair#*=}
                if curl -fsSLk --max-time 20 -o /dev/null "$url/kvm-vm.sh" 2>/dev/null; then
                    CKVM_REPO="$url"
                    say "using accelerator: $name"
                    return 0
                fi
            done
            warn "no built-in accelerator is reachable; falling back to GitHub"
            ;;
        *)
            CKVM_USING_CN=1
            url=$(normalise_mirror "$req")
            if curl -fsSLk --max-time 25 -o /dev/null "$url/kvm-vm.sh" 2>/dev/null; then
                CKVM_REPO="$url"
                say "using your accelerator: $CKVM_REPO"
                return 0
            fi
            warn "your accelerator did not answer: $url"
            warn "falling back to GitHub"
            ;;
    esac
    CKVM_REPO="$REPO_GITHUB"
    return 0
}
# download one file from the resolved repo, through the download engine
# A downloaded ckvm must parse, carry the build marker, and look like the
# script we expect.  Cheap insurance against a caching mirror or a truncated
# transfer - both of which have bitten this installer for real.
verify_download() {
    local f="$1"
    [ -s "$f" ] || return 1
    head -1 "$f" | grep -q '^#!/bin/bash' || return 1
    grep -q 'CKVM_BUILD=' "$f" || return 1
    grep -q 'cmd_versions()' "$f" || return 1
    bash -n "$f" 2>/dev/null || return 1
    return 0
}

fetch_repo_file() {
    local rel="$1" out="$2"
    [ -n "$CKVM_REPO" ] || resolve_repo
    if download_url "$CKVM_REPO/$rel" "$out" "$rel"; then
        echo "$CKVM_REPO"
        return 0
    fi
    return 1
}

cmd_install() {
    need_root
    local accel="${CKVM_ACCEL:-0}" RUN_SELFTEST=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -cn|--cn|--china)
                # -cn alone probes the built-in list; -cn <url> uses yours
                if [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
                    accel="$2"; shift 2
                else
                    accel=1; shift
                fi
                ;;
            --repo|--mirror) accel="$2"; shift 2 ;;
            --selftest)      RUN_SELFTEST=1; shift ;;
            *) shift ;;
        esac
    done
    mkdir -p "$CKVM_ROOT" "$CKVM_FWDIR"
    resolve_repo "$accel"
    ensure_aria2 || say "aria2 not available; falling back to curl"
    say "download backend: $(download_pick_backend)"

    # Where did we come from?  Piped installs ($0 = bash/sh) must refetch;
    # a real file can just be copied.
    local self="" source_dir=""
    if [ -f "$0" ] && [ "$(basename "$0")" != "bash" ] \
       && [ "$(basename "$0")" != "sh" ]; then
        self=$(readlink -f "$0")
        source_dir=$(dirname "$self")
    fi

    if [ -n "$self" ] && [ "$self" != "$(readlink -f "$CKVM_BINDIR/ckvm" 2>/dev/null)" ]; then
        install -m 0755 "$self" "$CKVM_BINDIR/ckvm"
    else
        # download to a temporary file first: a failed install must never
        # leave the machine without a working ckvm
        say "fetching ckvm"
        local base tmp
        # NOTE: use cat, not mv - /tmp can be a separate mount with its own
        # SELinux label and mv would fail on the security.selinux attribute
        tmp=$(mktemp "${TMPDIR:-/tmp}/ckvm.XXXXXX")
        if base=$(fetch_repo_file "kvm-vm.sh" "$tmp"); then
            if ! verify_download "$tmp"; then
                rm -f "$tmp"
                die "the downloaded script did not verify (mirror serving a stale copy?)
       try another source:  $0 install -cn <your-mirror>"
            fi
            cat "$tmp" > "$CKVM_BINDIR/ckvm"
            chmod 0755 "$CKVM_BINDIR/ckvm"
            rm -f "$tmp"
            say "  from $base"
        else
            rm -f "$tmp"
            die "could not download kvm-vm.sh  (try: 'install -cn <your-mirror>')"
        fi
    fi
    say "installed: $CKVM_BINDIR/ckvm"

    # Dependencies, checked here so the first create does not fail half way.
    # shellcheck disable=SC1090
    ensure_deps || warn "有必需依赖没装上，创建虚拟机前请先补上"

    # firmware: whatever is already on the device wins; otherwise fetch it
    local src="" cand
    for cand in "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd" \
                "$source_dir/edk2_qemu_aarch64_nonvram.fd"; do
        [ -n "$cand" ] && [ -f "$cand" ] && { src="$cand"; break; }
    done
    [ -z "$src" ] && src=$(find_firmware) || true

    if [ -n "$src" ]; then
        install_firmware "$src"
    else
        say "firmware not present; fetching it"
        local ok=0 f
        for f in edk2_qemu_aarch64_nonvram.fd edk2_vars.fd; do
            if [ -f "$CKVM_FWDIR/$f" ]; then
                say "  $f already present"
                ok=1
                continue
            fi
            if fetch_repo_file "$f" "$CKVM_FWDIR/$f" >/dev/null; then
                ok=1
                say "  got $f"
            else
                warn "could not fetch $f"
            fi
        done
        if [ "$ok" = 1 ]; then
            say "firmware downloaded into $CKVM_FWDIR"
        else
            warn "stage the firmware manually - 'ckvm create' will show how"
        fi
    fi

    write_unit
    systemctl daemon-reload
    say ""
    if [ "$RUN_SELFTEST" = 1 ]; then
        cmd_selftest || true
    fi
    say "try:  ckvm create ubuntu26 && ckvm start ubuntu26 && ckvm list"
    say "      or: ckvm selftest   (boot a throwaway guest to prove it works)"
}
cmd_uninstall() {
    need_root
    systemctl disable --now 'ckvm@*' >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/ckvm@.service" "$CKVM_BINDIR/ckvm"
    systemctl daemon-reload
    say "removed ckvm (guest data in $CKVM_ROOT kept; delete it manually)"
}


# ---------------------------------------------------------------------------
# selftest - prove this install can actually boot a guest
#
# The installer's check only ever proved the downloaded file was intact.  It
# never ran anything, so a build that could not boot at all would install and
# report success.  This boots a throwaway guest and checks the things that
# have broken in practice: /dev/kvm usable, the core mask QEMU accepts,
# working firmware, and a guest that reaches a login prompt with CPUs up.
# ---------------------------------------------------------------------------
SELFTEST_NAME="ckvm-selftest"
SELFTEST_KEEP=0
SELFTEST_FAILED=0

st_step() { printf '  %-30s' "$1"; }
st_ok()   { printf '%sok%s\n' "$C_G" "$C_RST"; }
st_no()   { printf '%sfail%s  %s\n' "$C_R" "$C_RST" "$1"; SELFTEST_FAILED=$((SELFTEST_FAILED + 1)); }

st_cleanup() {
    local d; d=$(vm_dir "$SELFTEST_NAME" 2>/dev/null)
    local p; p=$(running_pid "$SELFTEST_NAME" 2>/dev/null)
    if [ -n "$p" ]; then
        kill "$p" 2>/dev/null
        sleep 2
        kill -9 "$p" 2>/dev/null
    fi
    if [ "$SELFTEST_KEEP" = 1 ]; then
        say "测试机保留: ckvm console $SELFTEST_NAME"
    else
        rm -rf "$CKVM_ROOT/$SELFTEST_NAME" 2>/dev/null
    fi
    return 0
}

cmd_selftest() {
    need_root
    local rel=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep) SELFTEST_KEEP=1; shift ;;
            *)      rel="$1"; shift ;;
        esac
    done
    [ -n "$rel" ] || rel="$DEF_REL"

    trap 'st_cleanup' EXIT INT TERM
    printf '\n  %sckvm selftest%s\n\n' "$C_B" "$C_RST"

    # Try to fix the dependencies before complaining about them: the whole
    # point of the selftest is to get a working install, not just a verdict.
    local _missing; _missing=$(deps_missing)
    if [ -n "$_missing" ]; then
        say "缺少依赖: $_missing"
        ensure_deps || true
        echo
    fi

    # ---------------------------------------------------------- environment
    st_step "root"
    if [ "$(id -u)" = 0 ]; then st_ok; else st_no "not root"; fi

    st_step "qemu-system-aarch64"
    if [ -x "$QEMU" ] || command -v "$QEMU" >/dev/null 2>&1; then st_ok; else st_no "not found"; fi

    st_step "/dev/kvm"
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then st_ok; else st_no "missing or not writable"; fi

    st_step "cloud-localds"
    if command -v cloud-localds >/dev/null 2>&1; then st_ok; else st_no "cloud-image-utils missing"; fi

    st_step "firmware"
    if [ -s "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd" ]; then
        st_ok
    else
        st_no "missing edk2_qemu_aarch64_nonvram.fd"
    fi

    st_step "free disk"
    local avail
    avail=$(df -Pm "$CKVM_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
    if [ -n "$avail" ] && [ "$avail" -ge 2048 ]; then
        printf '%sok%s (%s MiB)\n' "$C_G" "$C_RST" "$avail"
    else
        st_no "need >=2048 MiB, have ${avail:-?}"
    fi

    if [ "$SELFTEST_FAILED" -gt 0 ]; then
        printf '\n  %s✗ %d 项环境检查失败，跳过启动测试%s\n\n' "$C_R" "$SELFTEST_FAILED" "$C_RST"
        return 1
    fi

    # ------------------------------------------------------ throwaway guest
    printf '\n  %s启动测试: 2 vCPU / 1024 MiB / 3G, 全核掩码 %s%s\n\n' \
           "$C_DIM" "$CORESET_FULL" "$C_RST"

    rm -rf "$CKVM_ROOT/$SELFTEST_NAME"
    mkdir -p "$CKVM_ROOT/$SELFTEST_NAME"
    cat > "$CKVM_ROOT/$SELFTEST_NAME/vm.conf" <<EOF
NAME=$SELFTEST_NAME
UBUNTU_REL=$rel
CPUS=2
MEM=1024
DISK_GB=3
PORT=$DEF_PORT_BASE
CPUSET=$CORESET_FULL
BOOT_CPU=$DEF_BOOT_CPU
VM_USER=root
VM_PASS=selftest
VM_HOSTNAME=$SELFTEST_NAME
NET_MODE=user
FORWARDS=22
EOF

    st_step "fetch image ($rel)"
    if fetch_image "$SELFTEST_NAME" >/dev/null 2>&1; then
        st_ok
    else
        st_no "download failed"
        printf '\n  %s✗ 无法取得镜像%s\n\n' "$C_R" "$C_RST"
        return 1
    fi

    st_step "build seed"
    if make_seed "$SELFTEST_NAME" >/dev/null 2>&1 \
       && [ -f "$CKVM_ROOT/$SELFTEST_NAME/seed.img" ]; then
        st_ok
    else
        st_no "cloud-localds failed"
        return 1
    fi

    # ----------------------------------------------------------- run qemu
    local d; d=$(vm_dir "$SELFTEST_NAME")
    # both halves, exactly as cmd_create does
    cp -f "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd" "$d/uefi-code.fd"
    cp -f "$CKVM_FWDIR/edk2_vars.fd" "$d/uefi-vars.fd"
    : > "$d/serial.log"

    st_step "qemu starts on cpuset $CORESET_FULL"
    setsid taskset -c "${BOOT_CPU:-$CORESET_FULL}" "$QEMU" \
        -name "$SELFTEST_NAME" -M virt,gic-version=3 -cpu max -accel kvm \
        -smp 2 -m 1024 \
        -drive if=pflash,format=raw,unit=0,file="$d/uefi-code.fd",readonly=on \
        -drive if=pflash,format=raw,unit=1,file="$d/uefi-vars.fd" \
        -drive if=virtio,format=qcow2,file="$d/disk.qcow2" \
        -drive if=virtio,format=raw,readonly=on,file="$d/seed.img" \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -device virtio-rng-pci -display none \
        -serial file:"$d/serial.log" > "$d/qemu.err" 2>&1 &
    # running_pid reads this file, and cmd_start writes it the same way
    echo $! > "$(vm_pid "$SELFTEST_NAME")"
    sleep 6
    local p; p=$(running_pid "$SELFTEST_NAME" 2>/dev/null)
    if [ -n "$p" ]; then
        st_ok
        widen_affinity "$p"
    else
        st_no "qemu refused to start"
        printf '    %s\n' "$(tail -2 "$d/qemu.err" 2>/dev/null | tr '\n' ' ')"
        printf '\n  %s✗ 启动失败%s\n\n' "$C_R" "$C_RST"
        return 1
    fi

    st_step "guest reaches login"
    local i=0
    while [ "$i" -lt 180 ]; do
        sleep 2; i=$((i + 2))
        grep -aq "login:" "$d/serial.log" 2>/dev/null && break
        [ -n "$(running_pid "$SELFTEST_NAME" 2>/dev/null)" ] || break
    done
    if grep -aq "login:" "$d/serial.log" 2>/dev/null; then
        printf '%sok%s (%ss)\n' "$C_G" "$C_RST" "$i"
    else
        st_no "no login prompt after ${i}s"
        printf '    %s\n' "$(tail -2 "$d/qemu.err" 2>/dev/null | tr '\n' ' ')"
    fi

    st_step "guest reports its CPUs"
    # single-CPU guests print "Brought up 1 node, 1 CPU"; SMP guests print
    # "SMP: Total of N processors activated".  Accept either.
    local n
    n=$(grep -ao 'SMP: Total of [0-9]\+' "$d/serial.log" 2>/dev/null | tail -1 | grep -o '[0-9]\+')
    if [ -z "$n" ]; then
        n=$(grep -ao 'Brought up [0-9]\+ node[s]*, [0-9]\+ CPU' "$d/serial.log" 2>/dev/null \
            | tail -1 | grep -o '[0-9]\+ CPU' | grep -o '[0-9]\+')
    fi
    if [ "${n:-0}" -ge 1 ]; then
        printf '%sok%s (%s CPU)\n' "$C_G" "$C_RST" "$n"
    else
        st_no "guest never reported its CPU count"
    fi

    st_step "firmware did not wedge"
    if grep -aqi 'ASSERT\|Synchronous exception' "$d/serial.log" 2>/dev/null; then
        st_no "firmware assertion in the serial log"
    else
        st_ok
    fi

    printf '\n'
    if [ "$SELFTEST_FAILED" -eq 0 ]; then
        printf '  %s✓ 自检通过，这台机器可以跑虚拟机%s\n\n' "$C_G" "$C_RST"
        return 0
    fi
    printf '  %s✗ %d 项失败%s\n\n' "$C_R" "$SELFTEST_FAILED" "$C_RST"
    return 1
}

cmd_help() {
    cat <<EOF
ckvm $CKVM_VERSION - KVM guest manager (MT6833 / evergo)

  ckvm install [options]           install to $CKVM_BINDIR/ckvm + systemd unit
  ckvm uninstall                   remove the binary and unit

    download source (default is plain GitHub, nothing is rewritten):
      (none)              use GitHub directly
      -cn                 probe the built-in accelerator list, use the first
                          that answers
      -cn <url>           use YOUR accelerator; accepts a full prefix, a bare
                          host, or a template with {url} or %s:
                            -cn https://your.proxy
                            -cn your.proxy
                            -cn "https://your.proxy/{url}"
      --repo <url>        same as -cn <url>
      CKVM_ACCEL=1        environment equivalent of -cn

  ckvm create                      interactive store: pick a release and
                                   answer a few prompts (default on a tty)
  ckvm create <name> [options]     create a guest non-interactively
  ckvm versions                    list the releases the store offers
  ckvm selftest [--keep]           boot a throwaway guest to prove this
                                   install works: checks /dev/kvm, qemu,
                                   firmware, the core mask, and that the
                                   guest reaches a login prompt.
                                   --keep leaves it for inspection
  ckvm ports                       how port mapping works
  ckvm help ports                  same thing
        --cpus N    vCPU count          (default $DEF_CPUS)
        --cores C   which physical cores to use:
                      all  = 全部 8 核（6×A55 + 2×A76），吞吐优先
                      big  = 仅 2 个大核（A76），单核延迟优先
                    (default $DEF_CORES)
                    实测 sha256 八线程吞吐: all 约 7.4-7.7 GB/s,
                    big 约 2.9-3.0 GB/s；all 的启动会慢 8-12 秒
        --mem  MB   memory              (default $DEF_MEM)
        --disk GB   disk size           (default $DEF_DISK_GB)
        --rel  V    Ubuntu release      (default $DEF_REL)
        --port N    host ssh port       (default: first free from $DEF_PORT_BASE)
        --net  M    user | host         (default $DEF_NET_MODE)
                      user: QEMU NAT, reach it via forwarded ports
                      host: tap device, guest gets its own IP, runs its own
                            sshd; nothing is forwarded
        --user U    login account: a name, or 'root'  (default ubuntu)
        --pass P    password for that account      (default ubuntu)
        --fwd  L    ports to forward, e.g. 22,80,443 or 8022:22
                    default "$DEF_FORWARDS" (guest 22 is published on --port)

  ckvm image <name>                (re)download the guest image
  ckvm start <name> [-f]           start (foreground with -f)
  ckvm stop|restart <name>
  ckvm list                        all guests and their state
  ckvm status <name>               detail + serial tail
  ckvm console <name>              follow the serial console
  ckvm rm <name> [-f]              delete a guest

  ckvm enable <name>               enable + start under systemd
  ckvm disable <name>              disable the systemd unit

  ckvm net <name>                  show a guest's network layout
  ckvm net                         container network + all guests
  ckvm config [name]               show global or per-guest settings
  ckvm edit <name>                 edit a guest's vm.conf

Files: $CKVM_ROOT/<name>/    firmware: $CKVM_FWDIR

作者  $CKVM_AUTHOR    $CKVM_HOME
      GPL-2.0 / 见仓库 COPYING；按原样提供，刷机风险自负
EOF
}
# Every subcommand that needs a guest name should fail clearly instead of
# treating a flag as a guest.  -h/--help anywhere prints the help.
# Always show who wrote this, once, unless the output is being captured.
banner

case "${1:-help}" in
    --version|-V) exit 0 ;;
esac
case "${1:-help}" in
    -h|--help) cmd_help; exit 0 ;;
    help)
        case "${2:-}" in
            ports|fwd|forward|network) cmd_help_ports; exit 0 ;;
            *) cmd_help; exit 0 ;;
        esac
        ;;
esac
if [ $# -ge 2 ]; then
    case "$2" in
        -h|--help) cmd_help; exit 0 ;;
    esac
fi

# commands that operate on a guest need one; say so instead of tripping over
# `set -u` further down
case "${1:-help}" in
    start|stop|restart|status|console|rm|remove|image|enable|disable|config|edit|net)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
            printf '  ERROR: %s needs a guest name\n\n' "$1" >&2
            cmd_help
            exit 1
        fi
        ;;
esac

case "${1:-help}" in
    install)   shift; cmd_install "$@" ;;
    uninstall) cmd_uninstall ;;
    create)    shift; cmd_create "$@" ;;
    image)     shift; cmd_image "$@" ;;
    versions|list-releases|releases) cmd_versions ;;
    ports|fwd)  cmd_help_ports ;;
    start)     shift; cmd_start "$@" ;;
    stop)      shift; cmd_stop "$@" ;;
    restart)   shift; cmd_restart "$@" ;;
    list|ls)   cmd_list ;;
    status)    shift; cmd_status "$@" ;;
    console)   shift; cmd_console "$@" ;;
    rm|remove) shift; cmd_rm "$@" ;;
    enable)    shift; cmd_enable "$@" ;;
    disable)   shift; cmd_disable "$@" ;;
    config)    shift; cmd_config "$@" ;;
    edit)      shift; cmd_edit "$@" ;;
    net)       shift; cmd_net "$@" ;;
    selftest)  shift; cmd_selftest "$@" ;;
    mirror)    shift
               case "${1:-}" in
                   --restore|-r) ask_apt_mirror_restore ;;
                   *)            ask_apt_mirror ;;
               esac ;;
    help|-h|--help) cmd_help ;;
    *)         cmd_help; exit 1 ;;
esac
