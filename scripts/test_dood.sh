#!/usr/bin/env bash
# test_dood.sh — Docker-out-of-Docker test
#
# Runs a Docker CLI container that talks to the host daemon via the
# mounted /var/run/docker.sock, proving sibling-container creation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TEST_NAME="dood"
LOG_FILE="$RESULTS_DIR/${TEST_NAME}.log"
exec > >(tee "$LOG_FILE") 2>&1

section "Docker-out-of-Docker (DOOD) Test"
print_env

CHILD_NAME="dood-child-$$"
DOOD_CONTAINER="dood-runner-$$"
add_cleanup "docker rm -f $CHILD_NAME 2>/dev/null || true"
add_cleanup "docker rm -f $DOOD_CONTAINER 2>/dev/null || true"

# ── Step 1: Pull images ─────────────────────────────────────────────
log "Pulling docker:cli image …"
retry 3 docker pull docker:cli

log "Pulling alpine:3.19 …"
retry 3 docker pull alpine:3.19

# ── Step 2: Launch DOOD container ────────────────────────────────────
log "Running DOOD container with host socket …"
docker run --rm --name "$DOOD_CONTAINER" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e CHILD_NAME="$CHILD_NAME" \
  docker:cli sh -c '
    set -e
    echo "=== Inside DOOD container ==="
    echo "--- docker version ---"
    docker version
    echo "--- docker ps (from inside) ---"
    docker ps
    echo "--- docker run hello-world ---"
    docker run --rm hello-world
    echo "--- launching sibling container ---"
    docker run -d --name "$CHILD_NAME" alpine:3.19 sh -c "echo started; sleep 300"
    echo "--- done inside DOOD container ---"
  '

# ── Step 3: Verify sibling container visible on host ─────────────────
log "Verifying sibling container is visible on the host …"
sleep 2
FOUND=$(docker ps --filter "name=$CHILD_NAME" --format '{{.Names}}' || true)

if [[ "$FOUND" == "$CHILD_NAME" ]]; then
  ok "DOOD works! Sibling container '$CHILD_NAME' visible on host."
  record_result "$TEST_NAME" "PASS" "Sibling container created via DOOD and visible on host."
  append_summary "| DOOD | :white_check_mark: PASS | Sibling container created and verified on host |"
  EXIT_CODE=0
else
  fail "Sibling container '$CHILD_NAME' NOT visible on host. Found: '$FOUND'"
  log "docker ps -a:"
  docker ps -a
  record_result "$TEST_NAME" "FAIL" "Sibling container not visible on host. Found: '$FOUND'"
  append_summary "| DOOD | :x: FAIL | Sibling container not visible on host |"
  EXIT_CODE=1
fi

# ── Cleanup ──────────────────────────────────────────────────────────
docker rm -f "$CHILD_NAME" 2>/dev/null || true

exit "$EXIT_CODE"
