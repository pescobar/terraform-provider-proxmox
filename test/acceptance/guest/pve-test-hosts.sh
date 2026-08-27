#!/usr/bin/env bash
#
# Rewrite /etc/hosts so the node name resolves to the current primary IP.
# pve-cluster refuses to start when the node name only resolves to loopback,
# and the IP changes depending on how the image is booted.
#
set -euo pipefail

NODE_NAME=$(hostname)
NODE_DOMAIN=${NODE_DOMAIN:-pve.test}

ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") print $(i+1)}')
if [ -z "${ip}" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
: "${ip:=127.0.1.1}"

cat >/etc/hosts <<HOSTS
127.0.0.1 localhost
${ip} ${NODE_NAME}.${NODE_DOMAIN} ${NODE_NAME}

::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
HOSTS
