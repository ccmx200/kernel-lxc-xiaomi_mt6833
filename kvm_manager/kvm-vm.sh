#!/bin/bash
# =============================================================================
#  ckvm - KVM guest manager for MT6833 / everpal (nVHE KVM, droidspaces)
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
#  Two hardware facts are baked in; see docs/KVM.md for the measurements:
#   * QEMU must be pinned to one core type (big.LITTLE!) or vCPU creation
#     fails with EINVAL.  Default CPUSET=6-7 (the two Cortex-A76 cores).
#   * The firmware must be the NVRAM-free EDK2 build, otherwise the guest
#     wedges as soon as the firmware writes its variable store.
# =============================================================================
set -u

CKVM_VERSION="1.0"
CKVM_ROOT="${CKVM_ROOT:-/var/lib/ckvm}"
CKVM_FWDIR="${CKVM_FWDIR:-/usr/local/share/ckvm/firmware}"
CKVM_BINDIR="${CKVM_BINDIR:-/usr/local/bin}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
QEMU="${QEMU:-/usr/bin/qemu-system-aarch64}"

# ---- mirrors: NJU for images, USTC for apt; official as the last resort ----
MIRROR_IMAGE_LIST="${MIRROR_IMAGE_LIST:-https://mirror.nju.edu.cn/ubuntu-cloud-images https://cloud-images.ubuntu.com}"
MIRROR_APT="${MIRROR_APT:-https://mirrors.ustc.edu.cn/ubuntu-ports}"

# ---- defaults for a new guest ---------------------------------------------
DEF_CPUS=8
DEF_MEM=2048
DEF_DISK_GB=50
DEF_CPUSET=6-7
DEF_USER=u0
DEF_PASS=1
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
download_url() {
    local url="$1" out="$2" label="${3:-downloading}"
    download_pick_backend >/dev/null

    if [ "$DL_BACKEND" = "aria2c" ]; then
        # -x16 -s16 is aria2's recommended shape for a single large file.
        # --console-log-level=warn keeps aria2 quiet so our own bar shows.
        if [ -t 1 ]; then
            aria2c -x16 -s16 -k1M -c \
                   --console-log-level=warn --summary-interval=0 \
                   --show-console-readout=false --allow-overwrite=true \
                   --file-allocation=none \
                   -d "$(dirname "$out")" -o "$(basename "$out")" "$url" \
                   >/tmp/ckvm-aria2.log 2>&1 &
            local pid=$! i=0
            local total
            total=$(stat -c%s "$out" 2>/dev/null || echo 0)
            while kill -0 "$pid" 2>/dev/null; do
                local cur pct=""
                cur=$(stat -c%s "$out" 2>/dev/null || echo 0)
                if [ "$total" -le 0 ] && [ -f "$out.aria2" ]; then
                    total=$(du -b "$out" 2>/dev/null | cut -f1)
                fi
                pct=$(awk -v c="$cur" -v t="$total" \
                      'BEGIN{ if (t>0) printf "%d", c*100/t; else print "" }')
                ui_tick $((i++)) "$pct" "$label" \
                        "  $(numfmt --to=iec "$cur" 2>/dev/null || echo "$cur")"
                sleep 0.4
            done
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

    # curl fallback, with the same animated bar
    if [ -t 1 ]; then
        curl -fSLk --retry 3 -o "$out.part" "$url" 2>/dev/null &
        local pid=$! i=0
        local total
        total=$(curl -sSLkI "$url" 2>/dev/null | \
                awk 'BEGIN{IGNORECASE=1}/^content-length:/{gsub(/\r/,"");print $2}' | tail -1)
        while kill -0 "$pid" 2>/dev/null; do
            local cur pct=""
            cur=$(stat -c%s "$out.part" 2>/dev/null || echo 0)
            [ -n "$total" ] && pct=$(awk -v c="$cur" -v t="$total" \
                'BEGIN{ if (t>0) printf "%d", c*100/t; else print "" }')
            ui_tick $((i++)) "$pct" "$label" \
                    "  $(numfmt --to=iec "$cur" 2>/dev/null || echo "$cur")"
            sleep 0.4
        done
        wait "$pid"; local rc=$?
        ui_stop
        [ $rc -eq 0 ] && [ -s "$out.part" ] && { mv -f "$out.part" "$out"; return 0; }
        rm -f "$out.part"
        return 1
    fi
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
    local d; d=$(vm_dir "$1")
    [ -f "$d/vm.conf" ] || die "no such guest: $1  (see: ckvm list)"
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
# create
# --------------------------------------------------------------------------
make_seed() {
    local name="$1" d
    d=$(vm_dir "$name")
    load_vm "$name"
    local hash; hash=$(openssl passwd -6 "$VM_PASS")
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
chpasswd:
  expire: false
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
    cat > "$d/meta-data" <<EOF
instance-id: ckvm-$name
local-hostname: $VM_HOSTNAME
EOF

    # host/tap mode: no DHCP server exists, so pin the address in the guest
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
        cloud-localds --network-config="$d/network-config" \
            "$d/seed.img" "$d/user-data" "$d/meta-data"
        say "seed.img written (user $VM_USER / password $VM_PASS, static ${TAP_IP_GUEST})"
    else
        cloud-localds "$d/seed.img" "$d/user-data" "$d/meta-data"
        say "seed.img written (user $VM_USER / password $VM_PASS)"
    fi
}

fetch_image() {
    local name="$1" d img url ok=0 fmt
    ensure_aria2 >/dev/null 2>&1 || true
    d=$(vm_dir "$name"); img="$d/disk.qcow2"
    load_vm "$name"
    for url in $(image_urls "$UBUNTU_REL"); do
        say "source: $url"
        if download_url "$url" "$d/base.img" "Ubuntu ${UBUNTU_REL} arm64"; then
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
        qemu-img convert -f "$fmt" -O qcow2 "$d/base.img" "$img"
        rm -f "$d/base.img"
    fi
    qemu-img resize "$img" "${DISK_GB}G" >/dev/null
    say "image ready"
    return 0
}

cmd_create() {
    need_root
    local name="" cpus="$DEF_CPUS" mem="$DEF_MEM" disk="$DEF_DISK_GB"
    local rel="$DEF_REL" port=""
    local net_mode="$DEF_NET_MODE" forwards="$DEF_FORWARDS" fwd_set=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --cpus) cpus="$2"; shift 2 ;;
            --mem)  mem="$2";  shift 2 ;;
            --disk) disk="$2"; shift 2 ;;
            --rel)  rel="$2";  shift 2 ;;
            --port) port="$2"; shift 2 ;;
            --net)  net_mode="$2"; shift 2 ;;
            --fwd)  forwards="$2"; fwd_set=1; shift 2 ;;
            *)      name="$1"; shift ;;
        esac
    done
    [ -n "$name" ] || die "usage: ckvm create <name> [--cpus N] [--mem MB] [--disk GB] [--rel 26.04] [--port N] [--net user|host] [--fwd 22,80,443]"
    case "$net_mode" in
        user|host) ;;
        *) die "--net must be 'user' or 'host'" ;;
    esac
    # host mode needs no port forwards unless asked for extra ones
    [ "$net_mode" = "host" ] && [ "$fwd_set" = 0 ] && forwards=""
    valid_name "$name"
    # a directory without vm.conf is a half-finished create, not an existing
    # guest, so allow it to be resumed
    if [ -f "$(vm_conf "$name")" ]; then
        die "guest '$name' already exists (use: ckvm rm $name)"
    fi

    check_firmware || return 1
    local d; d=$(vm_dir "$name")
    mkdir -p "$d"
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
CPUSET=$DEF_CPUSET
VM_USER=$DEF_USER
VM_PASS=$DEF_PASS
VM_HOSTNAME=$name
# user = QEMU NAT with the forwards below (works everywhere, needs no tap)
# host = tap device, guest gets $TAP_IP_GUEST and runs its own sshd
NET_MODE=$net_mode
FORWARDS=$forwards
EOF

    cp -f "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd" "$d/uefi-code.fd"
    [ -f "$CKVM_FWDIR/edk2_vars.fd" ] || die "missing edk2_vars.fd in $CKVM_FWDIR"
    cp -f "$CKVM_FWDIR/edk2_vars.fd" "$d/uefi-vars.fd"

    say "guest '$name' created (port $port, ${cpus} vCPU, ${mem} MiB, ${disk}G)"
    say "network: $net_mode${forwards:+ (forwards: $forwards)}"
    say "download backend: $(download_pick_backend)"
    if [ -s "$d/disk.qcow2" ]; then
        say "disk already present; skipping the download"
        qemu-img resize "$d/disk.qcow2" "${disk}G" >/dev/null
    else
        fetch_image "$name" || warn "image download failed; run 'ckvm image $name' later"
    fi
    make_seed "$name"
    say ""
    say "start it with:  ckvm start $name"
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
                    warn "host port $h is already in use"
                    warn "  (the container's own sshd is usually on 22; pick another with --port/--fwd)"
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
        exec taskset -c "$CPUSET" "${args[@]}"
    fi

    nohup taskset -c "$CPUSET" "${args[@]}" > "$d/qemu.err" 2>&1 &
    echo $! > "$(vm_pid "$name")"
    sleep 6
    local p; p=$(cat "$(vm_pid "$name")")
    if ! kill -0 "$p" 2>/dev/null; then
        [ -n "$tap" ] && tap_down "$name"
        die "failed to start: $(head -1 "$d/qemu.err")"
    fi
    say "guest '$name' running (pid $p, ${CPUS} vCPU, ${MEM} MiB, cpuset $CPUSET)"
    show_access "$name"
}

# how to reach this guest
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
    tr -d '\000' < "$(vm_log "$name")" 2>/dev/null | tail -8
}

cmd_console() {
    load_vm "$1"
    tail -f "$(vm_log "$1")" | tr -d '\000'
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
REPO_GITHUB="https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager"
REPO_GITHUB_CN="https://git.yylx.win/github.com/ccmx200/kernel-lxc-xiaomi_mt6833/raw/resukisu/kvm_manager"
# name=url pairs so `-cn` can fall through them in order if one is down
REPO_MIRRORS_CN="git.yylx.win=https://git.yylx.win/github.com/ccmx200/kernel-lxc-xiaomi_mt6833/raw/resukisu/kvm_manager ghproxy.net=https://ghproxy.net/https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager gh-proxy.com=https://gh-proxy.com/https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager"

CKVM_REPO=""          # resolved by resolve_repo()
CKVM_USING_CN=0       # 1 when any acceleration is in play
GH_UPSTREAM="https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager"
GH_UPSTREAM_PATH="github.com/ccmx200/kernel-lxc-xiaomi_mt6833/raw/resukisu/kvm_manager"

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
    local accel="${CKVM_ACCEL:-0}"
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
    say "try:  ckvm create ubuntu26 && ckvm start ubuntu26 && ckvm list"
}
cmd_uninstall() {
    need_root
    systemctl disable --now 'ckvm@*' >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/ckvm@.service" "$CKVM_BINDIR/ckvm"
    systemctl daemon-reload
    say "removed ckvm (guest data in $CKVM_ROOT kept; delete it manually)"
}

cmd_help() {
    cat <<EOF
ckvm $CKVM_VERSION - KVM guest manager (MT6833 / everpal)

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

  ckvm create <name> [options]     create a guest (downloads the image)
        --cpus N    vCPU count          (default $DEF_CPUS)
        --mem  MB   memory              (default $DEF_MEM)
        --disk GB   disk size           (default $DEF_DISK_GB)
        --rel  V    Ubuntu release      (default $DEF_REL)
        --port N    host ssh port       (default: first free from $DEF_PORT_BASE)
        --net  M    user | host         (default $DEF_NET_MODE)
                      user: QEMU NAT, reach it via forwarded ports
                      host: tap device, guest gets its own IP, runs its own
                            sshd; nothing is forwarded
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

  ckvm net [name]                  show the container / guest network layout
  ckvm config [name]               show global or per-guest settings
  ckvm edit <name>                 edit a guest's vm.conf

Files: $CKVM_ROOT/<name>/    firmware: $CKVM_FWDIR
EOF
}
case "${1:-help}" in
    install)   shift; cmd_install "$@" ;;
    uninstall) cmd_uninstall ;;
    create)    shift; cmd_create "$@" ;;
    image)     shift; cmd_image "$@" ;;
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
    help|-h|--help) cmd_help ;;
    *)         cmd_help; exit 1 ;;
esac
