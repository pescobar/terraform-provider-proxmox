#!/usr/bin/env bash
#
# Does this environment actually boot VMs?
#
# Talks straight to the Proxmox API, no terraform and no provider involved:
# create a tiny VM, start it, confirm it is running, then tear it down.  If
# this fails, nothing about the provider is worth debugging yet.
#
# It first tries with KVM enabled (what the provider asks for by default) and,
# if that fails, retries with KVM off, so the output distinguishes "this runner
# cannot nest virtualisation" from "the environment is broken".
#
source "$(dirname "$0")/common.sh"

require_tools curl

VMID=${PVE_TEST_SMOKE_VMID:-9001}
VM_NAME=acctest-boot-smoke

TICKET=""
CSRF=""

login() {
    local response
    response=$(curl -sk --max-time 15 -d "username=root@pam" \
        --data-urlencode "password=${ROOT_PASSWORD}" "${API_URL}/access/ticket")
    TICKET=$(printf '%s' "${response}" | json_str ticket)
    CSRF=$(printf '%s' "${response}" | json_str CSRFPreventionToken)
    [ -n "${TICKET}" ] || die "could not authenticate against ${API_URL}"
}

# Pull one string field out of a JSON response.  Ends in `|| true` because a
# non-matching grep fails the pipeline under `set -o pipefail`, which would
# abort the script before the caller can report a useful error.
json_str() { # json_str <key>, reads stdin
    grep -o "\"$1\":\"[^\"]*\"" | head -n1 | cut -d'"' -f4 || true
}

api() { # api <method> <path> [curl args...]
    local method=$1 path=$2
    shift 2
    curl -sk --max-time 60 -X "${method}" \
        -H "Cookie: PVEAuthCookie=${TICKET}" \
        -H "CSRFPreventionToken: ${CSRF}" \
        "$@" "${API_URL}${path}"
}

# Most write calls return a UPID; the call returning is not the work finishing.
wait_for_task() { # wait_for_task <upid> <what>
    local upid=$1 what=$2 status
    for _ in $(seq 1 120); do
        status=$(api GET "/nodes/${NODE_NAME}/tasks/${upid}/status")
        if echo "${status}" | grep -q '"status":"stopped"'; then
            if echo "${status}" | grep -q '"exitstatus":"OK"'; then
                return 0
            fi
            log "${what} failed: ${status}"
            api GET "/nodes/${NODE_NAME}/tasks/${upid}/log" | head -c 2000 >&2
            echo >&2
            return 1
        fi
        sleep 2
    done
    log "${what} did not finish in time"
    return 1
}

destroy_vm() {
    local upid
    api POST "/nodes/${NODE_NAME}/qemu/${VMID}/status/stop" >/dev/null 2>&1 || true
    sleep 3
    upid=$(api DELETE "/nodes/${NODE_NAME}/qemu/${VMID}?purge=1" | json_str data)
    [ -n "${upid}" ] && wait_for_task "${upid}" "destroy" >/dev/null 2>&1 || true
}

create_vm() { # create_vm <kvm 0|1>
    local kvm=$1 upid response
    response=$(api POST "/nodes/${NODE_NAME}/qemu" \
        --data-urlencode "vmid=${VMID}" \
        --data-urlencode "name=${VM_NAME}" \
        --data-urlencode "memory=512" \
        --data-urlencode "cores=1" \
        --data-urlencode "sockets=1" \
        --data-urlencode "ostype=l26" \
        --data-urlencode "kvm=${kvm}" \
        --data-urlencode "scsihw=virtio-scsi-single" \
        --data-urlencode "net0=virtio,bridge=vmbr0" \
        --data-urlencode "ide2=local:iso/SpinRite.iso,media=cdrom" \
        --data-urlencode "boot=order=ide2")
    upid=$(printf '%s' "${response}" | json_str data)
    [ -n "${upid}" ] || { log "create failed: $(printf '%s' "${response}" | head -c 300)"; return 1; }
    wait_for_task "${upid}" "create VM ${VMID}"
}

start_vm() {
    local upid response
    response=$(api POST "/nodes/${NODE_NAME}/qemu/${VMID}/status/start")
    upid=$(printf '%s' "${response}" | json_str data)
    [ -n "${upid}" ] || { log "start failed: $(printf '%s' "${response}" | head -c 300)"; return 1; }
    wait_for_task "${upid}" "start VM ${VMID}"
}

assert_running() {
    local state
    for _ in $(seq 1 30); do
        state=$(api GET "/nodes/${NODE_NAME}/qemu/${VMID}/status/current")
        if echo "${state}" | grep -q '"status":"running"'; then
            log "VM ${VMID} is running (qmpstatus: $(printf '%s' "${state}" | json_str qmpstatus))"
            return 0
        fi
        sleep 2
    done
    log "VM ${VMID} never reached the running state: ${state}"
    return 1
}

login

version=$(api GET "/version" | json_str version)
log "Proxmox VE version: ${version:-unknown}"
if [ -n "${PVE_EXPECT_VERSION:-}" ]; then
    case "${version}" in
        "${PVE_EXPECT_VERSION}"*)
            log "version matches the expected ${PVE_EXPECT_VERSION}.x" ;;
        *)
            log "WARNING: expected Proxmox VE ${PVE_EXPECT_VERSION}.x from the ${PVE_SUITE} repository, got ${version:-unknown}" ;;
    esac
fi

# Leave nothing behind, whatever happens from here on.
trap destroy_vm EXIT
destroy_vm

result=""
for kvm in 1 0; do
    log "attempting create + boot with kvm=${kvm}"
    if create_vm "${kvm}" && start_vm && assert_running; then
        result=${kvm}
        break
    fi
    log "kvm=${kvm} attempt failed, cleaning up"
    destroy_vm
done

case "${result}" in
    1)
        log "PASS: this environment boots VMs with hardware acceleration (kvm=1)"
        log "      the acceptance tests can run unmodified"
        ;;
    0)
        log "PASS (degraded): VMs boot only with kvm=0, nested virtualisation is not"
        log "      available on this runner.  The acceptance tests default to kvm=true"
        log "      and will fail until the fixtures set kvm = false."
        ;;
    *)
        die "FAIL: this environment cannot boot VMs at all" ;;
esac
