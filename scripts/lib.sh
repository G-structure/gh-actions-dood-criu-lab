#!/usr/bin/env bash
# lib.sh — shared helpers sourced by all test and migration scripts.
# Provides logging, retry with backoff, environment snapshot, JSON result
# recording, markdown summary, and a cleanup trap system.
set -euo pipefail

# ── Directories ──────────────────────────────────────────────────────
RESULTS_DIR="${RESULTS_DIR:-results}"
mkdir -p "$RESULTS_DIR"

# ── Colours (disabled when not a tty) ────────────────────────────────
if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'
  CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; CYAN=""; BOLD=""; RESET=""
fi

# ── Logging ──────────────────────────────────────────────────────────
log()  { echo "${CYAN}[INFO]${RESET}  $(date +%H:%M:%S) $*"; }
ok()   { echo "${GREEN}[PASS]${RESET}  $(date +%H:%M:%S) $*"; }
fail() { echo "${RED}[FAIL]${RESET}  $(date +%H:%M:%S) $*"; }
warn() { echo "${YELLOW}[WARN]${RESET}  $(date +%H:%M:%S) $*"; }

# ── Section headers ──────────────────────────────────────────────────
section() { echo ""; echo "${BOLD}═══ $* ═══${RESET}"; echo ""; }

# ── Retry with exponential back-off ──────────────────────────────────
retry() {
  local max_attempts="${1:?usage: retry <max> <cmd...>}"; shift
  local attempt=1 delay=2
  until "$@"; do
    if (( attempt >= max_attempts )); then
      fail "Command failed after $max_attempts attempts: $*"
      return 1
    fi
    warn "Attempt $attempt/$max_attempts failed; retrying in ${delay}s …"
    sleep "$delay"
    (( attempt++ ))
    (( delay *= 2 ))
  done
}

# ── Environment snapshot ─────────────────────────────────────────────
print_env() {
  section "Environment"
  log "OS:"; cat /etc/os-release 2>/dev/null || true
  log "Kernel: $(uname -a)"
  log "Docker version:"; docker version 2>&1 || true
  log "Docker info (abbreviated):"; docker info 2>&1 | head -40 || true
}

# ── JSON result helper ───────────────────────────────────────────────
# Usage: record_result <test_name> <status> <message>
#   status: PASS | FAIL | SKIP
record_result() {
  local name="$1" status="$2" msg="$3"
  local file="$RESULTS_DIR/results.json"
  # Ensure file exists with a JSON array
  if [[ ! -f "$file" ]]; then
    echo '[]' > "$file"
  fi
  # Escape quotes in msg
  msg="${msg//\"/\\\"}"
  # Append using jq if available, else python, else raw
  if command -v jq &>/dev/null; then
    jq --arg n "$name" --arg s "$status" --arg m "$msg" \
       '. += [{"test": $n, "status": $s, "message": $m}]' "$file" > "$file.tmp" \
       && mv "$file.tmp" "$file"
  elif command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
d = json.load(open('$file'))
d.append({'test': '$name', 'status': '$status', 'message': '''$msg'''})
json.dump(d, open('$file','w'), indent=2)
"
  else
    # Fallback: just append a line (not valid JSON array, but better than nothing)
    echo "{\"test\":\"$name\",\"status\":\"$status\",\"message\":\"$msg\"}" >> "$file"
  fi
}

# ── Summary markdown helper ──────────────────────────────────────────
append_summary() {
  local text="$1"
  echo "$text" >> "$RESULTS_DIR/summary.md"
}

# ── Cleanup trap helper ──────────────────────────────────────────────
# Register a cleanup function: add_cleanup "docker rm -f mycontainer"
_CLEANUP_CMDS=()
add_cleanup() { _CLEANUP_CMDS+=("$1"); }
run_cleanups() {
  for cmd in "${_CLEANUP_CMDS[@]+"${_CLEANUP_CMDS[@]}"}"; do
    log "Cleanup: $cmd"
    eval "$cmd" 2>/dev/null || true
  done
}
trap run_cleanups EXIT
