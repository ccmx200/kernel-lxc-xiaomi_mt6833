#!/bin/bash
# =============================================================================
#  Ubuntu 26.04 KVM guest launcher  (MT6833 / everpal, nVHE KVM)
#
#  Usage:
#     ./kvm-vm.sh start     start the guest (default)
#     ./kvm-vm.sh stop      stop the guest cleanly
#     ./kvm-vm.sh status    show state, serial tail, ssh banner
#     ./kvm-vm.sh console   follow the serial console
#
#  Notes (these are real, measured constraints - do not "clean them up"):
#   * The firmware must be the NVRAM-free EDK2 build.  A normal EDK2 writes
#     pflash NVRAM with writeback/exclusive stores, which never set
#     ESR_EL2.ISV; this KVM cannot decode those, so the vCPU wedges.
#   * 4 vCPUs is the usable maximum.  8 makes the firmware ASSERT, and
#     fewer than 4 currently fails vCPU creation with EINVAL.
#   * KVM vCPU creation right after a guest exits is flaky, hence the
#     settle delay plus the throwaway warm-up guest.
#   * The NVRAM variable store is refreshed on every start; a stale one
#     makes GRUB load and then hang.
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

SSH_PORT=8023
CPUS=4
MEM=2048

QEMU=/usr/bin/qemu-system-aarch64

say() { printf '  %s\n' "$*"; }

require_files() {
    local missing=0
    for f in "$FIRMWARE" "$VARS_TPL" "$DISK" "$SEED"; do
        if [ ! -f "$f" ]; then
            say "MISSING: $f"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || { say "cannot start: files missing"; exit 1; }
}

stop_guest() {
    if pgrep -f "qemu-system-aarch64" >/dev/null 2>&1; then
        say "stopping guest (graceful)..."
        for p in $(pgrep -f qemu-system-aarch64); do kill -15 "$p" 2>/dev/null; done
        sleep 5
        for p in $(pgrep -f qemu-system-aarch64); do kill -9 "$p" 2>/dev/null; done
        sleep 5
    fi
    rm -f "$PIDF"
    pgrep -f qemu-system-aarch64 >/dev/null 2>&1 \
        && say "warning: qemu still running" || say "stopped"
}

warmup() {
    say "warming up KVM..."
    "$QEMU" -name warmup -M virt,gic-version=3 -cpu max -accel kvm \
        -smp 1 -m 512 -display none -serial null >/dev/null 2>&1 &
    local w=$!
    sleep 5
    kill -15 "$w" 2>/dev/null; sleep 4; kill -9 "$w" 2>/dev/null
    wait "$w" 2>/dev/null
    sleep 2
}

start_guest() {
    require_files
    stop_guest
    cp -f "$VARS_TPL" "$VARS"
    say "fresh NVRAM in place"
    warmup

    rm -f "$LOG" "$ERR" "$PIDF"
    nohup "$QEMU" -name ubuntu2604 \
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
    sleep 8

    local p; p=$(cat "$PIDF")
    if ! kill -0 "$p" 2>/dev/null; then
        say "FAILED: $(head -1 "$ERR" 2>/dev/null)"
        exit 1
    fi
    say "guest running, pid=$p"
    say "waiting for the login prompt..."
    for _ in $(seq 1 20); do
        grep -aq "login:" "$LOG" 2>/dev/null && break
        sleep 3
    done
    if grep -aq "login:" "$LOG" 2>/dev/null; then
        say "ready.  ssh u0_207@127.0.0.1 -p ${SSH_PORT}   (password: 1)"
    else
        say "not at login yet - check '$0 console'"
    fi
}

show_status() {
    local p=""
    [ -f "$PIDF" ] && p=$(cat "$PIDF")
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
        local ut cs
        ut=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null)
        cs=$(awk -v t="$ut" -v c="$(getconf CLK_TCK)" 'BEGIN{printf "%.0f", t/c}')
        say "guest: running (pid $p, cpu ${cs}s)"
    else
        say "guest: not running"
    fi
    say "serial: $(wc -c < "$LOG" 2>/dev/null || echo 0) bytes"
    if grep -aq "login:" "$LOG" 2>/dev/null; then
        say "login prompt: present"
    fi
    if ss -tln 2>/dev/null | grep -q ":${SSH_PORT} "; then
        say "ssh forward: listening on ${SSH_PORT}"
    else
        say "ssh forward: not listening"
    fi
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
