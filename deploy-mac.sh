#!/usr/bin/env bash
# deploy-mac.sh — Standalone, no-sudo build/setup for CloudTrail Analyzer on macOS
#
# Usage:
#   chmod +x deploy-mac.sh start-mac.sh stop-mac.sh
#   ./deploy-mac.sh
#
# Philosophy (differs from deploy.sh, which is the EC2/systemd installer):
#   - NO sudo. Nothing is written outside this project directory.
#   - NO service. The app is launched later with ./start-mac.sh (a plain
#     background process) and stopped with ./stop-mac.sh.
#   - NO auto-install. This script only CHECKS for the tools it needs and, if
#     any are missing, prints how to install them (Homebrew or a no-sudo
#     download) and exits. You install them; then re-run this script.
#   - Data stays local: ./data next to this script, so there is no hunting for
#     "where is my data".
#
# This script is idempotent — safe to run multiple times.

set -euo pipefail

# Resolve the project directory (works regardless of the caller's cwd) and run
# from there so config.json and ./data are always colocated with the scripts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="cloudtrail-analyzer"
BIN_DIR="${SCRIPT_DIR}/dist"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
DATA_DIR="${SCRIPT_DIR}/data"
CONFIG_FILE="${SCRIPT_DIR}/config.json"
LOCAL_BIN="${SCRIPT_DIR}/bin"     # optional home for a no-sudo duckdb download

# Minimum versions (major.minor).
GO_MIN="1.26"
NODE_MIN="20"

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
info()  { printf '\n\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
fail()  { printf '\033[1;31m[FAIL]\033[0m  %s\n' "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Version helpers (bash 3.2 compatible — macOS default). No `sort -V`, no
# `grep -P`, no associative arrays.
# ---------------------------------------------------------------------------
ver_major() { printf '%s' "${1%%.*}"; }
ver_minor() {
    case "$1" in
        *.*) local rest="${1#*.}"; printf '%s' "${rest%%.*}";;
        *)   printf '0';;
    esac
}

# version_ge HAVE WANT  -> success (0) if HAVE >= WANT comparing major.minor
version_ge() {
    local have_maj have_min want_maj want_min
    have_maj="$(ver_major "$1")"; have_min="$(ver_minor "$1")"
    want_maj="$(ver_major "$2")"; want_min="$(ver_minor "$2")"
    # Non-numeric guard.
    case "${have_maj}${have_min}${want_maj}${want_min}" in
        *[!0-9]*) return 1;;
    esac
    if [ "${have_maj}" -gt "${want_maj}" ]; then return 0; fi
    if [ "${have_maj}" -lt "${want_maj}" ]; then return 1; fi
    [ "${have_min}" -ge "${want_min}" ]
}

MISSING=0
note_missing() { MISSING=$((MISSING + 1)); }

# ---------------------------------------------------------------------------
# Step 0: Platform + architecture
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
    fail "This script targets macOS. On Linux/EC2 use deploy.sh instead."
fi

ARCH="$(uname -m)"
case "${ARCH}" in
    arm64)  DUCKDB_ARCH="osx-universal"; NODE_ARCH="arm64"; BREW_HINT="/opt/homebrew/bin";;
    x86_64) DUCKDB_ARCH="osx-universal"; NODE_ARCH="x64";   BREW_HINT="/usr/local/bin";;
    *)      fail "Unsupported architecture: ${ARCH}";;
esac
info "macOS detected (arch: ${ARCH}). Standalone, no-sudo deploy."
info "Project dir: ${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Step 1: Dependency preflight (check-only; guide, do not install)
# ---------------------------------------------------------------------------
# Allow a project-local duckdb (./bin/duckdb) to satisfy the runtime check
# without touching the system.
export PATH="${LOCAL_BIN}:${PATH}"

info "Checking required tools (nothing will be installed) ..."

# --- Go ---
if command -v go >/dev/null 2>&1; then
    GO_VER="$(go version | awk '{print $3}' | sed 's/^go//')"
    if version_ge "${GO_VER}" "${GO_MIN}"; then
        ok "Go ${GO_VER} (>= ${GO_MIN})"
    else
        warn "Go ${GO_VER} is too old (need >= ${GO_MIN})."
        note_missing
        cat <<EOF
  Install/upgrade Go (no sudo needed with Homebrew):
    brew install go
  Or download the macOS archive (no sudo; extract to your home):
    https://go.dev/dl/   (pick go<version>.darwin-${NODE_ARCH}.tar.gz)
    mkdir -p "\$HOME/sdk" && tar -C "\$HOME/sdk" -xzf ~/Downloads/go*.tar.gz
    export PATH="\$HOME/sdk/go/bin:\$PATH"
EOF
    fi
else
    warn "Go not found."
    note_missing
    cat <<EOF
  Install Go (>= ${GO_MIN}):
    brew install go
  Or download (no sudo): https://go.dev/dl/  (go<version>.darwin-${NODE_ARCH}.tar.gz)
EOF
fi

# --- Node.js + npm ---
if command -v node >/dev/null 2>&1; then
    NODE_VER="$(node --version | sed 's/^v//')"
    if version_ge "${NODE_VER}" "${NODE_MIN}"; then
        ok "Node.js ${NODE_VER} (>= ${NODE_MIN})"
    else
        warn "Node.js ${NODE_VER} is too old (need >= ${NODE_MIN})."
        note_missing
        cat <<EOF
  Install/upgrade Node.js (no sudo with Homebrew):
    brew install node
  Or use nvm (no sudo): https://github.com/nvm-sh/nvm
    nvm install ${NODE_MIN} && nvm use ${NODE_MIN}
EOF
    fi
else
    warn "Node.js not found."
    note_missing
    cat <<EOF
  Install Node.js (>= ${NODE_MIN}), build-time only:
    brew install node
  Or nvm (no sudo): https://github.com/nvm-sh/nvm  then: nvm install ${NODE_MIN}
EOF
fi

if command -v npm >/dev/null 2>&1; then
    ok "npm $(npm --version)"
else
    warn "npm not found (usually installed alongside Node.js)."
    note_missing
    echo "  Installing Node.js via 'brew install node' provides npm."
fi

# --- DuckDB CLI (runtime dependency the app shells out to) ---
if command -v duckdb >/dev/null 2>&1; then
    ok "DuckDB CLI $(duckdb --version 2>/dev/null || echo 'installed') ($(command -v duckdb))"
else
    warn "DuckDB CLI not found."
    note_missing
    cat <<EOF
  The app runs the 'duckdb' command-line binary at query time. Install it
  WITHOUT sudo using ONE of:

    1) Homebrew (simplest):
         brew install duckdb

    2) Download the official CLI into this project's ./bin (no sudo):
         mkdir -p "${LOCAL_BIN}"
         curl -L -o /tmp/duckdb.zip \\
           https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-${DUCKDB_ARCH}.zip
         unzip -o /tmp/duckdb.zip -d "${LOCAL_BIN}"
         # start-mac.sh already adds ./bin to PATH, so it will be found.

  NOTE: 'pip install duckdb' / 'uv pip install duckdb' installs the Python
  LIBRARY, not the 'duckdb' CLI binary this app needs — use brew or the zip.
EOF
fi

if [ "${MISSING}" -ne 0 ]; then
    fail "${MISSING} dependency requirement(s) not met. Install the tool(s) above (no sudo required), then re-run ./deploy-mac.sh.
       If you used Homebrew and the command still isn't found, ensure ${BREW_HINT} is on your PATH."
fi
ok "All required tools present."

# ---------------------------------------------------------------------------
# Step 2: Sanity-check the source tree
# ---------------------------------------------------------------------------
for required in cmd internal web web/package.json go.mod; do
    if [ ! -e "${SCRIPT_DIR}/${required}" ]; then
        fail "Source tree is incomplete: missing ${required}. Re-clone or re-extract the project."
    fi
done

# ---------------------------------------------------------------------------
# Step 3: Build the frontend
# ---------------------------------------------------------------------------
info "Installing frontend dependencies (npm ci) ..."
( cd "${SCRIPT_DIR}/web" && npm ci --prefer-offline --no-audit --no-fund >/dev/null 2>&1 ) \
    || fail "npm ci failed. Run it manually in ./web to see the error."
ok "Frontend dependencies installed"

info "Building frontend (React + Vite) ..."
( cd "${SCRIPT_DIR}/web" && npm run build ) || fail "Frontend build failed."
ok "Frontend built to web/dist/"

# ---------------------------------------------------------------------------
# Step 4: Embed assets and build the Go binary
# ---------------------------------------------------------------------------
info "Preparing embedded assets ..."
# Remove the previous embed copy first — copying over an existing dist/ nests
# assets at cmd/analyzer/dist/dist/. Matches the Makefile / deploy.sh convention.
rm -rf "${SCRIPT_DIR}/cmd/analyzer/dist"
cp -r "${SCRIPT_DIR}/web/dist" "${SCRIPT_DIR}/cmd/analyzer/dist"
touch "${SCRIPT_DIR}/cmd/analyzer/dist/.gitkeep"
ok "Frontend assets copied for embedding"

info "Downloading Go module dependencies ..."
go mod download || fail "go mod download failed."

info "Building production binary ..."
mkdir -p "${BIN_DIR}"
VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo "mac-$(date +%Y%m%d)")"
# CGO disabled: the project is pure Go (modernc sqlite, no cgo), so no Xcode
# toolchain is required and the binary is self-contained.
CGO_ENABLED=0 go build -ldflags "-X main.version=${VERSION}" -o "${BIN_PATH}" ./cmd/analyzer \
    || fail "go build failed."
chmod 0755 "${BIN_PATH}"
ok "Binary built: ${BIN_PATH} (version: ${VERSION})"

# ---------------------------------------------------------------------------
# Step 5: Local data dir + default config (relative to this project)
# ---------------------------------------------------------------------------
info "Ensuring local data directory ..."
mkdir -p "${DATA_DIR}"
chmod 700 "${DATA_DIR}"
ok "Data directory: ${DATA_DIR}"

if [ ! -f "${CONFIG_FILE}" ]; then
    info "Writing default config.json (loopback bind, local ./data) ..."
    cat > "${CONFIG_FILE}" <<'CONFIGEOF'
{
  "port": 7070,
  "host": "127.0.0.1",
  "data_dir": "./data",
  "log_level": "info",
  "query_timeout_seconds": 60,
  "monitor_interval_seconds": 5,
  "max_download_concurrency": 16,
  "s3": {
    "bucket": "",
    "region": "",
    "account_id": "",
    "mode": "single"
  },
  "auth": {
    "method": "imds"
  },
  "bedrock": {
    "region": "us-east-1",
    "model_id": "us.anthropic.claude-sonnet-4-6",
    "enabled": false
  },
  "llm": {
    "provider": "bedrock",
    "max_session_spend_usd": 5.00
  }
}
CONFIGEOF
    chmod 600 "${CONFIG_FILE}"
    ok "Default config written to ${CONFIG_FILE}"
else
    warn "Config already exists at ${CONFIG_FILE} — not overwriting"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  CloudTrail Analyzer is built and ready (standalone)."
echo "============================================================"
echo ""
echo "  Binary:  ${BIN_PATH}"
echo "  Config:  ${CONFIG_FILE}"
echo "  Data:    ${DATA_DIR}"
echo ""
echo "  Start (background, no service, no sudo):"
echo "     ./start-mac.sh"
echo "  Stop:"
echo "     ./stop-mac.sh"
echo ""
echo "  On EC2 (macOS auth): the default auth.method is 'imds', which only"
echo "  works on an EC2 host. On a laptop, open the UI after starting and set"
echo "  credentials under Settings -> Credentials (session/SSO/static)."
echo ""
