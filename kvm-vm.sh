#!/bin/bash
# =============================================================================
#  Ubuntu KVM guest manager for MT6833 / everpal (nVHE KVM)
#
#  Usage:
#     ./kvm-vm.sh setup     download image + firmware, create the guest
#     ./kvm-vm.sh start     start the guest
#     ./kvm-vm.sh stop      stop it
#     ./kvm-vm.sh status    state + serial tail + ssh forward
#     ./kvm-vm.sh console   follow the serial console
#     ./kvm-vm.sh config    show the current settings
#     ./kvm-vm.sh edit      open the settings file in $EDITOR
#
#  Settings live in  <vmdir>/vm.conf  and are safe to edit by hand.
# =============================================================================
set -u

VMDIR="${VMDIR:-/root/vm26}"
CONF="$VMDIR/vm.conf"
FWSOURCE="${FWSOURCE:-/sdcard/limbo_fw/edk2_qemu_aarch64_nonvram.fd}"
VARS_TPL=${VARS_TPL:-/root/limbo_fw/edk2_vars.fd}
QEMU=/usr/bin/qemu-system-aarch64

say() { printf '  %s\n' "$*"; }
die() { printf '  ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ defaults
REL="${REL:-26.04}"
CPUS="${CPUS:-8}"
MEM="${MEM:-2048}"
DISK_GB="${DISK_GB:-50}"
SSH_PORT="${SSH_PORT:-8023}"
CPUSET="${CPUSET:-6-7}"
USERNAME="${USERNAME:-u0_207}"
PASSWORD="${PASSWORD:-1}"
HOSTNAME="${HOSTNAME:-ubuntu}"

load_conf() {
    # create the settings file on first use so it is always editable
    [ -f "$CONF" ] || save_conf >/dev/null 2>&1
    [ -f "$CONF" ] && . "$CONF"
}

save_conf() {
    mkdir -p "$VMDIR"
    cat > "$CONF" <<EOF
# kvm-vm settings - edit freely, or run: $0 edit
REL=$REL
CPUS=$CPUS
MEM=$MEM
DISK_GB=$DISK_GB
SSH_PORT=$SSH_PORT
# Pin to physical cores.  This SoC is big.LITTLE (6x A55 + 2x A76) and KVM
# exposes different ID registers depending on which core QEMU runs on, so
# leaving it unpinned makes vCPU creation fail with EINVAL.  Cores 6,7 are
# the two Cortex-A76 big cores.
CPUSET=$CPUSET
USERNAME=$USERNAME
PASSWORD=$PASSWORD
HOSTNAME=$HOSTNAME
EOF
    say "wrote $CONF"
}

# --------------------------------------------------------------- downloaders
download_image() {
    local img="$VMDIR/disk.qcow2"
    [ -f "$img" ] && { say "image already present"; return 0; }
    local url="https://cloud-images.ubuntu.com/releases/${REL}/release/ubuntu-${REL}-server-cloudimg-arm64.img"
    say "downloading Ubuntu ${REL} arm64 cloud image"
    say "  $url"
    mkdir -p "$VMDIR"
    curl -fSLk --retry 3 --progress-bar -o "$VMDIR/base.img.part" "$url" \
        || die "download failed"
    mv "$VMDIR/base.img.part" "$VMDIR/base.img"
    local fmt
    fmt=$(qemu-img info --output=json "$VMDIR/base.img" | \
          python3 -c "import sys,json;print(json.load(sys.stdin)['format'])")
    if [ "$fmt" = "qcow2" ]; then
        mv -f "$VMDIR/base.img" "$img"
    else
        qemu-img convert -f "$fmt" -O qcow2 "$VMDIR/base.img" "$img"
        rm -f "$VMDIR/base.img"
    fi
    qemu-img resize "$img" "${DISK_GB}G"
    say "image ready: $(qemu-img info "$img" | sed -n 2p | tr -s ' ')"
}

download_firmware() {
    # The NVRAM-free EDK2 is not in any git repo (Limbo ships it inside its
    # APK).  We therefore take it from wherever it already exists on this
    # device, in order of convenience.
    [ -f "$VMDIR/uefi-code.fd" ] && [ -f "$VMDIR/uefi-vars.fd" ] && {
        say "firmware already present"; return 0; }
    say "looking for the NVRAM-free EDK2 firmware"

    local found=""
    for c in "$FWSOURCE" \
             /root/limbo_fw/edk2_qemu_aarch64_nonvram.fd \
             /sdcard/limbo_fw/edk2_qemu_aarch64_nonvram.fd ; do
        [ -f "$c" ] && { found="$c"; break; }
    done

    if [ -z "$found" ]; then
        say "  not found locally."
        say "  It lives on the Android side of this device, inside Limbo's"
        say "  app data.  From Termux (with root) run:"
        say "     su -c 'mkdir -p /sdcard/limbo_fw && cp \\"
        say "        /data/data/com.limbo.emu.main.arm/cache/limbo/edk2/*.fd \\"
        say "        /sdcard/limbo_fw/'"
        say "  then copy them into $VMDIR/ as uefi-code.fd and uefi-vars.fd:"
        say "     su -c 'cp /sdcard/limbo_fw/edk2_qemu_aarch64_nonvram.fd $VMDIR/uefi-code.fd'"
        say "     su -c 'cp /sdcard/limbo_fw/edk2_vars.fd      $VMDIR/uefi-vars.fd'"
        return 1
    fi

    say "  using $found"
    local dir; dir=$(dirname "$found")
    cp -f "$found" "$VMDIR/uefi-code.fd"
    if [ -f "$dir/edk2_vars.fd" ]; then
        cp -f "$dir/edk2_vars.fd" "$VMDIR/uefi-vars.fd"
    elif [ -f "$dir/../edk2_vars.fd" ]; then
        cp -f "$dir/../edk2_vars.fd" "$VMDIR/uefi-vars.fd"
    else
        say "  warning: edk2_vars.fd not found next to the firmware"
    fi
    mkdir -p /root/limbo_fw
    cp -f "$found" /root/limbo_fw/edk2_qemu_aarch64_nonvram.fd
    [ -f "$VMDIR/uefi-vars.fd" ] && cp -f "$VMDIR/uefi-vars.fd" /root/limbo_fw/edk2_vars.fd
    say "  firmware installed"
}

make_seed() {
    local hash
    hash=$(openssl passwd -6 "$PASSWORD")
    cat > "$VMDIR/user-data" <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: true
users:
  - name: $USERNAME
    gecos: $USERNAME
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
package_update: false
package_upgrade: false
EOF
    cat > "$VMDIR/meta-data" <<EOF
instance-id: kvm-${HOSTNAME}
local-hostname: $HOSTNAME
EOF
    cloud-localds "$VMDIR/seed.img" "$VMDIR/user-data" "$VMDIR/meta-data"
    say "seed.img written (user $USERNAME)"
}

# ------------------------------------------------------------------- actions
do_setup() {
    load_conf
    save_conf
    mkdir -p "$VMDIR"
    download_image
    make_seed
    download_firmware || {
        say ""
        say "image and seed are ready; only the firmware is missing."
        say "re-run '$0 setup' once it is in place."
        return 1
    }
    say ""
    say "setup complete.  start it with: $0 start"
}

stop_guest() {
    for p in $(pgrep -f qemu-system-aarch64 2>/dev/null); do kill -15 "$p" 2>/dev/null; done
    sleep 4
    for p in $(pgrep -f qemu-system-aarch64 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    rm -f /tmp/kvm.pid
    say "stopped"
}

start_guest() {
    load_conf
    for f in "$VMDIR/uefi-code.fd" "$VMDIR/uefi-vars.fd" "$VMDIR/disk.qcow2" "$VMDIR/seed.img"; do
        [ -f "$f" ] || die "missing $f  (run: $0 setup)"
    done
    stop_guest; sleep 2
    # refresh the NVRAM store from the pristine template so a stale one can
    # never wedge GRUB
    [ -f "$VARS_TPL" ] && cp -f "$VARS_TPL" "$VMDIR/uefi-vars.fd"

    rm -f /tmp/kvm.log /tmp/kvm.err /tmp/kvm.pid
    nohup taskset -c "$CPUSET" "$QEMU" -name "$HOSTNAME" \
        -M virt,gic-version=3 -cpu max -accel kvm -smp "$CPUS" -m "$MEM" \
        -drive if=pflash,format=raw,unit=0,file="$VMDIR/uefi-code.fd",readonly=on \
        -drive if=pflash,format=raw,unit=1,file="$VMDIR/uefi-vars.fd" \
        -drive if=virtio,format=qcow2,file="$VMDIR/disk.qcow2" \
        -drive if=virtio,format=raw,readonly=on,file="$VMDIR/seed.img" \
        -netdev user,id=n0,hostfwd=tcp:0.0.0.0:${SSH_PORT}-:22 \
        -device virtio-net-pci,netdev=n0 -device virtio-rng-pci \
        -display none -serial file:/tmp/kvm.log \
        > /tmp/kvm.err 2>&1 &
    echo $! > /tmp/kvm.pid
    sleep 6
    local p; p=$(cat /tmp/kvm.pid)
    kill -0 "$p" 2>/dev/null || die "failed to start: $(head -1 /tmp/kvm.err)"
    say "guest running (pid $p, ${CPUS} vCPU, ${MEM} MiB, cpuset $CPUSET)"
    say "waiting for the login prompt..."
    for _ in $(seq 1 20); do
        grep -aq "login:" /tmp/kvm.log 2>/dev/null && break
        sleep 3
    done
    if grep -aq "login:" /tmp/kvm.log 2>/dev/null; then
        say "ready:  ssh ${USERNAME}@127.0.0.1 -p ${SSH_PORT}   (password: ${PASSWORD})"
    else
        say "not at login yet; try '$0 console'"
    fi
}

show_status() {
    load_conf
    local p=""
    [ -f /tmp/kvm.pid ] && p=$(cat /tmp/kvm.pid)
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        local ut cs aff
        ut=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)
        cs=$(awk -v t="$ut" -v c="$(getconf CLK_TCK)" 'BEGIN{printf "%.0f", t/c}')
        aff=$(taskset -pc "$p" 2>/dev/null | sed 's/.*: //')
        say "guest:  running (pid $p, cpu ${cs}s, affinity $aff)"
    else
        say "guest:  not running"
    fi
    say "config: ${CPUS} vCPU, ${MEM} MiB, disk ${DISK_GB}G, ssh port ${SSH_PORT}"
    say "serial: $(wc -c < /tmp/kvm.log 2>/dev/null || echo 0) bytes"
    grep -aq "login:" /tmp/kvm.log 2>/dev/null && say "login prompt: present"
    ss -tln 2>/dev/null | grep -q ":${SSH_PORT} " \
        && say "ssh forward: listening on ${SSH_PORT}" \
        || say "ssh forward: not listening"
    say "--- serial tail ---"
    tr -d '\000' < /tmp/kvm.log 2>/dev/null | tail -8
}

show_config() {
    load_conf
    say "config file: $CONF"
    say ""
    [ -f "$CONF" ] && cat "$CONF" || say "(not created yet - run '$0 setup')"
}

case "${1:-start}" in
    setup)   do_setup ;;
    start)   start_guest ;;
    stop)    stop_guest ;;
    status)  show_status ;;
    console) tail -f /tmp/kvm.log | tr -d '\000' ;;
    config)  show_config ;;
    edit)    ${EDITOR:-vi} "$CONF" ;;
    *)       echo "usage: $0 {setup|start|stop|status|console|config|edit}"; exit 1 ;;
esac
