#!/usr/bin/env bash
# test_criu_process.sh — CRIU direct process checkpoint/restore test
#
# Attempts to checkpoint a running host process with CRIU and restore it,
# verifying state continuity (counter resumes, doesn't restart at 0).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TEST_NAME="criu_process"
LOG_FILE="$RESULTS_DIR/${TEST_NAME}.log"
exec > >(tee "$LOG_FILE") 2>&1

section "CRIU Direct Process Checkpoint/Restore Test"
print_env

DUMP_DIR="$RESULTS_DIR/criu-dump"
COUNTER_FILE="/tmp/criu-counter-$$"
WORKER_PIDFILE="/tmp/criu-worker-$$.pid"
mkdir -p "$DUMP_DIR"
add_cleanup "rm -f $COUNTER_FILE $WORKER_PIDFILE"

# ── Step 1: Install CRIU ─────────────────────────────────────────────
section "Installing CRIU"
retry 3 sudo apt-get update -qq
retry 3 sudo apt-get install -y criu
criu --version
log "CRIU installed."

# ── Step 2: CRIU pre-flight check ────────────────────────────────────
section "CRIU Check"
log "Running 'sudo criu check' …"
if sudo criu check 2>&1 | tee "$RESULTS_DIR/criu-check.log"; then
  ok "criu check passed."
else
  warn "criu check reported issues (may still work for simple cases)."
fi

# Also capture kernel config hints
log "Checking kernel config for CRIU support …"
if [[ -f /boot/config-$(uname -r) ]]; then
  grep -i checkpoint /boot/config-"$(uname -r)" 2>/dev/null | head -20 || true
fi
log "Loaded modules (checkpoint-related):"
lsmod 2>/dev/null | grep -iE 'criu|checkpoint|netns' || log "(none found)"

# ── Step 3: Start demo process ───────────────────────────────────────
section "Starting counter process"

# We need the process to run in its own session for CRIU tree dump.
# Use setsid so it becomes a session leader.
cat > /tmp/criu_counter_worker.sh <<'WORKER'
#!/usr/bin/env bash
counter=0
while true; do
  echo "$counter" > "$1"
  echo "counter=$counter (pid=$$)"
  counter=$((counter + 1))
  sleep 1
done
WORKER
chmod +x /tmp/criu_counter_worker.sh

setsid bash /tmp/criu_counter_worker.sh "$COUNTER_FILE" &>/tmp/criu-worker-output.log &
WORKER_PID=$!
echo "$WORKER_PID" > "$WORKER_PIDFILE"
add_cleanup "kill $WORKER_PID 2>/dev/null || true"

log "Worker started with PID $WORKER_PID"
sleep 4  # Let counter run to at least 3

PRE_VALUE=$(cat "$COUNTER_FILE" 2>/dev/null || echo "unknown")
log "Counter value before checkpoint: $PRE_VALUE"

if [[ "$PRE_VALUE" == "unknown" || "$PRE_VALUE" -lt 2 ]]; then
  warn "Counter may not have advanced enough; continuing anyway."
fi

# ── Step 4: Attempt CRIU checkpoint ──────────────────────────────────
section "Attempting CRIU Checkpoint"

CRIU_EXIT=0
CRIU_ERROR=""

# Try multiple approaches
try_checkpoint() {
  local desc="$1"; shift
  log "Trying: $desc"
  log "Command: sudo criu dump $*"
  if sudo criu dump "$@" 2>&1 | tee "$RESULTS_DIR/criu-dump-attempt.log"; then
    return 0
  else
    local rc=$?
    warn "Failed (exit $rc): $desc"
    cat "$RESULTS_DIR/criu-dump-attempt.log" >> "$RESULTS_DIR/criu-dump-all-attempts.log"
    return $rc
  fi
}

CHECKPOINT_OK=false

# Approach 1: Standard tree dump
if try_checkpoint "Standard tree dump" \
    -t "$WORKER_PID" -D "$DUMP_DIR" --shell-job -v4 --log-file dump.log; then
  CHECKPOINT_OK=true
fi

# Approach 2: With tcp-established and file-locks
if [[ "$CHECKPOINT_OK" != "true" ]]; then
  rm -rf "$DUMP_DIR"/*
  if try_checkpoint "With --tcp-established --file-locks" \
      -t "$WORKER_PID" -D "$DUMP_DIR" --shell-job --tcp-established --file-locks -v4 --log-file dump.log; then
    CHECKPOINT_OK=true
  fi
fi

# Approach 3: Without --shell-job, redirect output
if [[ "$CHECKPOINT_OK" != "true" ]]; then
  rm -rf "$DUMP_DIR"/*
  if try_checkpoint "Without --shell-job" \
      -t "$WORKER_PID" -D "$DUMP_DIR" -v4 --log-file dump.log; then
    CHECKPOINT_OK=true
  fi
fi

# Approach 4: Trying with --ext-unix-sk
if [[ "$CHECKPOINT_OK" != "true" ]]; then
  rm -rf "$DUMP_DIR"/*
  if try_checkpoint "With --ext-unix-sk" \
      -t "$WORKER_PID" -D "$DUMP_DIR" --shell-job --ext-unix-sk -v4 --log-file dump.log; then
    CHECKPOINT_OK=true
  fi
fi

# Save CRIU logs regardless
if [[ -f "$DUMP_DIR/dump.log" ]]; then
  cp "$DUMP_DIR/dump.log" "$RESULTS_DIR/criu-dump.log"
fi

if [[ "$CHECKPOINT_OK" != "true" ]]; then
  fail "All CRIU checkpoint approaches failed."
  log "CRIU dump log (last 50 lines):"
  tail -50 "$DUMP_DIR/dump.log" 2>/dev/null || true
  log "dmesg (last 20 lines):"
  sudo dmesg | tail -20 2>/dev/null || true

  CRIU_ERROR="Checkpoint failed. See criu-dump.log for details."
  record_result "$TEST_NAME" "FAIL" "$CRIU_ERROR"
  append_summary "| CRIU process | :x: FAIL | Checkpoint failed — likely kernel/seccomp restrictions on GH runners |"
  exit 1
fi

ok "Checkpoint succeeded!"

# ── Step 5: Verify process is stopped ────────────────────────────────
log "Verifying process $WORKER_PID is stopped …"
sleep 1
if kill -0 "$WORKER_PID" 2>/dev/null; then
  warn "Process still alive after dump; it should have been killed by CRIU. Killing …"
  kill "$WORKER_PID" 2>/dev/null || true
fi

CHECKPOINT_VALUE=$(cat "$COUNTER_FILE" 2>/dev/null || echo "unknown")
log "Counter value at checkpoint: $CHECKPOINT_VALUE"

# ── Step 6: Attempt CRIU restore ─────────────────────────────────────
section "Attempting CRIU Restore"

RESTORE_OK=false

try_restore() {
  local desc="$1"; shift
  log "Trying: $desc"
  log "Command: sudo criu restore $*"
  if sudo criu restore "$@" 2>&1 | tee "$RESULTS_DIR/criu-restore-attempt.log"; then
    return 0
  else
    local rc=$?
    warn "Failed (exit $rc): $desc"
    return $rc
  fi
}

if try_restore "Standard restore" \
    -D "$DUMP_DIR" --shell-job -v4 --log-file restore.log -d; then
  RESTORE_OK=true
fi

if [[ "$RESTORE_OK" != "true" ]]; then
  if try_restore "Restore with --tcp-established" \
      -D "$DUMP_DIR" --shell-job --tcp-established -v4 --log-file restore.log -d; then
    RESTORE_OK=true
  fi
fi

# Save restore log
if [[ -f "$DUMP_DIR/restore.log" ]]; then
  cp "$DUMP_DIR/restore.log" "$RESULTS_DIR/criu-restore.log"
fi

if [[ "$RESTORE_OK" != "true" ]]; then
  fail "CRIU restore failed."
  log "CRIU restore log (last 50 lines):"
  tail -50 "$DUMP_DIR/restore.log" 2>/dev/null || true

  record_result "$TEST_NAME" "FAIL" "Checkpoint succeeded but restore failed."
  append_summary "| CRIU process | :x: FAIL | Checkpoint OK but restore failed |"
  exit 1
fi

ok "Restore succeeded!"

# ── Step 7: Verify state continuity ──────────────────────────────────
section "Verifying state continuity"
sleep 3

POST_VALUE=$(cat "$COUNTER_FILE" 2>/dev/null || echo "unknown")
log "Counter value after restore: $POST_VALUE"

if [[ "$POST_VALUE" != "unknown" && "$CHECKPOINT_VALUE" != "unknown" ]]; then
  if (( POST_VALUE > CHECKPOINT_VALUE )); then
    ok "State continuity verified: counter advanced from $CHECKPOINT_VALUE to $POST_VALUE"
    record_result "$TEST_NAME" "PASS" "Counter went from $CHECKPOINT_VALUE to $POST_VALUE after restore."
    append_summary "| CRIU process | :white_check_mark: PASS | Counter $CHECKPOINT_VALUE -> $POST_VALUE |"
  else
    fail "Counter did not advance: was $CHECKPOINT_VALUE, now $POST_VALUE"
    record_result "$TEST_NAME" "FAIL" "Counter did not advance after restore ($CHECKPOINT_VALUE -> $POST_VALUE)."
    append_summary "| CRIU process | :x: FAIL | Counter stalled ($CHECKPOINT_VALUE -> $POST_VALUE) |"
    exit 1
  fi
else
  warn "Could not verify counter values (checkpoint=$CHECKPOINT_VALUE, post=$POST_VALUE)"
  record_result "$TEST_NAME" "FAIL" "Could not read counter file after restore."
  append_summary "| CRIU process | :x: FAIL | Could not verify state after restore |"
  exit 1
fi

# Kill the restored process
kill "$WORKER_PID" 2>/dev/null || true
