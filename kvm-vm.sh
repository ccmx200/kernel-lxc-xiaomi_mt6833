#!/bin/bash
# =============================================================================
#  Ubuntu 26.04 KVM guest launcher  (MT6833 / everpal, nVHE KVM)
#
#  Usage:
#     ./kvm-vm.sh start     start the guest (default)
#     ./kvm-vm.sh stop      stop the guest
#     ./kvm-vm.sh status    show state, serial tail, ssh forward
#     ./kvm-vm.sh console   follow the serial console
#
#  Two things matter and are easy to get wrong:
#
#  1. taskset -c 6-7  (pin to the Cortex-A76 big cores)
#     This SoC is big.LITTLE: 6x A55 (0xd05) + 2x A76 (0xd0b) with different
#     ID register values.  If QEMU is left free to migrate, it may probe the
#     host CPU on one core type and then have KVM reject the register writes
#     with EINVAL on the other ->
#        "Failed to put registers after init: Invalid argument"
#     Measured: pinned 3/3 starts succeed, unpinned 0/3.
#
#  2. The firmware must be the NVRAM-free EDK2 build
#     A normal EDK2 writes the pflash variable store with writeback/
#     exclusive stores, which never set ESR_EL2.ISV; this KVM cannot decode
#     those, so the guest wedges.  uefi-code.fd is the NVRAM-free build.
#
#  Everything else is plain QEMU.
# =============================================================================
set -u

VMDIR="${VMDIR:-/root/vm26}"
FWDIR="${FWDIR:-/root/limbo_fw}"
FIRMWARE="$VMDIR/uefi-code.fd"
VARS="$VMDIR/uefi-vars.fd"
VARS_TPL="$FWDIR/edk2_vars.fd"
DISK="$VMDIR/disk.qcow2"
SEED="$VMDIR/seed.img"
LOG=/tmp/kvm.log
ERR=/tmp/kvm.err
PIDF=/tmp/kvm.pid

CPUS=4                      # 4 is the usable maximum; 8 makes the firmware ASSERT
MEM=2048
SSH_PORT=8023
CPUSET="6-7"                # the two Cortex-A76 cores

QEMU=/usr/bin/qemu-system-aarch64

say() { printf '  %s\n' "$*"; }

stop_guest() {
    for p in $(pgrep -f qemu-system-aarch64 2>/dev/null); do
        kill -15 "$p" 2>/dev/null
    done
    sleep 4
    for p in $(pgrep -f qemu-system-aarch64 2>/dev/null); do
        kill -9 "$p" 2>/dev/null
    done
    rm -f "$PIDF"
    say "stopped"
}

start_guest() {
    for f in "$FIRMWARE" "$VARS_TPL" "$DISK" "$SEED"; do
        [ -f "$f" ] || { say "MISSING: $f"; exit 1; }
    done

    stop_guest
    sleep 2
    cp -f "$VARS_TPL" "$VARS"          # fresh NVRAM each boot

    rm -f "$LOG" "$ERR" "$PIDF"
    nohup taskset -c "$CPUSET" "$QEMU" -name ubuntu2604 \
        -M virt,gic-version=3 -cpu max -accel kvm -smp "$CPUS" -m "$MEM" \
        -drive if=pflash,format=raw,unit=0,file="$FIRMWARE",readonly=on \
        -drive if=pflash,format=raw,unit=1,file="$VARS" \
        -drive if=virtio,format=qcow2,file="$DISK" \
        -drive if=virtio,format=raw,readonly=on,file="$SEED" \
        -netdev user,id=n0,hostfwd=tcp:0.0.0.0:${SSH_PORT}-:22 \
        -device virtio-net-pci,netdev=n0 -device virtio-rng-pci \
        -display none -serial file:"$LOG" \
        > "$ERR" 2>&1 &
    echo $! > "$PIDF"
    sleep 6

    local p; p=$(cat "$PIDF")
    if ! kill -0 "$p" 2>/dev/null; then
        say "FAILED: $(head -1 "$ERR" 2>/dev/null)"
        say "hint: is '$CPUSET' a valid cpuset on this device?"
        exit 1
    fi
    say "guest running (pid $p), waiting for login prompt..."
    for _ in $(seq 1 20); do
        grep -aq "login:" "$LOG" 2>/dev/null && break
        sleep 3
    done
    if grep -aq "login:" "$LOG" 2>/dev/null; then
        say "ready:  ssh u0_207@127.0.0.1 -p ${SSH_PORT}   (password: 1)"
    else
        say "not at login yet; try '$0 console'"
    fi
}

show_status() {
    local p=""
    [ -f "$PIDF" ] && p=$(cat "$PIDF")
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        local ut cs
        ut=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null)
        cs=$(awk -v t="$ut" -v c="$(getconf CLK_TCK)" 'BEGIN{printf "%.0f", t/c}')
        say "guest: running (pid $p, cpu ${cs}s)"
    else
        say "guest: not running"
    fi
    say "serial: $(wc -c < "$LOG" 2>/dev/null || echo 0) bytes"
    grep -aq "login:" "$LOG" 2>/dev/null && say "login prompt: present"
    ss -tln 2>/dev/null | grep -q ":${SSH_PORT} " \
        && say "ssh forward: listening on ${SSH_PORT}" \
        || say "ssh forward: not listening"
    say "--- serial tail ---"
    tr -d '\000' < "$LOG" 2>/dev/null | tail -8
}

case "${1:-start}" in
    start)   start_guest ;;
    stop)    stop_guest ;;
    status)  show_status ;;
    console) tail -f "$LOG" | tr -d '\000' ;;
    *)       echo "usage: $0 {start|stop|status|console}"; exit 1 ;;
esac
