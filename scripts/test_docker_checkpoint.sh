#!/usr/bin/env bash
# test_docker_checkpoint.sh — Docker checkpoint/restore (docker + CRIU) test
#
# Tests whether the Docker daemon on GitHub-hosted runners supports
# `docker checkpoint create` / `docker start --checkpoint` (requires
# Docker experimental features + CRIU).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TEST_NAME="docker_checkpoint"
LOG_FILE="$RESULTS_DIR/${TEST_NAME}.log"
exec > >(tee "$LOG_FILE") 2>&1

section "Docker Checkpoint/Restore Test"
print_env

CONTAINER_NAME="docker-ckpt-test-$$"
add_cleanup "docker rm -f $CONTAINER_NAME 2>/dev/null || true"

# ── Step 1: Install CRIU on host ─────────────────────────────────────
section "Installing CRIU on host (for Docker checkpoint support)"
retry 3 sudo apt-get update -qq
retry 3 sudo apt-get install -y criu
criu --version

# ── Step 2: Check if docker checkpoint subcommand exists ─────────────
section "Checking docker checkpoint command"
if docker checkpoint --help 2>&1 | grep -q "checkpoint"; then
  ok "docker checkpoint subcommand exists."
else
  fail "docker checkpoint subcommand not available."
  record_result "$TEST_NAME" "FAIL" "docker checkpoint subcommand not available in this Docker version."
  append_summary "| Docker checkpoint | :x: FAIL | Subcommand not available |"
  exit 1
fi

# ── Step 3: Enable Docker experimental features ─────────────────────
section "Enabling Docker experimental features"

log "Current docker info (Experimental):"
docker info 2>&1 | grep -i experimental || true

DAEMON_JSON="/etc/docker/daemon.json"
log "Current $DAEMON_JSON:"
sudo cat "$DAEMON_JSON" 2>/dev/null || log "(does not exist)"

# Build new daemon.json preserving existing content
if sudo test -f "$DAEMON_JSON"; then
  # Merge experimental:true into existing config
  EXISTING=$(sudo cat "$DAEMON_JSON")
  if echo "$EXISTING" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    NEW_CONFIG=$(echo "$EXISTING" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['experimental'] = True
json.dump(d, sys.stdout, indent=2)
")
  else
    # Not valid JSON, overwrite
    NEW_CONFIG='{"experimental": true}'
  fi
else
  NEW_CONFIG='{"experimental": true}'
fi

log "Writing daemon.json: $NEW_CONFIG"
echo "$NEW_CONFIG" | sudo tee "$DAEMON_JSON" > /dev/null

# Restart Docker
log "Restarting Docker daemon …"
RESTART_OK=false
if sudo systemctl restart docker 2>&1; then
  # Wait for docker to be ready
  for i in $(seq 1 30); do
    if docker info &>/dev/null; then
      RESTART_OK=true
      break
    fi
    sleep 1
  done
fi

if [[ "$RESTART_OK" == "true" ]]; then
  ok "Docker restarted successfully."
else
  warn "Docker restart may have failed; trying to continue …"
  # Try alternative: reload
  sudo systemctl reload docker 2>/dev/null || true
  sleep 5
  if ! docker info &>/dev/null; then
    # Try starting it
    sudo systemctl start docker 2>/dev/null || true
    sleep 5
  fi
fi

log "Docker info after restart:"
docker info 2>&1 | grep -iE "experimental|server version|storage driver|cgroup" || true

EXPERIMENTAL=$(docker info --format '{{.ExperimentalBuild}}' 2>/dev/null || echo "unknown")
log "Experimental enabled: $EXPERIMENTAL"

if [[ "$EXPERIMENTAL" != "true" ]]; then
  warn "Experimental features not enabled. Docker checkpoint may not work."
fi

# ── Step 4: Check CRIU compatibility with Docker's runc ──────────────
section "Checking runtime compatibility"
log "Docker runtime info:"
docker info --format '{{.DefaultRuntime}}' 2>/dev/null || true
docker info 2>&1 | grep -i runtime || true
log "runc version:"
runc --version 2>/dev/null || sudo runc --version 2>/dev/null || true

# ── Step 5: Start test container ─────────────────────────────────────
section "Starting test container"

# Start with minimal privileges, escalate if needed
CONTAINER_STARTED=false
CONTAINER_OPTS_USED=""

start_test_container() {
  local desc="$1"; shift
  log "Starting container ($desc) …"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  if docker run -d --name "$CONTAINER_NAME" "$@" \
      alpine:3.19 sh -c '
        i=0
        while true; do
          echo "tick=$i"
          echo "$i" > /tmp/counter
          i=$((i + 1))
          sleep 1
        done
      '; then
    CONTAINER_STARTED=true
    CONTAINER_OPTS_USED="$desc"
    return 0
  else
    return 1
  fi
}

# Try progressively more permissive settings
if ! start_test_container "minimal" ; then
  if ! start_test_container "seccomp=unconfined" \
       --security-opt seccomp=unconfined; then
    if ! start_test_container "seccomp+apparmor=unconfined" \
         --security-opt seccomp=unconfined \
         --security-opt apparmor=unconfined; then
      if ! start_test_container "with capabilities" \
           --security-opt seccomp=unconfined \
           --security-opt apparmor=unconfined \
           --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE; then
        start_test_container "privileged (last resort)" --privileged || true
      fi
    fi
  fi
fi

if [[ "$CONTAINER_STARTED" != "true" ]]; then
  fail "Could not start test container with any privilege level."
  record_result "$TEST_NAME" "FAIL" "Could not start test container."
  append_summary "| Docker checkpoint | :x: FAIL | Could not start test container |"
  exit 1
fi

ok "Container started ($CONTAINER_OPTS_USED)."
sleep 4  # Let counter tick

log "Container logs before checkpoint:"
docker logs "$CONTAINER_NAME" 2>&1 | tail -10

PRE_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
log "Counter value before checkpoint: $PRE_VALUE"

# ── Step 6: Create checkpoint ────────────────────────────────────────
section "Creating Docker checkpoint"

CKPT_OK=false
CKPT_ERROR=""

create_checkpoint() {
  local desc="$1"; shift
  log "Trying checkpoint ($desc) …"
  if docker checkpoint create "$@" "$CONTAINER_NAME" cp1 2>&1 | tee "$RESULTS_DIR/docker-ckpt-attempt.log"; then
    return 0
  else
    local rc=$?
    warn "Checkpoint failed ($desc), exit $rc"
    cat "$RESULTS_DIR/docker-ckpt-attempt.log" >> "$RESULTS_DIR/docker-ckpt-all-attempts.log" 2>/dev/null
    return $rc
  fi
}

# Approach 1: leave-running=false (default, freezes then stops container)
if create_checkpoint "default"; then
  CKPT_OK=true
fi

# Approach 2: leave-running=true (keeps container running)
if [[ "$CKPT_OK" != "true" ]]; then
  # Container might have been stopped by failed attempt, restart
  docker start "$CONTAINER_NAME" 2>/dev/null || true
  sleep 2
  if create_checkpoint "leave-running" --leave-running=true; then
    CKPT_OK=true
  fi
fi

# If both failed, try restarting container with privileged if not already
if [[ "$CKPT_OK" != "true" && "$CONTAINER_OPTS_USED" != *"privileged"* ]]; then
  log "Retrying with privileged container …"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  if start_test_container "privileged (retry)" --privileged; then
    sleep 4
    if create_checkpoint "privileged container"; then
      CKPT_OK=true
    fi
  fi
fi

if [[ "$CKPT_OK" != "true" ]]; then
  fail "Docker checkpoint creation failed."
  log "Attempting to capture Docker daemon logs …"
  sudo journalctl -u docker --no-pager -n 50 2>/dev/null | tee "$RESULTS_DIR/docker-daemon.log" || true
  log "CRIU check output:"
  sudo criu check 2>&1 | tee -a "$RESULTS_DIR/criu-check-docker.log" || true

  CKPT_ERROR=$(cat "$RESULTS_DIR/docker-ckpt-all-attempts.log" 2>/dev/null | tail -5 || echo "See logs")
  record_result "$TEST_NAME" "FAIL" "Docker checkpoint create failed: $CKPT_ERROR"
  append_summary "| Docker checkpoint | :x: FAIL | Checkpoint creation failed — see logs |"
  exit 1
fi

ok "Docker checkpoint created!"

# ── Step 7: Restore from checkpoint ──────────────────────────────────
section "Restoring from checkpoint"

log "Container status after checkpoint:"
docker ps -a --filter "name=$CONTAINER_NAME" --format '{{.Status}}' || true

RESTORE_OK=false

if docker start --checkpoint cp1 "$CONTAINER_NAME" 2>&1 | tee "$RESULTS_DIR/docker-restore.log"; then
  RESTORE_OK=true
fi

if [[ "$RESTORE_OK" != "true" ]]; then
  fail "Docker restore failed."
  sudo journalctl -u docker --no-pager -n 30 2>/dev/null >> "$RESULTS_DIR/docker-daemon.log" || true
  record_result "$TEST_NAME" "FAIL" "Docker checkpoint restore failed."
  append_summary "| Docker checkpoint | :x: FAIL | Restore from checkpoint failed |"
  exit 1
fi

ok "Restore succeeded!"

# ── Step 8: Verify state continuity ──────────────────────────────────
section "Verifying state continuity"
sleep 3

POST_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
log "Counter after restore: $POST_VALUE"

log "Container logs after restore:"
docker logs "$CONTAINER_NAME" 2>&1 | tail -10

if [[ "$POST_VALUE" != "unknown" && "$PRE_VALUE" != "unknown" ]]; then
  if (( POST_VALUE > PRE_VALUE )); then
    ok "State continuity verified: counter $PRE_VALUE -> $POST_VALUE"
    record_result "$TEST_NAME" "PASS" "Counter went from $PRE_VALUE to $POST_VALUE after restore."
    append_summary "| Docker checkpoint | :white_check_mark: PASS | Counter $PRE_VALUE -> $POST_VALUE |"
  else
    fail "Counter did not advance: $PRE_VALUE -> $POST_VALUE"
    record_result "$TEST_NAME" "FAIL" "Counter did not advance ($PRE_VALUE -> $POST_VALUE)."
    append_summary "| Docker checkpoint | :x: FAIL | Counter stalled ($PRE_VALUE -> $POST_VALUE) |"
    exit 1
  fi
else
  warn "Could not verify counter (pre=$PRE_VALUE, post=$POST_VALUE)"
  record_result "$TEST_NAME" "FAIL" "Could not read counter after restore."
  append_summary "| Docker checkpoint | :x: FAIL | Could not read counter after restore |"
  exit 1
fi

# Cleanup
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
