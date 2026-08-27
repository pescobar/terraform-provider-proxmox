#!/usr/bin/env bash
#
# Creates everything the acceptance tests in proxmox/resource_vm_qemu_test.go
# assume already exists:
#
#   * the "local" storage has to accept disk images, not just ISOs
#   * "local:iso/SpinRite.iso" has to be there
#
# Runs once while the image is built, and again on every boot as a safety net.
# Everything below is idempotent.
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
