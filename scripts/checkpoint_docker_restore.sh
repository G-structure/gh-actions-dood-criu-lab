#!/usr/bin/env bash
# checkpoint_docker_restore.sh — Restore a Docker container checkpoint
# that was exported from another worker.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TEST_NAME="docker_cross_restore"
LOG_FILE="$RESULTS_DIR/${TEST_NAME}.log"
exec > >(tee "$LOG_FILE") 2>&1

section "Docker Cross-Worker Checkpoint: RESTORE Phase"
print_env

EXPORT_DIR="$RESULTS_DIR/docker-migration-export"
CONTAINER_NAME="docker-migrate-restored-$$"
add_cleanup "docker rm -f $CONTAINER_NAME 2>/dev/null || true"

# ── Validate export exists ───────────────────────────────────────────
if [[ ! -d "$EXPORT_DIR" ]]; then
  fail "Export directory $EXPORT_DIR does not exist."
  record_result "$TEST_NAME" "FAIL" "Export directory not found."
  append_summary "| Docker cross-worker RESTORE | :x: FAIL | Export directory missing |"
  exit 1
fi

if [[ ! -f "$EXPORT_DIR/docker-migration-meta.json" ]]; then
  fail "Migration metadata not found."
  record_result "$TEST_NAME" "FAIL" "Metadata missing."
  exit 1
fi

log "Migration metadata from source worker:"
cat "$EXPORT_DIR/docker-migration-meta.json"

CHECKPOINT_VALUE=$(python3 -c "import json; print(json.load(open('$EXPORT_DIR/docker-migration-meta.json'))['counter_at_checkpoint'])")
SOURCE_HOST=$(python3 -c "import json; print(json.load(open('$EXPORT_DIR/docker-migration-meta.json'))['source_hostname'])")
CONTAINER_IMAGE=$(python3 -c "import json; print(json.load(open('$EXPORT_DIR/docker-migration-meta.json'))['container_image'])")
SOURCE_DOCKER=$(python3 -c "import json; print(json.load(open('$EXPORT_DIR/docker-migration-meta.json'))['docker_version'])")

log "Source: $SOURCE_HOST, Docker $SOURCE_DOCKER, Counter at $CHECKPOINT_VALUE"
log "Image: $CONTAINER_IMAGE"

# ── Install CRIU + enable experimental ───────────────────────────────
bash "$SCRIPT_DIR/install_criu.sh"

section "Enabling Docker experimental features"
DAEMON_JSON="/etc/docker/daemon.json"
if sudo test -f "$DAEMON_JSON"; then
  EXISTING=$(sudo cat "$DAEMON_JSON")
  NEW_CONFIG=$(echo "$EXISTING" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['experimental'] = True
json.dump(d, sys.stdout, indent=2)
" 2>/dev/null || echo '{"experimental": true}')
else
  NEW_CONFIG='{"experimental": true}'
fi
echo "$NEW_CONFIG" | sudo tee "$DAEMON_JSON" > /dev/null
sudo systemctl restart docker
for i in $(seq 1 30); do docker info &>/dev/null && break; sleep 1; done
ok "Docker restarted with experimental."

# ── Pull the same image ──────────────────────────────────────────────
section "Pulling container image"
retry 3 docker pull "$CONTAINER_IMAGE"

# ── Attempt restore methods ──────────────────────────────────────────
section "Attempting cross-worker Docker checkpoint restore"

RESTORE_OK=false

# Method 1: Import via ctr checkpoint restore if we have a ctr-checkpoint.tar
if [[ -f "$EXPORT_DIR/ctr-checkpoint.tar" ]]; then
  log "Found ctr checkpoint tar. Attempting containerd restore …"

  # Create a container first, then try to restore from checkpoint
  docker run -d --name "$CONTAINER_NAME" \
    --net=host \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    "$CONTAINER_IMAGE" sh -c 'sleep 1' 2>/dev/null || true

  CONTAINER_ID=$(docker inspect "$CONTAINER_NAME" --format '{{.Id}}' 2>/dev/null || echo "")

  if [[ -n "$CONTAINER_ID" ]]; then
    # Try to import the checkpoint into containerd and restore
    log "Importing checkpoint for container $CONTAINER_ID …"
    if sudo ctr -n moby containers restore "$CONTAINER_ID" "$EXPORT_DIR/ctr-checkpoint.tar" 2>&1; then
      ok "ctr restore succeeded!"
      RESTORE_OK=true
    else
      warn "ctr restore failed."
    fi
  fi

  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
fi

# Method 2: Import content blobs and try docker checkpoint restore
if [[ "$RESTORE_OK" != "true" && -d "$EXPORT_DIR/content-blobs" ]]; then
  log "Trying to import content blobs and restore …"

  # Create a new container with the same image and config
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker run -d --name "$CONTAINER_NAME" \
    --net=host \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    "$CONTAINER_IMAGE" sh -c '
      i=0
      while true; do
        echo "tick=$i host=$(hostname)"
        echo "$i" > /tmp/counter
        i=$((i + 1))
        sleep 1
      done
    '
  sleep 2

  CONTAINER_ID=$(docker inspect "$CONTAINER_NAME" --format '{{.Id}}')

  # Import the content blobs into containerd
  for blob_file in "$EXPORT_DIR/content-blobs"/*; do
    [[ -f "$blob_file" ]] || continue
    DIGEST=$(basename "$blob_file" | tr '_' ':' | sed 's/_/\//')
    log "  Importing content blob: $DIGEST"
    cat "$blob_file" | sudo ctr -n moby content ingest --ref "imported-$(date +%s)" 2>/dev/null || true
  done

  # Create a checkpoint on this container first, then try to overlay the imported data
  docker stop "$CONTAINER_NAME" 2>/dev/null || true

  # Try creating a checkpoint and then replacing with imported data
  if [[ -d "$EXPORT_DIR/raw-checkpoint-data" ]]; then
    CKPT_DIR="/var/lib/docker/containers/$CONTAINER_ID/checkpoints"
    sudo mkdir -p "$CKPT_DIR/cp1" 2>/dev/null || true
    sudo cp -a "$EXPORT_DIR/raw-checkpoint-data/." "$CKPT_DIR/cp1/" 2>/dev/null || true

    # Purge containerd content
    STALE=$(sudo ctr -n moby content ls -q 2>/dev/null || true)
    while IFS= read -r blob; do
      [[ -n "$blob" ]] && sudo ctr -n moby content rm "$blob" 2>/dev/null || true
    done <<< "$STALE"

    if docker start --checkpoint cp1 "$CONTAINER_NAME" 2>&1; then
      ok "Restore from imported checkpoint data succeeded!"
      RESTORE_OK=true
    else
      warn "Restore from imported checkpoint data failed."
    fi
  fi
fi

# Method 3: Filesystem-only restore (not a true checkpoint restore, but shows the concept)
if [[ "$RESTORE_OK" != "true" && -f "$EXPORT_DIR/container-fs.tar" ]]; then
  log "True cross-worker Docker checkpoint restore not possible with current containerd."
  log "The checkpoint data is tied to the specific container ID and containerd instance."
  log ""
  log "Demonstrating filesystem-state import instead (not process-state) …"

  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

  # Import the filesystem and create a new image from it
  IMPORTED_IMAGE="migrated-container:latest"
  docker import "$EXPORT_DIR/container-fs.tar" "$IMPORTED_IMAGE" 2>&1 || true

  if docker images "$IMPORTED_IMAGE" --format '{{.Repository}}' 2>/dev/null | grep -q migrated; then
    log "Filesystem imported as image: $IMPORTED_IMAGE"
    # Run a new container from the imported filesystem
    docker run -d --name "$CONTAINER_NAME" --net=host \
      "$IMPORTED_IMAGE" sh -c '
        # Read counter from the imported filesystem state
        if [ -f /tmp/counter ]; then
          i=$(cat /tmp/counter)
          echo "Resumed from imported filesystem, counter was at $i"
          i=$((i + 1))
        else
          i=0
          echo "No previous counter found"
        fi
        while true; do
          echo "tick=$i host=$(hostname)"
          echo "$i" > /tmp/counter
          i=$((i + 1))
          sleep 1
        done
      '
    sleep 3
    POST_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
    log "Counter after filesystem import: $POST_VALUE"
    # This is a qualified success — filesystem state was preserved, not process state
    warn "This is filesystem-state migration only, not true process checkpoint/restore."
  fi
fi

# ── Final verdict ────────────────────────────────────────────────────
section "Cross-Worker Docker Checkpoint Results"

if [[ "$RESTORE_OK" == "true" ]]; then
  sleep 4
  POST_VALUE=$(docker exec "$CONTAINER_NAME" cat /tmp/counter 2>/dev/null || echo "unknown")
  log "Counter after restore: $POST_VALUE"

  if [[ "$POST_VALUE" != "unknown" ]] && (( POST_VALUE > CHECKPOINT_VALUE )); then
    ok "CROSS-WORKER Docker checkpoint/restore succeeded!"
    ok "Counter: $CHECKPOINT_VALUE -> $POST_VALUE (migrated from $SOURCE_HOST)"
    record_result "$TEST_NAME" "PASS" "Cross-worker Docker restore succeeded. Counter $CHECKPOINT_VALUE -> $POST_VALUE."
    append_summary "| Docker cross-worker RESTORE | :white_check_mark: PASS | Counter $CHECKPOINT_VALUE -> $POST_VALUE |"
  else
    warn "Restore succeeded but counter didn't advance as expected."
    record_result "$TEST_NAME" "FAIL" "Counter didn't advance ($CHECKPOINT_VALUE -> $POST_VALUE)."
    append_summary "| Docker cross-worker RESTORE | :x: FAIL | Counter didn't advance |"
  fi
else
  fail "Cross-worker Docker checkpoint restore is NOT possible with current Docker/containerd."
  log ""
  log "Root cause: Docker checkpoints are stored in containerd's content-addressed"
  log "store tied to the specific container ID and containerd instance. There is no"
  log "supported API to export a checkpoint from one Docker daemon and import it into"
  log "another. The containerd v2 backend does not support --checkpoint-dir for restore,"
  log "and checkpoint content blobs are keyed by container-specific digests."
  log ""
  log "Possible alternatives:"
  log "  1. Use CRIU directly (not Docker) for process migration — this WORKS"
  log "  2. Use Podman which has 'podman container checkpoint --export' support"
  log "  3. Use buildah/skopeo for container filesystem migration"
  log "  4. Wait for Docker/containerd to add checkpoint export/import APIs"

  record_result "$TEST_NAME" "FAIL" "Cross-worker Docker checkpoint not possible — containerd ties checkpoints to specific container instances."
  append_summary "| Docker cross-worker RESTORE | :x: FAIL | Not possible — checkpoints are instance-bound in containerd v2 |"
fi

docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
