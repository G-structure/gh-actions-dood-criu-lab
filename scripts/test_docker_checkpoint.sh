#!/usr/bin/env bash
# test_docker_checkpoint.sh — Docker checkpoint/restore on the same worker.
#
# Tests `docker checkpoint create` / `docker start --checkpoint` with
# progressively more permissive container configurations until one works.
# Requires Docker experimental features + CRIU installed on the host.
#
# Working configuration on GitHub runners:
#   --net=host --security-opt seccomp=unconfined --security-opt apparmor=unconfined
# Plus containerd content blob purge before restore (moby#42900 workaround).
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

# ── Step 4: Check CRIU + runtime compatibility ───────────────────────
section "Checking runtime compatibility"
log "Default runtime: $(docker info --format '{{.DefaultRuntime}}' 2>/dev/null || echo unknown)"
log "runc version:"
runc --version 2>/dev/null || sudo runc --version 2>/dev/null || true
log "criu version:"
criu --version 2>/dev/null || true

# ── Step 5: Full checkpoint/restore cycle ─────────────────────────────
# Try progressively more permissive container configs. For each one, start
# a container, checkpoint it, purge stale containerd content blobs
# (moby#42900 workaround), restore, and verify counter continuity.
# We use Docker's built-in checkpoint storage (containerd v2 does NOT
# support --checkpoint-dir).

OVERALL_PASS=false

attempt_full_cycle() {
  local desc="$1"; shift
  local container_opts=("$@")

  section "Attempt: $desc"
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  log "Starting container ($desc) …"
  if ! docker run -d --name "$CONTAINER_NAME" "${container_opts[@]}" \
      alpine:3.19 sh -c '
        i=0
        while true; do
          echo "tick=$i"
          echo "$i" > /tmp/counter
          i=$((i + 1))
          sleep 1
        done
      '; then
    warn "Could not start container ($desc)."
    return 1
  fi

  ok "Container started ($desc)."
  sleep 5

  PRE_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
  log "Counter before checkpoint: $PRE_VALUE"

  # Create checkpoint (no --checkpoint-dir; use Docker default storage)
  log "Creating checkpoint …"
  if ! docker checkpoint create "$CONTAINER_NAME" cp1 2>&1 | tee "$RESULTS_DIR/docker-ckpt-attempt.log"; then
    warn "Checkpoint creation failed ($desc)."
    cat "$RESULTS_DIR/docker-ckpt-attempt.log" >> "$RESULTS_DIR/docker-ckpt-all-attempts.log" 2>/dev/null || true
    return 1
  fi
  ok "Checkpoint created."

  # Workaround for moby/moby#42900: purge stale content blobs
  log "Purging stale containerd content (moby#42900 workaround) …"
  STALE=$(sudo ctr -n moby content ls -q 2>/dev/null || true)
  if [[ -n "$STALE" ]]; then
    while IFS= read -r blob; do
      [[ -n "$blob" ]] && { log "  Removing: $blob"; sudo ctr -n moby content rm "$blob" 2>/dev/null || true; }
    done <<< "$STALE"
  fi

  # Restore
  log "Restoring from checkpoint …"
  if ! docker start --checkpoint cp1 "$CONTAINER_NAME" 2>&1 | tee "$RESULTS_DIR/docker-restore.log"; then
    warn "Restore failed ($desc)."
    cat "$RESULTS_DIR/docker-restore.log" >> "$RESULTS_DIR/docker-restore-all.log" 2>/dev/null || true
    return 1
  fi
  ok "Restore succeeded ($desc)!"

  # Verify state continuity
  sleep 4
  POST_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
  log "Counter after restore: $POST_VALUE"

  if [[ "$POST_VALUE" != "unknown" && "$PRE_VALUE" != "unknown" ]] && (( POST_VALUE > PRE_VALUE )); then
    ok "State continuity verified: counter $PRE_VALUE -> $POST_VALUE ($desc)"
    record_result "$TEST_NAME" "PASS" "Counter $PRE_VALUE -> $POST_VALUE ($desc)."
    append_summary "| Docker checkpoint | :white_check_mark: PASS | Counter $PRE_VALUE -> $POST_VALUE ($desc) |"
    OVERALL_PASS=true
    return 0
  else
    warn "Counter did not advance: $PRE_VALUE -> $POST_VALUE ($desc)"
    return 1
  fi
}

# Attempt 1: minimal
attempt_full_cycle "minimal" || true

# Attempt 2: seccomp=unconfined
if [[ "$OVERALL_PASS" != "true" ]]; then
  attempt_full_cycle "seccomp=unconfined" \
    --security-opt seccomp=unconfined || true
fi

# Attempt 3: seccomp+apparmor unconfined
if [[ "$OVERALL_PASS" != "true" ]]; then
  attempt_full_cycle "seccomp+apparmor=unconfined" \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined || true
fi

# Attempt 4: with capabilities
if [[ "$OVERALL_PASS" != "true" ]]; then
  attempt_full_cycle "with SYS_ADMIN+SYS_PTRACE" \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    --cap-add=SYS_ADMIN --cap-add=SYS_PTRACE || true
fi

# Attempt 5: net=host (workaround for containerd#12141 netns issue)
if [[ "$OVERALL_PASS" != "true" ]]; then
  attempt_full_cycle "net=host + seccomp=unconfined" \
    --net=host \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined || true
fi

# Attempt 6: fully privileged
if [[ "$OVERALL_PASS" != "true" ]]; then
  attempt_full_cycle "privileged" --privileged || true
fi

# Attempt 7: privileged + net=host
if [[ "$OVERALL_PASS" != "true" ]]; then
  attempt_full_cycle "privileged + net=host" --privileged --net=host || true
fi

if [[ "$OVERALL_PASS" != "true" ]]; then
  fail "Docker checkpoint/restore failed after all approaches."
  log "Docker daemon logs (last 80 lines):"
  sudo journalctl -u docker --no-pager -n 80 2>/dev/null | tee "$RESULTS_DIR/docker-daemon.log" || true
  log "All restore attempts:"
  cat "$RESULTS_DIR/docker-restore-all.log" 2>/dev/null || true
  log "All checkpoint attempts:"
  cat "$RESULTS_DIR/docker-ckpt-all-attempts.log" 2>/dev/null || true

  record_result "$TEST_NAME" "FAIL" "Docker checkpoint/restore failed — see logs for details."
  append_summary "| Docker checkpoint | :x: FAIL | All checkpoint/restore approaches failed — see logs |"
fi

# Cleanup
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
