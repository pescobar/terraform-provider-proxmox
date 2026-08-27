#!/usr/bin/env bash
#
# Kill the test VM and drop its overlay.
#
source "$(dirname "$0")/common.sh"

if [ -f "${PID_FILE}" ]; then
    pid=$(cat "${PID_FILE}")
    if kill -0 "${pid}" 2>/dev/null; then
        log "stopping the test VM (pid ${pid})"
        kill "${pid}" 2>/dev/null || true
        for _ in $(seq 1 30); do
            kill -0 "${pid}" 2>/dev/null || break
            sleep 1
        done
        kill -9 "${pid}" 2>/dev/null || true
    fi
    rm -f "${PID_FILE}"
fi
rm -f "${RUN_IMAGE}"
