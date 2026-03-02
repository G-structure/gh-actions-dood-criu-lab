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
CKPT_DIR="/tmp/docker-ckpt-dir-$$"
mkdir -p "$CKPT_DIR"
add_cleanup "docker rm -f $CONTAINER_NAME 2>/dev/null || true"
add_cleanup "rm -rf $CKPT_DIR"

# ── Step 1: Install CRIU on host ─────────────────────────────────────
bash "$SCRIPT_DIR/install_criu.sh"

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
  EXISTING=$(sudo cat "$DAEMON_JSON")
  if echo "$EXISTING" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    NEW_CONFIG=$(echo "$EXISTING" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['experimental'] = True
json.dump(d, sys.stdout, indent=2)
")
  else
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
  sudo systemctl start docker 2>/dev/null || true
  sleep 5
fi

log "Docker info after restart:"
docker info 2>&1 | grep -iE "experimental|server version|storage driver|cgroup" || true

EXPERIMENTAL=$(docker info --format '{{.ExperimentalBuild}}' 2>/dev/null || echo "unknown")
log "Experimental enabled: $EXPERIMENTAL"

if [[ "$EXPERIMENTAL" != "true" ]]; then
  warn "Experimental features not enabled. Docker checkpoint may not work."
fi

# ── Step 4: Check CRIU + runtime compatibility ───────────────────────
section "Checking runtime compatibility"
log "Default runtime: $(docker info --format '{{.DefaultRuntime}}' 2>/dev/null || echo unknown)"
log "runc version:"
runc --version 2>/dev/null || sudo runc --version 2>/dev/null || true
log "criu version:"
criu --version 2>/dev/null || true
log "criu check:"
sudo criu check 2>&1 | tail -5 || true

# ── Step 5: Start test container ─────────────────────────────────────
section "Starting test container"

# Try progressively more permissive settings
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

# Escalating privilege levels
start_test_container "minimal" || \
start_test_container "seccomp=unconfined" \
     --security-opt seccomp=unconfined || \
start_test_container "seccomp+apparmor=unconfined" \
     --security-opt seccomp=unconfined \
     --security-opt apparmor=unconfined || \
start_test_container "with capabilities" \
     --security-opt seccomp=unconfined \
     --security-opt apparmor=unconfined \
     --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE || \
start_test_container "privileged (last resort)" --privileged || true

if [[ "$CONTAINER_STARTED" != "true" ]]; then
  fail "Could not start test container with any privilege level."
  record_result "$TEST_NAME" "FAIL" "Could not start test container."
  append_summary "| Docker checkpoint | :x: FAIL | Could not start test container |"
  exit 1
fi

ok "Container started ($CONTAINER_OPTS_USED)."
sleep 5  # Let counter tick

log "Container logs before checkpoint:"
docker logs "$CONTAINER_NAME" 2>&1 | tail -10

PRE_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
log "Counter value before checkpoint: $PRE_VALUE"

# ── Step 6: Create checkpoint ────────────────────────────────────────
section "Creating Docker checkpoint"

CKPT_OK=false

create_checkpoint() {
  local desc="$1"; shift
  log "Trying checkpoint ($desc) …"
  local rc=0
  docker checkpoint create "$@" "$CONTAINER_NAME" cp1 2>&1 | tee "$RESULTS_DIR/docker-ckpt-attempt.log" || rc=$?
  if [[ $rc -eq 0 ]]; then
    return 0
  else
    warn "Checkpoint failed ($desc), exit $rc"
    cat "$RESULTS_DIR/docker-ckpt-attempt.log" >> "$RESULTS_DIR/docker-ckpt-all-attempts.log" 2>/dev/null || true
    return $rc
  fi
}

# Try with external checkpoint directory to avoid containerd content-store collision
if create_checkpoint "with --checkpoint-dir" --checkpoint-dir="$CKPT_DIR"; then
  CKPT_OK=true
fi

# Fallback: try default location
if [[ "$CKPT_OK" != "true" ]]; then
  docker start "$CONTAINER_NAME" 2>/dev/null || true
  sleep 2
  if create_checkpoint "default location"; then
    CKPT_OK=true
  fi
fi

# If both failed, try with privileged container
if [[ "$CKPT_OK" != "true" && "$CONTAINER_OPTS_USED" != *"privileged"* ]]; then
  log "Retrying with privileged container …"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  if start_test_container "privileged (retry)" --privileged; then
    sleep 5
    if create_checkpoint "privileged + checkpoint-dir" --checkpoint-dir="$CKPT_DIR"; then
      CKPT_OK=true
    fi
  fi
fi

if [[ "$CKPT_OK" != "true" ]]; then
  fail "Docker checkpoint creation failed."
  log "Docker daemon logs (last 50 lines):"
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

# Workaround for "content sha256:... already exists" bug (moby/moby#42900):
# Purge any stale content blobs from containerd's moby namespace
log "Purging stale containerd content blobs (workaround for moby#42900) …"
STALE_BLOBS=$(sudo ctr -n moby content ls -q 2>/dev/null || true)
if [[ -n "$STALE_BLOBS" ]]; then
  while IFS= read -r blob; do
    log "  Removing content: $blob"
    sudo ctr -n moby content rm "$blob" 2>/dev/null || true
  done <<< "$STALE_BLOBS"
fi

RESTORE_OK=false
RESTORE_ERROR=""

# Try restore with --checkpoint-dir if we used it for create
if [[ -d "$CKPT_DIR/cp1" ]]; then
  log "Restoring with --checkpoint-dir=$CKPT_DIR …"
  if docker start --checkpoint cp1 --checkpoint-dir="$CKPT_DIR" "$CONTAINER_NAME" 2>&1 | tee "$RESULTS_DIR/docker-restore.log"; then
    RESTORE_OK=true
  else
    RESTORE_ERROR=$(cat "$RESULTS_DIR/docker-restore.log" 2>/dev/null | tail -3)
    warn "Restore with checkpoint-dir failed: $RESTORE_ERROR"
  fi
fi

# Try default restore
if [[ "$RESTORE_OK" != "true" ]]; then
  log "Trying default restore …"
  if docker start --checkpoint cp1 "$CONTAINER_NAME" 2>&1 | tee "$RESULTS_DIR/docker-restore.log"; then
    RESTORE_OK=true
  else
    RESTORE_ERROR=$(cat "$RESULTS_DIR/docker-restore.log" 2>/dev/null | tail -3)
    warn "Default restore failed: $RESTORE_ERROR"
  fi
fi

# If still failing, try recreating with --net=host (workaround for containerd#12141)
if [[ "$RESTORE_OK" != "true" ]]; then
  log "Retrying entire flow with --net=host (workaround for containerd netns issue) …"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  rm -rf "$CKPT_DIR"/*

  NET_HOST_OPTS=(--net=host --security-opt seccomp=unconfined --security-opt apparmor=unconfined)
  if start_test_container "net=host + seccomp=unconfined" "${NET_HOST_OPTS[@]}"; then
    sleep 5
    PRE_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
    log "Counter before checkpoint (net=host attempt): $PRE_VALUE"

    if create_checkpoint "net=host + checkpoint-dir" --checkpoint-dir="$CKPT_DIR"; then
      # Purge containerd content again
      STALE=$(sudo ctr -n moby content ls -q 2>/dev/null || true)
      while IFS= read -r blob; do
        [[ -n "$blob" ]] && sudo ctr -n moby content rm "$blob" 2>/dev/null || true
      done <<< "$STALE"

      if docker start --checkpoint cp1 --checkpoint-dir="$CKPT_DIR" "$CONTAINER_NAME" 2>&1 | tee "$RESULTS_DIR/docker-restore.log"; then
        RESTORE_OK=true
      fi
    fi
  fi
fi

# Last resort: privileged + net=host
if [[ "$RESTORE_OK" != "true" ]]; then
  log "Last resort: privileged + net=host …"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  rm -rf "$CKPT_DIR"/*

  if start_test_container "privileged + net=host" --privileged --net=host; then
    sleep 5
    PRE_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
    log "Counter before checkpoint (privileged+net=host): $PRE_VALUE"

    if create_checkpoint "privileged + net=host + checkpoint-dir" --checkpoint-dir="$CKPT_DIR"; then
      STALE=$(sudo ctr -n moby content ls -q 2>/dev/null || true)
      while IFS= read -r blob; do
        [[ -n "$blob" ]] && sudo ctr -n moby content rm "$blob" 2>/dev/null || true
      done <<< "$STALE"

      if docker start --checkpoint cp1 --checkpoint-dir="$CKPT_DIR" "$CONTAINER_NAME" 2>&1 | tee "$RESULTS_DIR/docker-restore.log"; then
        RESTORE_OK=true
      fi
    fi
  fi
fi

if [[ "$RESTORE_OK" != "true" ]]; then
  fail "Docker restore failed after all approaches."
  log "Docker daemon logs (last 60 lines):"
  sudo journalctl -u docker --no-pager -n 60 2>/dev/null | tee "$RESULTS_DIR/docker-daemon.log" || true
  log "Last restore attempt output:"
  cat "$RESULTS_DIR/docker-restore.log" 2>/dev/null || true

  record_result "$TEST_NAME" "FAIL" "Docker checkpoint restore failed: ${RESTORE_ERROR:-see logs}"
  append_summary "| Docker checkpoint | :x: FAIL | Restore from checkpoint failed — see logs |"
  exit 1
fi

ok "Restore succeeded!"

# ── Step 8: Verify state continuity ──────────────────────────────────
section "Verifying state continuity"
sleep 4

POST_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
log "Counter after restore: $POST_VALUE"

log "Container logs after restore (last 10):"
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
