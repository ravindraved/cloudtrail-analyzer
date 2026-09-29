#!/usr/bin/env bash
# start-mac.sh — Launch CloudTrail Analyzer as a plain background process on
# macOS. No service, no sudo. Data and logs stay inside this project directory.
#
# Usage:
#   ./start-mac.sh            # start in the background (nohup), health-check
#   ./start-mac.sh -f         # run in the foreground (Ctrl-C to stop)
#   PORT=8080 ./start-mac.sh  # override the port for this run
#
# Environment overrides (optional):
#   PORT       (default 7070)
#   HOST       (default 127.0.0.1 — loopback only; the app has no auth)
#   LOG_LEVEL  (default info)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="cloudtrail-analyzer"
BIN_PATH="${SCRIPT_DIR}/dist/${APP_NAME}"
LOCAL_BIN="${SCRIPT_DIR}/bin"
RUN_DIR="${SCRIPT_DIR}/run"
LOG_DIR="${SCRIPT_DIR}/logs"
PID_FILE="${RUN_DIR}/${APP_NAME}.pid"
LOG_FILE="${LOG_DIR}/${APP_NAME}.log"

# Runtime config — data is anchored to this project directory (absolute), so
# there is never any question about where the data lives.
export PORT="${PORT:-7070}"
export HOST="${HOST:-127.0.0.1}"
export LOG_LEVEL="${LOG_LEVEL:-info}"
export DATA_DIR="${SCRIPT_DIR}/data"

# Make a project-local duckdb (./bin/duckdb) discoverable without touching the
# system, and keep the user's PATH (Homebrew duckdb) too.
export PATH="${LOCAL_BIN}:${PATH}"

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

FOREGROUND=0
case "${1:-}" in
    -f|--foreground) FOREGROUND=1;;
    "") ;;
    *) fail "Unknown argument: $1 (use -f for foreground)";;
esac

# --- Preconditions ---
[ -x "${BIN_PATH}" ] || fail "Binary not found at ${BIN_PATH}. Run ./deploy-mac.sh first."

if ! command -v duckdb >/dev/null 2>&1; then
    warn "duckdb CLI is not on PATH. Queries/indexing will fail until it is installed."
    warn "Install it with 'brew install duckdb' or drop the CLI into ${LOCAL_BIN}/ (see deploy-mac.sh)."
fi

mkdir -p "${RUN_DIR}" "${LOG_DIR}" "${DATA_DIR}"

# --- Already running? ---
is_running() {
    [ -f "${PID_FILE}" ] || return 1
    local pid; pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    [ -n "${pid}" ] || return 1
    kill -0 "${pid}" 2>/dev/null
}

if is_running; then
    fail "Already running (PID $(cat "${PID_FILE}")). Use ./stop-mac.sh first, or check ${LOG_FILE}."
fi
# Clean up a stale PID file if the process is gone.
[ -f "${PID_FILE}" ] && rm -f "${PID_FILE}"

# --- Foreground mode: exec and hand the terminal the process ---
if [ "${FOREGROUND}" -eq 1 ]; then
    info "Starting ${APP_NAME} in the FOREGROUND on http://${HOST}:${PORT}"
    info "Data dir: ${DATA_DIR}   (Ctrl-C to stop)"
    exec "${BIN_PATH}"
fi

# --- Background mode ---
info "Starting ${APP_NAME} on http://${HOST}:${PORT}"
info "Data dir: ${DATA_DIR}"
nohup "${BIN_PATH}" >> "${LOG_FILE}" 2>&1 &
APP_PID=$!
echo "${APP_PID}" > "${PID_FILE}"

# --- Health check (portable loop; no reliance on curl --retry flags) ---
HEALTHY=0
for _ in $(seq 1 30); do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
        break  # process exited early
    fi
    if curl -sf "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
        HEALTHY=1
        break
    fi
    sleep 0.5
done

if [ "${HEALTHY}" -eq 1 ]; then
    ok "${APP_NAME} is running (PID ${APP_PID})."
    echo ""
    echo "  URL:   http://${HOST}:${PORT}"
    echo "  PID:   ${APP_PID}  (${PID_FILE})"
    echo "  Logs:  ${LOG_FILE}    (tail -f to follow)"
    echo "  Data:  ${DATA_DIR}"
    echo "  Stop:  ./stop-mac.sh"
else
    rm -f "${PID_FILE}"
    echo "---- last 40 log lines ----"
    tail -n 40 "${LOG_FILE}" 2>/dev/null || true
    echo "---------------------------"
    fail "${APP_NAME} did not become healthy. See ${LOG_FILE} above."
fi
