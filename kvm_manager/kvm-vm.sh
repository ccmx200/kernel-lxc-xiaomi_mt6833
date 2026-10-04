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

say()  { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '  ERROR: %s\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }

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
    cloud-localds "$d/seed.img" "$d/user-data" "$d/meta-data"
    say "seed.img written (user $VM_USER / password $VM_PASS)"
}

fetch_image() {
    local name="$1" d img url ok=0 fmt
    d=$(vm_dir "$name"); img="$d/disk.qcow2"
    load_vm "$name"
    for url in $(image_urls "$UBUNTU_REL"); do
        say "downloading $url"
        if curl -fSLk --retry 2 --progress-bar -o "$d/base.img.part" "$url"; then
            ok=1; break
        fi
        say "  mirror failed, trying the next one"
    done
    [ "$ok" = 1 ] || return 1
    mv -f "$d/base.img.part" "$d/base.img"
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

    while [ $# -gt 0 ]; do
        case "$1" in
            --cpus) cpus="$2"; shift 2 ;;
            --mem)  mem="$2";  shift 2 ;;
            --disk) disk="$2"; shift 2 ;;
            --rel)  rel="$2";  shift 2 ;;
            --port) port="$2"; shift 2 ;;
            *)      name="$1"; shift ;;
        esac
    done
    [ -n "$name" ] || die "usage: ckvm create <name> [--cpus N] [--mem MB] [--disk GB] [--rel 26.04] [--port N]"
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
EOF

    cp -f "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd" "$d/uefi-code.fd"
    [ -f "$CKVM_FWDIR/edk2_vars.fd" ] || die "missing edk2_vars.fd in $CKVM_FWDIR"
    cp -f "$CKVM_FWDIR/edk2_vars.fd" "$d/uefi-vars.fd"

    say "guest '$name' created (port $port, ${cpus} vCPU, ${mem} MiB, ${disk}G)"
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

    rm -f "$(vm_log "$name")" "$d/qemu.err"
    local args=(
        "$QEMU" -name "$name"
        -M virt,gic-version=3 -cpu max -accel kvm -smp "$CPUS" -m "$MEM"
        -drive if=pflash,format=raw,unit=0,file="$d/uefi-code.fd",readonly=on
        -drive if=pflash,format=raw,unit=1,file="$d/uefi-vars.fd"
        -drive if=virtio,format=qcow2,file="$d/disk.qcow2"
        -drive if=virtio,format=raw,readonly=on,file="$d/seed.img"
        -netdev user,id=n0,hostfwd=tcp:0.0.0.0:${PORT}-:22
        -device virtio-net-pci,netdev=n0 -device virtio-rng-pci
        -display none -serial file:"$(vm_log "$name")"
    )

    if [ "$fg" = 1 ]; then
        exec taskset -c "$CPUSET" "${args[@]}"
    fi

    nohup taskset -c "$CPUSET" "${args[@]}" > "$d/qemu.err" 2>&1 &
    echo $! > "$(vm_pid "$name")"
    sleep 6
    local p; p=$(cat "$(vm_pid "$name")")
    kill -0 "$p" 2>/dev/null || die "failed to start: $(head -1 "$d/qemu.err")"
    say "guest '$name' running (pid $p, ${CPUS} vCPU, ${MEM} MiB, cpuset $CPUSET)"
    say "ssh ${VM_USER}@127.0.0.1 -p ${PORT}   (password: ${VM_PASS})"
}

cmd_stop() {
    need_root
    local name="$1" p
    if p=$(running_pid "$name"); then
        kill -15 "$p" 2>/dev/null; sleep 4
        kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
        rm -f "$(vm_pid "$name")"
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
          printf '  %-16s %-8s %-6s %-8s %-7s %-6s %s\n' \
                 "$name" "$state" "$CPUS" "$MEM" "${DISK_GB}G" "$PORT" \
                 "ssh ${VM_USER}@127.0.0.1 -p ${PORT}" )
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

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/ccmx200/kernel-lxc-xiaomi_mt6833/resukisu/kvm_manager}"

cmd_install() {
    need_root
    mkdir -p "$CKVM_ROOT" "$CKVM_FWDIR"

    # when the script was piped in, $0 is not the file we want to install
    if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$CKVM_BINDIR/ckvm" ]; then
        install -m 0755 "$0" "$CKVM_BINDIR/ckvm"
    else
        say "fetching the latest ckvm"
        curl -fSLk --retry 3 -o "$CKVM_BINDIR/ckvm" "$REPO_RAW/kvm-vm.sh" \
            || die "download failed: $REPO_RAW/kvm-vm.sh"
        chmod 0755 "$CKVM_BINDIR/ckvm"
    fi
    say "installed: $CKVM_BINDIR/ckvm"

    # firmware: prefer the repo copy (it ships next to the script), then
    # anything already staged on this device
    local src="" cand
    for cand in "$CKVM_FWDIR/edk2_qemu_aarch64_nonvram.fd" \
                "$(dirname "$0")/edk2_qemu_aarch64_nonvram.fd"; do
        [ -f "$cand" ] && { src="$cand"; break; }
    done
    if [ -z "$src" ]; then
        src=$(find_firmware) || src=""
    fi

    if [ -n "$src" ]; then
        install_firmware "$src"
    else
        say "firmware not bundled locally; fetching it from the repo"
        local ok=0 f
        for f in edk2_qemu_aarch64_nonvram.fd edk2_vars.fd; do
            if curl -fSLk --retry 3 -o "$CKVM_FWDIR/$f.part" "$REPO_RAW/$f"; then
                mv -f "$CKVM_FWDIR/$f.part" "$CKVM_FWDIR/$f"
                ok=1
            else
                rm -f "$CKVM_FWDIR/$f.part"
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

  ckvm install                     install to $CKVM_BINDIR/ckvm + systemd unit
  ckvm uninstall                   remove the binary and unit

  ckvm create <name> [options]     create a guest (downloads the image)
        --cpus N    vCPU count          (default $DEF_CPUS)
        --mem  MB   memory              (default $DEF_MEM)
        --disk GB   disk size           (default $DEF_DISK_GB)
        --rel  V    Ubuntu release      (default $DEF_REL)
        --port N    host ssh port       (default: first free from $DEF_PORT_BASE)

  ckvm image <name>                (re)download the guest image
  ckvm start <name> [-f]           start (foreground with -f)
  ckvm stop|restart <name>
  ckvm list                        all guests and their state
  ckvm status <name>               detail + serial tail
  ckvm console <name>              follow the serial console
  ckvm rm <name> [-f]              delete a guest

  ckvm enable <name>               enable + start under systemd
  ckvm disable <name>              disable the systemd unit

  ckvm config [name]               show global or per-guest settings
  ckvm edit <name>                 edit a guest's vm.conf

Files: $CKVM_ROOT/<name>/    firmware: $CKVM_FWDIR
EOF
}

case "${1:-help}" in
    install)   cmd_install ;;
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
    help|-h|--help) cmd_help ;;
    *)         cmd_help; exit 1 ;;
esac
