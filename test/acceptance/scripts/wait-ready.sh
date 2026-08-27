#!/usr/bin/env bash
#
# Block until the Proxmox test VM is fully usable: API up, credentials valid,
# node online and the fixtures the tests expect in place.
#
source "$(dirname "$0")/common.sh"

require_tools curl

TIMEOUT=${PVE_TEST_READY_TIMEOUT:-1200}
deadline=$(( $(date +%s) + TIMEOUT ))
last_report=$(date +%s)
last=""

api_get() { # $1 = path, $2 = ticket
    curl -sk --max-time 10 -H "Cookie: PVEAuthCookie=$2" "${API_URL}$1"
}

while [ "$(date +%s)" -lt "${deadline}" ]; do
    ticket=$(curl -sk --max-time 10 -d "username=root@pam" \
        --data-urlencode "password=${ROOT_PASSWORD}" \
        "${API_URL}/access/ticket" 2>/dev/null |
        grep -o '"ticket":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)

    if [ -z "${ticket}" ]; then
        last="API not answering or credentials rejected"
    elif ! api_get "/nodes/${NODE_NAME}/status" "${ticket}" | grep -q '"uptime"'; then
        last="node ${NODE_NAME} is not online yet"
    elif ! api_get "/nodes/${NODE_NAME}/network" "${ticket}" | grep -q '"iface":"vmbr0"'; then
        last="the vmbr0 bridge is missing"
        node_up_since=${node_up_since:-$(date +%s)}
        if [ $(( $(date +%s) - node_up_since )) -ge 180 ]; then
            log "node ${NODE_NAME} is online but ${last}"
            log "the image was built without it; rebuild (bump IMAGE_CACHE_EPOCH in CI)"
            exit 1
        fi
    elif ! api_get "/nodes/${NODE_NAME}/storage/local/content" "${ticket}" | grep -q "SpinRite.iso"; then
        last="the fixtures are missing (local:iso/SpinRite.iso)"
        # The node answering means Proxmox is up; the fixtures are baked into
        # the image, so if they are not there now they never will be.  Do not
        # burn the whole timeout on it.
        node_up_since=${node_up_since:-$(date +%s)}
        if [ $(( $(date +%s) - node_up_since )) -ge 180 ]; then
            log "node ${NODE_NAME} is online but ${last}"
            log "the image was built without its fixtures; rebuild it (bump IMAGE_CACHE_EPOCH in CI)"
            exit 1
        fi
    else
        version=$(api_get "/version" "${ticket}" | grep -o '"version":"[^"]*"' | head -n1 | cut -d'"' -f4)
        log "Proxmox VE ${version:-unknown} is ready on ${API_URL}"
        case "${version}" in
            "${PVE_EXPECT_VERSION}"*) : ;;
            *) log "WARNING: expected ${PVE_EXPECT_VERSION}.x from the ${PVE_SUITE} repository, got ${version:-unknown}" ;;
        esac
        exit 0
    fi
    # Say what we are waiting on rather than going quiet for 20 minutes.
    now=$(date +%s)
    if [ $(( now - last_report )) -ge 60 ]; then
        log "still waiting (${last}), $(( deadline - now ))s left"
        last_report=${now}
    fi
    sleep 5
done

log "last state: ${last}"
[ -f "${RUN_LOG}" ] && tail -n 40 "${RUN_LOG}" >&2
die "timed out after ${TIMEOUT}s waiting for Proxmox VE"
