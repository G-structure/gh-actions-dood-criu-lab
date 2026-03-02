#!/usr/bin/env bash
# checkpoint_criu_restore.sh — Download a CRIU dump from another worker,
# restore the process, and verify state continuity.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TEST_NAME="criu_cross_restore"
LOG_FILE="$RESULTS_DIR/${TEST_NAME}.log"
exec > >(tee "$LOG_FILE") 2>&1

section "CRIU Cross-Worker: RESTORE Phase"
print_env

DUMP_DIR="$RESULTS_DIR/criu-migration-dump"
COUNTER_FILE="/tmp/criu-migrate-counter"
WORKER_SCRIPT="/tmp/criu_migrator.sh"

# ── Validate dump exists ─────────────────────────────────────────────
if [[ ! -d "$DUMP_DIR" ]]; then
  fail "Dump directory $DUMP_DIR does not exist. Was the artifact downloaded?"
  record_result "$TEST_NAME" "FAIL" "Dump directory not found."
  append_summary "| CRIU cross-worker RESTORE | :x: FAIL | Dump directory missing |"
  exit 1
fi

log "Dump directory contents:"
ls -la "$DUMP_DIR"

if [[ ! -f "$DUMP_DIR/migration-meta.json" ]]; then
  fail "migration-meta.json not found in dump."
  record_result "$TEST_NAME" "FAIL" "Migration metadata missing."
  exit 1
fi

log "Migration metadata from source worker:"
cat "$DUMP_DIR/migration-meta.json"

# Extract metadata
CHECKPOINT_VALUE=$(python3 -c "import json; print(json.load(open('$DUMP_DIR/migration-meta.json'))['counter_at_checkpoint'])")
SOURCE_HOST=$(python3 -c "import json; print(json.load(open('$DUMP_DIR/migration-meta.json'))['source_hostname'])")
SOURCE_KERNEL=$(python3 -c "import json; print(json.load(open('$DUMP_DIR/migration-meta.json'))['source_kernel'])")

log "Source host: $SOURCE_HOST"
log "Source kernel: $SOURCE_KERNEL"
log "Current host: $(hostname)"
log "Current kernel: $(uname -r)"
log "Counter was at: $CHECKPOINT_VALUE"

# ── Install CRIU ─────────────────────────────────────────────────────
bash "$SCRIPT_DIR/install_criu.sh"

# ── Set up the worker script at the expected path ────────────────────
section "Preparing restore environment"

# The CRIU dump recorded the path of the binary. We must place it there.
if [[ -f "$DUMP_DIR/criu_migrator.sh" ]]; then
  log "Installing worker script to $WORKER_SCRIPT"
  cp "$DUMP_DIR/criu_migrator.sh" "$WORKER_SCRIPT"
  chmod +x "$WORKER_SCRIPT"
else
  fail "Worker script not found in dump directory."
  record_result "$TEST_NAME" "FAIL" "Worker script missing from dump."
  exit 1
fi

# CRIU requires that files the process had open exist at their original paths
# AND that their sizes match the checkpoint. Restore saved copies from the dump.
rm -f "$COUNTER_FILE" /tmp/criu-migrator-output.log

if [[ -f "$DUMP_DIR/saved-output.log" ]]; then
  cp "$DUMP_DIR/saved-output.log" /tmp/criu-migrator-output.log
  log "Restored output log ($(wc -c < /tmp/criu-migrator-output.log) bytes)"
else
  touch /tmp/criu-migrator-output.log
  warn "No saved output log in dump — created empty (may fail size check)"
fi

if [[ -f "$DUMP_DIR/saved-counter" ]]; then
  cp "$DUMP_DIR/saved-counter" "$COUNTER_FILE"
  log "Restored counter file ($(cat "$COUNTER_FILE"))"
else
  touch "$COUNTER_FILE"
  warn "No saved counter in dump — created empty"
fi

# ── Attempt CRIU restore ─────────────────────────────────────────────
section "Restoring process from checkpoint"

RESTORE_OK=false

try_restore() {
  local desc="$1"; shift
  log "Trying restore: $desc"
  log "Command: sudo criu restore $*"
  local rc=0
  sudo criu restore "$@" 2>&1 | tee "$RESULTS_DIR/criu-cross-restore-attempt.log" || rc=$?
  return $rc
}

# Kill any process using the original PID (cross-worker PID conflict is expected)
ORIG_PID=$(python3 -c "import json; print(json.load(open('$DUMP_DIR/migration-meta.json'))['worker_pid'])" 2>/dev/null || echo "")
if [[ -n "$ORIG_PID" ]] && kill -0 "$ORIG_PID" 2>/dev/null; then
  log "PID $ORIG_PID is in use on this worker. Killing it to free the PID."
  sudo kill -9 "$ORIG_PID" 2>/dev/null || true
  sleep 1
fi

# Approach 1: Standard restore (may fail if PIDs conflict)
if try_restore "standard" -D "$DUMP_DIR" --shell-job -v4 --log-file restore.log -d; then
  RESTORE_OK=true
fi

# Approach 2: With --restore-sibling (avoids PID namespace issues)
if [[ "$RESTORE_OK" != "true" ]]; then
  if try_restore "with --restore-sibling" -D "$DUMP_DIR" --shell-job --restore-sibling -v4 --log-file restore.log -d; then
    RESTORE_OK=true
  fi
fi

# Approach 3: Restore into a new PID namespace (avoids PID conflicts entirely)
if [[ "$RESTORE_OK" != "true" ]]; then
  log "Trying restore in a new PID namespace (unshare) …"
  UNSHARE_RC=0
  sudo unshare --pid --fork --mount-proc criu restore \
    -D "$DUMP_DIR" --shell-job -v4 --log-file restore.log -d 2>&1 \
    | tee "$RESULTS_DIR/criu-cross-restore-attempt.log" || UNSHARE_RC=$?
  if [[ $UNSHARE_RC -eq 0 ]]; then
    RESTORE_OK=true
    log "Restore in new PID namespace succeeded."
  else
    warn "Restore in new PID namespace failed (exit $UNSHARE_RC)."
  fi
fi

# Approach 4: With --ext-unix-sk
if [[ "$RESTORE_OK" != "true" ]]; then
  if try_restore "with --ext-unix-sk" -D "$DUMP_DIR" --shell-job --ext-unix-sk -v4 --log-file restore.log -d; then
    RESTORE_OK=true
  fi
fi

# Approach 5: With --tcp-established
if [[ "$RESTORE_OK" != "true" ]]; then
  if try_restore "with --tcp-established" -D "$DUMP_DIR" --shell-job --tcp-established -v4 --log-file restore.log -d; then
    RESTORE_OK=true
  fi
fi

# Save restore log
if sudo test -f "$DUMP_DIR/restore.log"; then
  sudo cp "$DUMP_DIR/restore.log" "$RESULTS_DIR/criu-cross-restore.log"
  sudo chmod 644 "$RESULTS_DIR/criu-cross-restore.log"
fi

if [[ "$RESTORE_OK" != "true" ]]; then
  fail "CRIU restore failed on this worker."
  log "Restore log (last 60 lines):"
  sudo cat "$DUMP_DIR/restore.log" 2>/dev/null | tail -60 || true
  log "dmesg (last 20 lines):"
  sudo dmesg | tail -20 2>/dev/null || true

  record_result "$TEST_NAME" "FAIL" "CRIU restore failed on different worker."
  append_summary "| CRIU cross-worker RESTORE | :x: FAIL | Restore failed on different worker |"
  exit 1
fi

ok "Process restored on this worker!"

# ── Verify state continuity ──────────────────────────────────────────
section "Verifying state continuity (cross-worker)"
log "Waiting for restored process to advance counter …"
sleep 5

POST_VALUE=$(cat "$COUNTER_FILE" 2>/dev/null || echo "unknown")
log "Counter value after cross-worker restore: $POST_VALUE"

log "Process output (last 10 lines):"
cat /tmp/criu-migrator-output.log 2>/dev/null | tail -10 || true

if [[ "$POST_VALUE" != "unknown" && "$CHECKPOINT_VALUE" != "unknown" ]]; then
  if (( POST_VALUE > CHECKPOINT_VALUE )); then
    ok "CROSS-WORKER state continuity verified!"
    ok "Process migrated from $SOURCE_HOST to $(hostname)"
    ok "Counter: $CHECKPOINT_VALUE (at checkpoint) -> $POST_VALUE (after restore on new worker)"
    record_result "$TEST_NAME" "PASS" "Cross-worker restore succeeded. Counter $CHECKPOINT_VALUE -> $POST_VALUE. Migrated from $SOURCE_HOST to $(hostname)."
    append_summary "| CRIU cross-worker RESTORE | :white_check_mark: PASS | Counter $CHECKPOINT_VALUE -> $POST_VALUE (migrated from $SOURCE_HOST) |"
  else
    fail "Counter did not advance: checkpoint=$CHECKPOINT_VALUE, now=$POST_VALUE"
    record_result "$TEST_NAME" "FAIL" "Counter did not advance after cross-worker restore ($CHECKPOINT_VALUE -> $POST_VALUE)."
    append_summary "| CRIU cross-worker RESTORE | :x: FAIL | Counter stalled ($CHECKPOINT_VALUE -> $POST_VALUE) |"
    exit 1
  fi
else
  fail "Could not read counter (post=$POST_VALUE)"
  record_result "$TEST_NAME" "FAIL" "Counter file not readable after restore."
  append_summary "| CRIU cross-worker RESTORE | :x: FAIL | Cannot read counter after restore |"
  exit 1
fi

# Cleanup the restored process
sudo pkill -f criu_migrator || true
sudo chmod -R a+rX "$DUMP_DIR" 2>/dev/null || true
