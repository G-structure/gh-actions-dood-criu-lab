#!/usr/bin/env bash
# test_criu_process.sh — CRIU direct process checkpoint/restore (same worker).
#
# Starts a counter process, checkpoints it with `criu dump`, verifies the
# process was killed, restores it with `criu restore`, and confirms the
# counter resumes from the checkpoint value (not from 0).
#
# Tries progressively more permissive CRIU flags if standard dump fails.
# Requires CRIU 4.2 from PPA — see install_criu.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TEST_NAME="criu_process"
LOG_FILE="$RESULTS_DIR/${TEST_NAME}.log"
exec > >(tee "$LOG_FILE") 2>&1

section "CRIU Direct Process Checkpoint/Restore Test"
print_env

DUMP_DIR="$(pwd)/results/criu-dump"
COUNTER_FILE="/tmp/criu-counter-$$"
WORKER_PIDFILE="/tmp/criu-worker-$$.pid"
sudo rm -rf "$DUMP_DIR"
mkdir -p "$DUMP_DIR"
add_cleanup "rm -f $COUNTER_FILE $WORKER_PIDFILE /tmp/criu_counter_worker.sh /tmp/criu-worker-output.log"

# ── Step 1: Install CRIU ─────────────────────────────────────────────
bash "$SCRIPT_DIR/install_criu.sh"

# ── Step 2: CRIU pre-flight check ────────────────────────────────────
section "CRIU Check"
log "Running 'sudo criu check' …"
if sudo criu check 2>&1 | tee "$RESULTS_DIR/criu-check.log"; then
  ok "criu check passed."
else
  warn "criu check reported issues (may still work for simple cases)."
fi

# Capture kernel config hints
log "Checking kernel config for CRIU support …"
if [[ -f /boot/config-$(uname -r) ]]; then
  grep -i checkpoint /boot/config-"$(uname -r)" 2>/dev/null | head -20 || true
fi
log "Loaded modules (checkpoint-related):"
lsmod 2>/dev/null | grep -iE 'criu|checkpoint|netns' || log "(none found)"

# ── Step 3: Start demo process ───────────────────────────────────────
section "Starting counter process"

# Simple shell loop that writes a counter to a file every second.
# setsid creates a clean session for the process tree.
cat > /tmp/criu_counter_worker.sh <<'WORKER'
#!/bin/bash
counter=0
OUTFILE="$1"
while true; do
  echo "$counter" > "$OUTFILE"
  counter=$((counter + 1))
  sleep 1
done
WORKER
chmod +x /tmp/criu_counter_worker.sh

# Launch in background with setsid. For same-worker tests setsid is fine;
# the cross-worker scripts avoid setsid to prevent PID mismatch issues.
setsid /tmp/criu_counter_worker.sh "$COUNTER_FILE" </dev/null &>/tmp/criu-worker-output.log &
WORKER_PID=$!
echo "$WORKER_PID" > "$WORKER_PIDFILE"
add_cleanup "sudo kill $WORKER_PID 2>/dev/null || true"

log "Worker started with PID $WORKER_PID"
sleep 5  # Let counter run to at least 4

PRE_VALUE=$(cat "$COUNTER_FILE" 2>/dev/null || echo "unknown")
log "Counter value before checkpoint: $PRE_VALUE"

if [[ "$PRE_VALUE" == "unknown" ]]; then
  fail "Counter file not created. Worker may not have started."
  record_result "$TEST_NAME" "FAIL" "Counter process did not start properly."
  append_summary "| CRIU process | :x: FAIL | Counter process failed to start |"
  exit 1
fi

# ── Step 4: Attempt CRIU checkpoint ──────────────────────────────────
section "Attempting CRIU Checkpoint"

# Try multiple approaches; CRIU dump is expected to kill the process on success
try_checkpoint() {
  local desc="$1"; shift
  log "Trying: $desc"
  log "Command: sudo criu dump $*"
  # Capture exit code explicitly; don't let set -e kill us
  local rc=0
  sudo criu dump "$@" 2>&1 | tee "$RESULTS_DIR/criu-dump-attempt.log" || rc=$?
  if [[ $rc -eq 0 ]]; then
    return 0
  else
    warn "Failed (exit $rc): $desc"
    cat "$RESULTS_DIR/criu-dump-attempt.log" >> "$RESULTS_DIR/criu-dump-all-attempts.log" 2>/dev/null || true
    return $rc
  fi
}

CHECKPOINT_OK=false

# Approach 1: Standard tree dump with --shell-job
if try_checkpoint "Standard tree dump (--shell-job)" \
    -t "$WORKER_PID" -D "$DUMP_DIR" --shell-job -v4 --log-file dump.log; then
  CHECKPOINT_OK=true
fi

# Approach 2: With --ext-unix-sk (for external unix sockets)
if [[ "$CHECKPOINT_OK" != "true" ]]; then
  sudo rm -rf "$DUMP_DIR"/*
  if try_checkpoint "With --ext-unix-sk" \
      -t "$WORKER_PID" -D "$DUMP_DIR" --shell-job --ext-unix-sk -v4 --log-file dump.log; then
    CHECKPOINT_OK=true
  fi
fi

# Approach 3: Without --shell-job
if [[ "$CHECKPOINT_OK" != "true" ]]; then
  sudo rm -rf "$DUMP_DIR"/*
  if try_checkpoint "Without --shell-job" \
      -t "$WORKER_PID" -D "$DUMP_DIR" -v4 --log-file dump.log; then
    CHECKPOINT_OK=true
  fi
fi

# Approach 4: With --tcp-established --file-locks --ext-unix-sk
if [[ "$CHECKPOINT_OK" != "true" ]]; then
  sudo rm -rf "$DUMP_DIR"/*
  if try_checkpoint "Kitchen sink flags" \
      -t "$WORKER_PID" -D "$DUMP_DIR" --shell-job --tcp-established --file-locks --ext-unix-sk -v4 --log-file dump.log; then
    CHECKPOINT_OK=true
  fi
fi

# Save CRIU dump logs regardless (use sudo since CRIU creates root-owned files)
if sudo test -f "$DUMP_DIR/dump.log"; then
  sudo cp "$DUMP_DIR/dump.log" "$RESULTS_DIR/criu-dump.log"
  sudo chmod 644 "$RESULTS_DIR/criu-dump.log"
fi

if [[ "$CHECKPOINT_OK" != "true" ]]; then
  fail "All CRIU checkpoint approaches failed."
  log "CRIU dump log (last 60 lines):"
  sudo cat "$DUMP_DIR/dump.log" 2>/dev/null | tail -60 || true
  log "dmesg (last 30 lines):"
  sudo dmesg | tail -30 2>/dev/null || true

  CRIU_ERROR="Checkpoint failed. See criu-dump.log for details."
  record_result "$TEST_NAME" "FAIL" "$CRIU_ERROR"
  append_summary "| CRIU process | :x: FAIL | Checkpoint failed — see logs for kernel/seccomp constraints |"
  exit 1
fi

ok "Checkpoint succeeded!"

# Fix permissions on dump dir so artifacts can be uploaded
sudo chmod -R a+rX "$DUMP_DIR" 2>/dev/null || true

# ── Step 5: Verify process is stopped ────────────────────────────────
log "Verifying process $WORKER_PID is stopped …"
sleep 1
if kill -0 "$WORKER_PID" 2>/dev/null; then
  warn "Process still alive after dump; it should have been killed by CRIU. Killing …"
  sudo kill "$WORKER_PID" 2>/dev/null || true
  sleep 1
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
  local rc=0
  sudo criu restore "$@" 2>&1 | tee "$RESULTS_DIR/criu-restore-attempt.log" || rc=$?
  if [[ $rc -eq 0 ]]; then
    return 0
  else
    warn "Failed (exit $rc): $desc"
    return $rc
  fi
}

# -d = detach (daemonize the restored process)
if try_restore "Standard restore" \
    -D "$DUMP_DIR" --shell-job -v4 --log-file restore.log -d; then
  RESTORE_OK=true
fi

if [[ "$RESTORE_OK" != "true" ]]; then
  if try_restore "Restore with --ext-unix-sk" \
      -D "$DUMP_DIR" --shell-job --ext-unix-sk -v4 --log-file restore.log -d; then
    RESTORE_OK=true
  fi
fi

if [[ "$RESTORE_OK" != "true" ]]; then
  if try_restore "Restore with --tcp-established" \
      -D "$DUMP_DIR" --shell-job --tcp-established -v4 --log-file restore.log -d; then
    RESTORE_OK=true
  fi
fi

# Save restore log
if sudo test -f "$DUMP_DIR/restore.log"; then
  sudo cp "$DUMP_DIR/restore.log" "$RESULTS_DIR/criu-restore.log"
  sudo chmod 644 "$RESULTS_DIR/criu-restore.log"
fi

if [[ "$RESTORE_OK" != "true" ]]; then
  fail "CRIU restore failed."
  log "CRIU restore log (last 60 lines):"
  sudo cat "$DUMP_DIR/restore.log" 2>/dev/null | tail -60 || true
  log "dmesg (last 20 lines):"
  sudo dmesg | tail -20 2>/dev/null || true

  record_result "$TEST_NAME" "FAIL" "Checkpoint succeeded but restore failed."
  append_summary "| CRIU process | :x: FAIL | Checkpoint OK but restore failed |"
  exit 1
fi

ok "Restore succeeded!"

# ── Step 7: Verify state continuity ──────────────────────────────────
section "Verifying state continuity"
sleep 4

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
sudo kill "$WORKER_PID" 2>/dev/null || true
# Fix permissions for artifact upload
sudo chmod -R a+rX "$DUMP_DIR" 2>/dev/null || true
