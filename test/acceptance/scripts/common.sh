# Shared configuration for the Proxmox VE acceptance test environment.
# Sourced by the other scripts in this directory; not meant to be run.

set -euo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO_DIR=$(cd "${TEST_DIR}/../.." && pwd)
BUILD_DIR=${PVE_TEST_BUILD_DIR:-${TEST_DIR}/.build}

# The node name is hardcoded in proxmox/resource_vm_qemu_test.go
# (testAccProxmoxTargetNode), so the VM has to answer to exactly this name.
NODE_NAME=${PVE_TEST_NODE_NAME:-testproxmox}
NODE_DOMAIN=${PVE_TEST_NODE_DOMAIN:-pve.test}

# Throwaway credentials for a throwaway VM that only ever listens on loopback.
ROOT_PASSWORD=${PVE_TEST_ROOT_PASSWORD:-proxmox-acctest}

# Ports forwarded from the host into the test VM.
API_PORT=${PVE_TEST_API_PORT:-8006}
SSH_PORT=${PVE_TEST_SSH_PORT:-2222}

# Resources for the VM that runs Proxmox itself.  It has to be big enough to
# start a handful of small guests of its own.
VM_MEMORY=${PVE_TEST_MEMORY:-8192}
VM_CPUS=${PVE_TEST_CPUS:-2}
VM_DISK=${PVE_TEST_DISK:-32G}

# Address of the port-less vmbr0 bridge inside the VM, used by the PXE test.
BRIDGE_CIDR=${PVE_TEST_BRIDGE_CIDR:-10.10.10.1/24}

# A single node cluster, so ha-manager answers at all.  HA is the most used
# non-default attribute in the configurations this provider actually serves,
# and it needs corosync quorum before any of it works -- a standalone node
# rejects every HA call.  One node is quorate on its own; nothing fails over,
# but the API surface the provider drives is the same.
CLUSTER_NAME=${PVE_TEST_CLUSTER_NAME:-acctest}
HA_GROUP=${PVE_TEST_HA_GROUP:-acctest-ha}

# Which Proxmox VE major version to build.  Production is on 8 and the target
# is 9, so both are buildable and the two images can coexist.
PVE_VERSION=${PVE_TEST_PVE_VERSION:-9}
case "${PVE_VERSION}" in
    9)
        PVE_SUITE=trixie
        # The trixie pve-no-subscription repo currently serves the 9.2 line.
        DEFAULT_EXPECT_VERSION=9.2
        DEFAULT_IMAGE_URL=https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
        DEFAULT_KEYRING_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
        ;;
    8)
        PVE_SUITE=bookworm
        # 8.4 is the final Proxmox VE 8 release, so bookworm stays on it.
        DEFAULT_EXPECT_VERSION=8.4
        DEFAULT_IMAGE_URL=https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
        DEFAULT_KEYRING_URL=https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
        ;;
    *)
        echo "[pve-test] ERROR: PVE_TEST_PVE_VERSION must be 8 or 9" >&2
        exit 1
        ;;
esac

# Checked at boot and reported, not pinned: apt installs whatever the suite
# currently has, and we want a loud warning if that ever stops being 8.4/9.2
# rather than a silent version drift.
PVE_EXPECT_VERSION=${PVE_TEST_EXPECT_VERSION:-${DEFAULT_EXPECT_VERSION}}

DEBIAN_IMAGE_URL=${PVE_TEST_DEBIAN_IMAGE_URL:-${DEFAULT_IMAGE_URL}}
PVE_KEYRING_URL=${PVE_TEST_KEYRING_URL:-${DEFAULT_KEYRING_URL}}

BASE_IMAGE=${BUILD_DIR}/$(basename "${DEBIAN_IMAGE_URL}")
PVE_IMAGE=${PVE_TEST_IMAGE:-${BUILD_DIR}/proxmox-ve-${PVE_VERSION}-test.qcow2}
RUN_IMAGE=${BUILD_DIR}/run-${PVE_VERSION}.qcow2
SEED_IMAGE=${BUILD_DIR}/seed.iso
PID_FILE=${BUILD_DIR}/qemu-${PVE_VERSION}.pid
BUILD_LOG=${BUILD_DIR}/build-console-${PVE_VERSION}.log
RUN_LOG=${BUILD_DIR}/run-console-${PVE_VERSION}.log

API_URL="https://127.0.0.1:${API_PORT}/api2/json"

log()  { echo "[pve-test] $*" >&2; }
die()  { echo "[pve-test] ERROR: $*" >&2; exit 1; }

require_tools() {
    local missing=()
    for t in "$@"; do
        command -v "${t}" >/dev/null 2>&1 || missing+=("${t}")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "missing required tool(s): ${missing[*]}
On Debian/Ubuntu: sudo apt-get install -y qemu-system-x86 qemu-utils xorriso curl"
    fi
}

# Nested VMs inside the Proxmox VM need hardware virtualisation to be passed
# through; without it qemu-server refuses to start any guest (kvm defaults to
# true in the provider schema).  Set PVE_TEST_ACCEL=tcg to try anyway.
accel_args() {
    local accel=${PVE_TEST_ACCEL:-kvm}
    if [ "${accel}" = "kvm" ]; then
        [ -w /dev/kvm ] || die "/dev/kvm is not writable (or does not exist).
The Proxmox VM needs KVM, and the guests it starts need nested KVM on top.
On a GitHub hosted Ubuntu runner, add the udev rule from the workflow.
Set PVE_TEST_ACCEL=tcg to run without it (expect it to be far too slow)."
        echo "-machine q35,accel=kvm -cpu host"
    else
        echo "-machine q35,accel=tcg -cpu max"
    fi
}
