#!/usr/bin/env bash
#
# Boot the prepared Proxmox VE image and wait until it is ready.
#
# Every run gets a throwaway qcow2 overlay on top of the built image, so tests
# that leave a mess behind cannot affect the next run.
#
source "$(dirname "$0")/common.sh"

require_tools qemu-system-x86_64 qemu-img curl

[ -s "${PVE_IMAGE}" ] || die "${PVE_IMAGE} not found, run scripts/build-image.sh first"

if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    log "a test VM is already running (pid $(cat "${PID_FILE}"))"
else
    log "creating a fresh overlay on ${PVE_IMAGE}"
    rm -f "${RUN_IMAGE}"
    qemu-img create -q -f qcow2 -F qcow2 -b "${PVE_IMAGE}" "${RUN_IMAGE}" >/dev/null

    log "starting the VM (api on 127.0.0.1:${API_PORT}, ssh on 127.0.0.1:${SSH_PORT})"
    rm -f "${RUN_LOG}"
    # shellcheck disable=SC2046
    qemu-system-x86_64 \
        $(accel_args) \
        -smp "${VM_CPUS}" \
        -m "${VM_MEMORY}" \
        -drive "if=virtio,file=${RUN_IMAGE},format=qcow2,cache=unsafe" \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${API_PORT}-:8006,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -display none \
        -serial "file:${RUN_LOG}" \
        -pidfile "${PID_FILE}" \
        -daemonize
fi

"$(dirname "$0")/wait-ready.sh"
