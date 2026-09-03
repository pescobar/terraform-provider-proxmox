#!/usr/bin/env bash
#
# Creates everything the acceptance tests in proxmox/resource_vm_qemu_test.go
# assume already exists:
#
#   * the "local" storage has to accept disk images, not just ISOs
#   * "local:iso/SpinRite.iso" has to be there
#   * a single node corosync cluster, and an HA group inside it
#
# Runs once while the image is built, and again on every boot as a safety net.
# Everything below is idempotent.
#
# The cluster is the exception: it is created on boot only, never during the
# image build.  `pvecm create` writes the node's current IP into
# corosync.conf, and that address is not the same one the image gets when it
# is booted for testing -- which is the whole reason pve-test-hosts exists.  A
# corosync.conf pinned to a stale address leaves pmxcfs without quorum and
# read-only, so every later fixture write fails.  PVE_TEST_PHASE=build skips
# it; systemd runs this with no phase set and gets the cluster.
#
set -euo pipefail

log() { echo "[bootstrap] $*"; }

# /etc/pve is a FUSE mount provided by pmxcfs; nothing below works until it is
# mounted.  Note we deliberately do NOT wait for a file inside it: on a Debian
# based install PVE writes no default storage.cfg until it has been through a
# boot, so waiting for one during the image build waits forever.
for _ in $(seq 1 120); do
    mountpoint -q /etc/pve && break
    sleep 2
done
if ! mountpoint -q /etc/pve; then
    log "/etc/pve is not mounted, pve-cluster is broken"
    exit 1
fi

# The stock "local" storage only accepts ISOs, templates and backups, and the
# tests put VM disks on it.  Write the config rather than using `pvesm set`,
# which needs the storage to already be defined.
if ! grep -qs 'content.*images' /etc/pve/storage.cfg; then
    log "configuring the local storage to accept disk images"
    {
        printf 'dir: local\n'
        printf '\tpath /var/lib/vz\n'
        printf '\tcontent images,rootdir,iso,vztmpl,backup,snippets\n'
        printf '\tprune-backups keep-all=1\n'
        printf '\tshared 0\n'
    } >/etc/pve/storage.cfg
fi

ISO_DIR=/var/lib/vz/template/iso
mkdir -p "${ISO_DIR}"

# The tests boot VMs from local:iso/SpinRite.iso.  They never look at what is
# on it, they only need PVE to hand a valid CD-ROM to QEMU, so a small empty
# ISO9660 image does the job.
if [ ! -s "${ISO_DIR}/SpinRite.iso" ]; then
    log "creating the SpinRite.iso placeholder"
    tmp=$(mktemp -d)
    echo "placeholder for the terraform-provider-proxmox acceptance tests" >"${tmp}/README.txt"
    xorrisofs -quiet -V SPINRITE -o "${ISO_DIR}/SpinRite.iso" "${tmp}"
    rm -rf "${tmp}"
fi

log "ready: $(wc -c <"${ISO_DIR}/SpinRite.iso") byte ISO, local storage accepts images"

# --- single node cluster, so that HA works at all -------------------------

CLUSTER_NAME=${PVE_TEST_CLUSTER_NAME:-acctest}
HA_GROUP=${PVE_TEST_HA_GROUP:-acctest-ha}
NODE=$(hostname)

if [ "${PVE_TEST_PHASE:-boot}" = "build" ]; then
    log "build phase: skipping cluster creation, it is a boot time step"
    exit 0
fi

if [ -f /etc/pve/corosync.conf ]; then
    log "already clustered as $(awk -F: '/cluster_name/{print $2}' /etc/pve/corosync.conf | tr -d ' ')"
else
    log "creating the single node cluster ${CLUSTER_NAME} on ${NODE}"
    # -link0 pinned to the address pve-test-hosts just wrote, so corosync binds
    # to the interface the node actually answers on rather than guessing.
    link=$(awk -v n="${NODE}" '$2==n || $3==n {print $1; exit}' /etc/hosts)
    if [ -n "${link}" ] && [ "${link}" != "127.0.0.1" ]; then
        pvecm create "${CLUSTER_NAME}" --link0 "${link}" || log "pvecm create failed"
    else
        pvecm create "${CLUSTER_NAME}" || log "pvecm create failed"
    fi
fi

# Quorum does not arrive the instant pvecm returns; ha-manager refuses
# everything until it does.
for _ in $(seq 1 60); do
    pvecm status 2>/dev/null | grep -qi 'Quorate:.*Yes' && break
    sleep 2
done
if ! pvecm status 2>/dev/null | grep -qi 'Quorate:.*Yes'; then
    log "WARNING: cluster is not quorate; HA fixtures will not be created"
    exit 0
fi
log "cluster is quorate"

# The HA group the tests attach guests to.
#
# Proxmox VE 9 deprecated HA groups in favour of node affinity rules and
# migrates existing ones on upgrade, but `ha-manager groupadd` still works
# there -- deprecated is not removed -- and groups are what this provider
# knows how to set.  If that ever stops being true this is where it breaks,
# loudly, rather than in a test.
if ha-manager groupconfig 2>/dev/null | grep -q "^${HA_GROUP}\b"; then
    log "HA group ${HA_GROUP} already exists"
elif ha-manager groupadd "${HA_GROUP}" --nodes "${NODE}" 2>/dev/null; then
    log "created HA group ${HA_GROUP} on ${NODE}"
else
    log "WARNING: could not create HA group ${HA_GROUP} (groups may be gone on this PVE version)"
fi

log "HA ready: $(ha-manager groupconfig 2>/dev/null | tr '\n' ' ' | head -c 200)"
