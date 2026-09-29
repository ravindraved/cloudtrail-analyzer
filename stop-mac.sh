#!/usr/bin/env bash
# stop-mac.sh — Stop the CloudTrail Analyzer background process started by
# start-mac.sh. No service, no sudo. Sends SIGTERM for a graceful shutdown
# (the app drains sync pipelines and the index writer on SIGTERM), then
# escalates to SIGKILL only if it refuses to exit.
#
# Usage:
#   ./stop-mac.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="cloudtrail-analyzer"
RUN_DIR="${SCRIPT_DIR}/run"
PID_FILE="${RUN_DIR}/${APP_NAME}.pid"

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }

if [ ! -f "${PID_FILE}" ]; then
    warn "No PID file at ${PID_FILE}. ${APP_NAME} does not appear to be running."
    exit 0
fi

PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
if [ -z "${PID}" ]; then
    warn "PID file is empty; removing it."
    rm -f "${PID_FILE}"
    exit 0
fi

if ! kill -0 "${PID}" 2>/dev/null; then
    warn "Process ${PID} is not running (stale PID file). Cleaning up."
    rm -f "${PID_FILE}"
    exit 0
fi

info "Stopping ${APP_NAME} (PID ${PID}) with SIGTERM ..."
kill -TERM "${PID}" 2>/dev/null || true

# Wait up to ~15s for a graceful exit.
for _ in $(seq 1 30); do
    if ! kill -0 "${PID}" 2>/dev/null; then
        rm -f "${PID_FILE}"
        ok "${APP_NAME} stopped."
        exit 0
    fi
    sleep 0.5
done

warn "Process did not exit after 15s; sending SIGKILL ..."
kill -KILL "${PID}" 2>/dev/null || true
sleep 1
if kill -0 "${PID}" 2>/dev/null; then
    printf '\033[1;31m[FAIL]\033[0m  Could not stop PID %s. Inspect it manually: ps -p %s\n' "${PID}" "${PID}"
    exit 1
fi
rm -f "${PID_FILE}"
ok "${APP_NAME} force-stopped."
