#!/usr/bin/env bash
#
# Runs INSIDE the Debian VM while the test image is being built (invoked by
# cloud-init).  It converts a plain Debian 13 (trixie) cloud image into a
# single-node Proxmox VE host that the acceptance tests can talk to.
#
# The last thing it prints on the serial console is either PVE_BUILD_OK or
# PVE_BUILD_FAIL; the host side build script greps for those markers.
#
set -euo pipefail

# Values written by the build script through cloud-init.
# shellcheck disable=SC1091
source /root/pve-build.conf

log() { echo "[provision] $*"; }

on_error() {
    local line=$1
    log "PVE_BUILD_FAIL: aborted at line ${line}"
    sync
    sleep 5
    systemctl poweroff -f || poweroff -f
}
trap 'on_error $LINENO' ERR

export DEBIAN_FRONTEND=noninteractive

log "configuring hostname ${NODE_NAME}.${NODE_DOMAIN}"
echo "${NODE_NAME}" >/etc/hostname
hostname "${NODE_NAME}"

# Proxmox refuses to start pve-cluster when the node name resolves to a
# loopback address, so pin it to the current primary IP.
install -m 0755 /root/pve-test-hosts.sh /usr/local/sbin/pve-test-hosts
/usr/local/sbin/pve-test-hosts

log "adding the Proxmox VE ${PVE_VERSION} no-subscription repository (${PVE_SUITE})"
apt-get update
apt-get install -y ca-certificates curl gnupg
curl -fsSL "${PVE_KEYRING_URL}" -o /usr/share/keyrings/proxmox-archive-keyring.gpg
cat >/etc/apt/sources.list.d/pve-install-repo.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${PVE_SUITE}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

apt-get update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" full-upgrade

# Installing proxmox-ve pulls a new kernel, which makes grub-pc's postinst ask
# which disk to install to.  Non-interactively that is a hard dpkg failure, and
# it is what broke the Debian 13 build:
#   Errors were encountered while processing: grub-pc
root_disk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -n1)
if [ -n "${root_disk}" ]; then
    log "preseeding the grub install device as /dev/${root_disk}"
    echo "grub-pc grub-pc/install_devices multiselect /dev/${root_disk}" | debconf-set-selections
else
    log "WARNING: could not work out the root disk, grub-pc may prompt"
fi

# postfix would otherwise stop and ask what kind of mail server we want.
# "Local only" rather than "No configuration": the latter leaves postfix
# without a main.cf, so postfix@-.service fails on every boot.
echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections
echo "postfix postfix/mailname string ${NODE_NAME}.${NODE_DOMAIN}" | debconf-set-selections

log "installing proxmox-ve (this is the slow part)"
apt-get install -y \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    proxmox-ve postfix open-iscsi chrony xorriso

# Only drop the Debian kernels once we are sure a Proxmox one is in place,
# otherwise we end up with an unbootable image.
if compgen -G "/boot/vmlinuz-*-pve" >/dev/null; then
    log "removing the Debian kernels in favour of the Proxmox one"
    mapfile -t debian_kernels < <(
        dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null |
            grep -vE -- '-pve$|proxmox' || true
    )
    if [ ${#debian_kernels[@]} -gt 0 ]; then
        apt-get purge -y "${debian_kernels[@]}" || true
    fi
    apt-get purge -y os-prober || true
    update-grub
else
    log "PVE_BUILD_FAIL: no Proxmox kernel was installed"
    exit 1
fi

# The enterprise repositories need a subscription key; leaving them enabled
# just makes every apt-get run fail with a 401.
rm -f /etc/apt/sources.list.d/pve-enterprise.sources \
      /etc/apt/sources.list.d/pve-enterprise.list \
      /etc/apt/sources.list.d/ceph.sources \
      /etc/apt/sources.list.d/ceph.list

log "creating the vmbr0 and vmbr1 test bridges"
# A bridge with no ports: test VMs get a NIC and PVE is happy, but nothing the
# tests create can reach the network the runner is on.
#
# This goes in /etc/network/interfaces rather than interfaces.d/.  The Debian
# cloud image does not reliably source that directory, and a stanza that is
# never read is exactly how vmbr0 came to be missing at boot while
# networking.service still reported success.
rm -f /etc/network/interfaces.d/vmbr0 /etc/network/interfaces.d/vmbr1

add_bridge_stanza() { # add_bridge_stanza <file>
    local f=$1
    [ -f "${f}" ] || printf 'auto lo\niface lo inet loopback\n' >"${f}"
    if ! grep -qE '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d' "${f}"; then
        printf '\nsource /etc/network/interfaces.d/*\n' >>"${f}"
    fi
    if ! grep -q 'iface vmbr0' "${f}"; then
        cat >>"${f}" <<EOF

auto vmbr0
iface vmbr0 inet static
    address ${BRIDGE_CIDR}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
    fi
    # A second bridge, so the tests can cover multi-interface VMs, which is
    # the common case in real configurations.  It carries no address: nothing
    # needs to reach it, PVE only has to accept it as a NIC target.
    if ! grep -q 'iface vmbr1' "${f}"; then
        cat >>"${f}" <<EOF

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
    fi
}

add_bridge_stanza /etc/network/interfaces
# The ifupdown2 postinst rewrites the config for compatibility and parks the
# result in interfaces.new, which PVE applies on the next boot.  Without the
# stanza in there too, our bridge is thrown away the first time the image is
# booted for testing.
if [ -f /etc/network/interfaces.new ]; then
    log "also adding the bridge to /etc/network/interfaces.new"
    add_bridge_stanza /etc/network/interfaces.new
fi

# Bringing it up here is a bonus, not a requirement: the ifupdown2 postinst
# runs its own reload during the install and holds the lock ("Another instance
# of this program is already running"), so retry for a while and settle for a
# warning.  A genuinely missing bridge is caught by the readiness probe, which
# asks the node for its interface list before any test runs.
ifup_out=""
for attempt in $(seq 1 24); do
    ip link show vmbr0 >/dev/null 2>&1 && break
    ifup_out=$(ifup vmbr0 2>&1) || true
    ip link show vmbr0 >/dev/null 2>&1 && break
    [ $(( attempt % 6 )) -eq 0 ] && log "vmbr0 not up yet (attempt ${attempt}): ${ifup_out}"
    sleep 5
done
if ip link show vmbr0 >/dev/null 2>&1; then
    log "vmbr0 is up: $(ip -4 -o addr show vmbr0 | awk '{print $4}')"
else
    log "WARNING: could not bring vmbr0 up during the build (${ifup_out}); it is configured and will come up at boot"
fi

ifup vmbr1 >/dev/null 2>&1 || true
if ip link show vmbr1 >/dev/null 2>&1; then
    log "vmbr1 is up"
else
    log "WARNING: could not bring vmbr1 up during the build; it is configured and will come up at boot"
fi

log "allowing nested KVM for the guests the tests create"
cat >/etc/modprobe.d/kvm-nested.conf <<'EOF'
options kvm-intel nested=1
options kvm-amd nested=1
EOF

log "setting the root password and enabling ssh root login"
echo "root:${ROOT_PASSWORD}" | chpasswd
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

log "creating the test fixtures"
install -m 0755 /root/pve-test-bootstrap.sh /usr/local/sbin/pve-test-bootstrap
# Done here, at build time, rather than only at boot: the boot time unit used
# to be ordered After=pveproxy.service, and pveproxy's start job never
# completes on this image, so the unit silently never ran while the API itself
# was perfectly healthy.  Baking the fixtures into the image removes the
# ordering question entirely.
# PVE_TEST_PHASE=build: create the storage and ISO fixtures now, but not the
# cluster.  pvecm create would pin corosync.conf to the build time IP, which is
# not the address the image answers on once it is booted for testing.
if ! PVE_TEST_PHASE=build /usr/local/sbin/pve-test-bootstrap; then
    log "PVE_BUILD_FAIL: could not create the test fixtures"
    exit 1
fi

# And verify, so a broken image never reaches the cache.  Both checks read
# files directly; nothing here depends on a PVE daemon being up yet.
if [ ! -s /var/lib/vz/template/iso/SpinRite.iso ]; then
    log "PVE_BUILD_FAIL: SpinRite.iso was not created"
    exit 1
fi
if ! grep -qs 'content.*images' /etc/pve/storage.cfg; then
    log "PVE_BUILD_FAIL: the local storage does not accept disk images"
    exit 1
fi
for br in vmbr0 vmbr1; do
    if ! grep -qs "iface ${br}" /etc/network/interfaces /etc/network/interfaces.new; then
        log "PVE_BUILD_FAIL: the ${br} bridge was not configured"
        exit 1
    fi
done
# The cluster itself is created at boot, but the tools for it have to be in the
# image, and a missing ha-manager would only show up as a failing HA test much
# later.
for tool in pvecm ha-manager; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        log "PVE_BUILD_FAIL: ${tool} is not installed"
        exit 1
    fi
done
log "fixtures verified"

log "installing the boot time bootstrap units"
cat >/etc/systemd/system/pve-test-hosts.service <<'EOF'
[Unit]
Description=Pin the Proxmox node name to the current primary IP
After=network-online.target
Wants=network-online.target
Before=pve-cluster.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/pve-test-hosts

[Install]
WantedBy=multi-user.target
EOF
cat >/etc/systemd/system/pve-test-bootstrap.service <<'EOF'
[Unit]
Description=Create the fixtures the terraform provider acceptance tests expect
# Only pve-cluster: pvesm needs /etc/pve and nothing else.  Ordering this after
# pveproxy.service means it never runs, because that unit's start job does not
# complete on this image.
After=pve-cluster.service
Wants=pve-cluster.service

[Service]
Type=oneshot
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
Environment=PVE_TEST_CLUSTER_NAME=__CLUSTER_NAME__
Environment=PVE_TEST_HA_GROUP=__HA_GROUP__
ExecStart=/usr/local/sbin/pve-test-bootstrap

[Install]
WantedBy=multi-user.target
EOF
sed -i "s/__CLUSTER_NAME__/${CLUSTER_NAME:-acctest}/; s/__HA_GROUP__/${HA_GROUP:-acctest-ha}/" \
    /etc/systemd/system/pve-test-bootstrap.service
systemctl enable pve-test-hosts.service pve-test-bootstrap.service

# Nothing here should ever phone home or update itself mid test run.
systemctl disable --now pve-daily-update.timer 2>/dev/null || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# The seed ISO is not attached when the image is booted for testing, so stop
# cloud-init from hunting for a datasource on every boot.
touch /etc/cloud/cloud-init.disabled

log "cleaning up"
apt-get clean
rm -f /root/pve-build.conf /root/provision.sh
fstrim -av || true

log "PVE_BUILD_OK"
sync
sleep 5
systemctl poweroff -f || poweroff -f
