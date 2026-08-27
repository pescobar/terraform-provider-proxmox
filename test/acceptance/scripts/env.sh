# Environment for `make acctest` against the local test VM.
#
#   source test/acceptance/scripts/env.sh
#
# Kept free of `set -e` and friends on purpose: it is meant to be sourced into
# an interactive shell.

export PM_API_URL="https://127.0.0.1:${PVE_TEST_API_PORT:-8006}/api2/json"
export PM_USER="root@pam"
export PM_PASS="${PVE_TEST_ROOT_PASSWORD:-proxmox-acctest}"
export PM_TLS_INSECURE=true
