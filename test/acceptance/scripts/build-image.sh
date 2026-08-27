#!/usr/bin/env bash
#
# Build a bootable single node Proxmox VE image for the acceptance tests.
#
# Takes a stock Debian 13 cloud image, boots it once under QEMU with a
# cloud-init seed that installs Proxmox VE and the test fixtures, and leaves a
# compressed qcow2 behind at test/acceptance/.build/proxmox-ve-test.qcow2.
#
# Roughly 10 minutes and ~2GB of downloads on a cold run; the result is meant
# to be cached.
#
source "$(dirname "$0")/common.sh"

require_tools qemu-system-x86_64 qemu-img xorriso curl base64

BUILD_TIMEOUT=${PVE_TEST_BUILD_TIMEOUT:-3600}

mkdir -p "${BUILD_DIR}"

if [ -s "${PVE_IMAGE}" ] && [ "${PVE_TEST_FORCE_REBUILD:-0}" != "1" ]; then
    log "${PVE_IMAGE} already exists, nothing to do (PVE_TEST_FORCE_REBUILD=1 to rebuild)"
    exit 0
fi

log "downloading ${DEBIAN_IMAGE_URL}"
curl -fL --retry 3 -C - -o "${BASE_IMAGE}" "${DEBIAN_IMAGE_URL}"

WORK_IMAGE=${BUILD_DIR}/work.qcow2
rm -f "${WORK_IMAGE}"
cp "${BASE_IMAGE}" "${WORK_IMAGE}"
qemu-img resize "${WORK_IMAGE}" "${VM_DISK}"

log "building the cloud-init seed"
SEED_DIR=${BUILD_DIR}/seed
rm -rf "${SEED_DIR}"
mkdir -p "${SEED_DIR}"

b64() { base64 <"$1" | tr -d '\n'; }

cat >"${SEED_DIR}/meta-data" <<META
instance-id: ${NODE_NAME}-build
local-hostname: ${NODE_NAME}
META

cat >"${SEED_DIR}/user-data" <<USERDATA
#cloud-config
hostname: ${NODE_NAME}
fqdn: ${NODE_NAME}.${NODE_DOMAIN}
preserve_hostname: false
manage_etc_hosts: false
ssh_pwauth: true
disable_root: false
chpasswd:
  expire: false
  users:
    - name: root
      password: ${ROOT_PASSWORD}
      type: text
write_files:
  - path: /root/pve-build.conf
    permissions: '0600'
    content: |
      NODE_NAME=${NODE_NAME}
      NODE_DOMAIN=${NODE_DOMAIN}
      ROOT_PASSWORD=${ROOT_PASSWORD}
      BRIDGE_CIDR=${BRIDGE_CIDR}
      PVE_VERSION=${PVE_VERSION}
      PVE_SUITE=${PVE_SUITE}
      PVE_KEYRING_URL=${PVE_KEYRING_URL}
  - path: /root/provision.sh
    encoding: b64
    permissions: '0755'
    content: $(b64 "${TEST_DIR}/guest/provision.sh")
  - path: /root/pve-test-hosts.sh
    encoding: b64
    permissions: '0755'
    content: $(b64 "${TEST_DIR}/guest/pve-test-hosts.sh")
  - path: /root/pve-test-bootstrap.sh
    encoding: b64
    permissions: '0755'
    content: $(b64 "${TEST_DIR}/guest/pve-test-bootstrap.sh")
runcmd:
  - [ bash, /root/provision.sh ]
USERDATA

rm -f "${SEED_IMAGE}"
xorriso -as mkisofs -quiet -o "${SEED_IMAGE}" -V cidata -J -r "${SEED_DIR}"

log "booting the installer VM for Proxmox VE ${PVE_VERSION} (${PVE_SUITE}), console log: ${BUILD_LOG}"
rm -f "${BUILD_LOG}"
# shellcheck disable=SC2046
qemu-system-x86_64 \
    $(accel_args) \
    -smp "${VM_CPUS}" \
    -m "${VM_MEMORY}" \
    -drive "if=virtio,file=${WORK_IMAGE},format=qcow2,cache=writeback" \
    -drive "if=virtio,file=${SEED_IMAGE},format=raw,readonly=on" \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -display none \
    -serial "file:${BUILD_LOG}" \
    -no-reboot \
    -pidfile "${BUILD_DIR}/build.pid" &
QEMU_PID=$!

cleanup() { kill "${QEMU_PID}" 2>/dev/null || true; }
trap cleanup EXIT

status=""
deadline=$(( $(date +%s) + BUILD_TIMEOUT ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
    if [ -f "${BUILD_LOG}" ]; then
        if grep -q "PVE_BUILD_OK" "${BUILD_LOG}"; then status=ok; break; fi
        if grep -q "PVE_BUILD_FAIL" "${BUILD_LOG}"; then status=fail; break; fi
    fi
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then status=died; break; fi
    sleep 10
done

case "${status}" in
    ok)   log "provisioning finished, waiting for the VM to power off" ;;
    fail) tail -n 60 "${BUILD_LOG}" >&2; die "provisioning failed, see ${BUILD_LOG}" ;;
    died) tail -n 60 "${BUILD_LOG}" >&2; die "QEMU exited before provisioning finished, see ${BUILD_LOG}" ;;
    *)    tail -n 60 "${BUILD_LOG}" >&2; die "timed out after ${BUILD_TIMEOUT}s, see ${BUILD_LOG}" ;;
esac

for _ in $(seq 1 60); do
    kill -0 "${QEMU_PID}" 2>/dev/null || break
    sleep 2
done
kill "${QEMU_PID}" 2>/dev/null || true
wait "${QEMU_PID}" 2>/dev/null || true
trap - EXIT

# Compacted but deliberately NOT compressed (-c).  A compressed qcow2 has to
# be inflated on every read, which made the first boot take ten minutes; the
# Actions cache zstd-compresses the file on upload anyway, so -c cost runtime
# performance and bought very little cache size.
log "compacting the image"
rm -f "${PVE_IMAGE}"
qemu-img convert -O qcow2 "${WORK_IMAGE}" "${PVE_IMAGE}"
rm -f "${WORK_IMAGE}"

log "built ${PVE_IMAGE} ($(du -h "${PVE_IMAGE}" | cut -f1))"
