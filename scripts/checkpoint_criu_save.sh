#!/usr/bin/env bash
# checkpoint_criu_save.sh — CRIU cross-worker migration: SAVE phase.
#
# Starts a stateful counter process, checkpoints it with CRIU, and
# packages everything the restore side needs into a dump directory:
#   - CRIU dump images (core-*.img, pages-*.img, pstree.img, etc.)
#   - The worker script (must be placed at the same path on restore)
#   - Open files with exact byte sizes (CRIU validates sizes on restore)
#   - Migration metadata JSON (counter value, PIDs, hostname, kernel)
#
# The dump directory is uploaded as a GitHub Actions artifact by the
# workflow, then downloaded on a different runner for restore.
#
# Important: the process is run directly (no setsid) so that $! captures
# the actual PID that CRIU dumps. Using setsid causes a fork, making $!
# point to the wrong PID — the dump then contains different PIDs than
# metadata reports, and the restore side kills the wrong processes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TEST_NAME="criu_cross_save"
LOG_FILE="$RESULTS_DIR/${TEST_NAME}.log"
exec > >(tee "$LOG_FILE") 2>&1

section "CRIU Cross-Worker: SAVE Phase"
print_env

DUMP_DIR="$RESULTS_DIR/criu-migration-dump"
COUNTER_FILE="/tmp/criu-migrate-counter"
WORKER_SCRIPT="/tmp/criu_migrator.sh"
sudo rm -rf "$DUMP_DIR"
mkdir -p "$DUMP_DIR"
add_cleanup "rm -f $COUNTER_FILE /tmp/criu-migrator-output.log"

# ── Install CRIU ─────────────────────────────────────────────────────
bash "$SCRIPT_DIR/install_criu.sh"

# ── Create the worker script ────────────────────────────────────────
# Must exist at the same absolute path on the restore side because CRIU
# records the path of the executable in the dump images.
section "Creating worker process"
cat > "$WORKER_SCRIPT" <<'WORKER'
#!/bin/bash
# Stateful counter — writes to a well-known file.
# On restore, it picks up exactly where it left off.
OUTFILE="/tmp/criu-migrate-counter"
HOSTNAME_AT_START=$(hostname)
counter=0
# If counter file already exists (from a previous run), start from there
if [[ -f "$OUTFILE" ]]; then
  counter=$(cat "$OUTFILE")
  counter=$((counter + 1))
fi
while true; do
  echo "$counter" > "$OUTFILE"
  echo "counter=$counter host=$HOSTNAME_AT_START pid=$$"
  counter=$((counter + 1))
  sleep 1
done
WORKER
chmod +x "$WORKER_SCRIPT"

# ── Start the process ────────────────────────────────────────────────
section "Starting counter process"
# Run directly (no setsid) so $! matches the actual PID CRIU will dump
"$WORKER_SCRIPT" </dev/null &>/tmp/criu-migrator-output.log &
WORKER_PID=$!
add_cleanup "sudo kill $WORKER_PID 2>/dev/null || true"

log "Worker PID: $WORKER_PID"
log "Letting counter run for 8 seconds …"
sleep 8

PRE_VALUE=$(cat "$COUNTER_FILE" 2>/dev/null || echo "unknown")
log "Counter value before checkpoint: $PRE_VALUE"

if [[ "$PRE_VALUE" == "unknown" || "$PRE_VALUE" -lt 5 ]]; then
  fail "Counter didn't advance enough (value=$PRE_VALUE). Cannot checkpoint."
  record_result "$TEST_NAME" "FAIL" "Counter process failed."
  exit 1
fi

# ── Checkpoint ───────────────────────────────────────────────────────
section "Checkpointing process"
log "Running: sudo criu dump -t $WORKER_PID -D $DUMP_DIR --shell-job -v4 --log-file dump.log"

if sudo criu dump -t "$WORKER_PID" -D "$DUMP_DIR" --shell-job -v4 --log-file dump.log 2>&1; then
  ok "Checkpoint succeeded!"
else
  fail "Checkpoint failed."
  sudo cat "$DUMP_DIR/dump.log" 2>/dev/null | tail -30 || true
  record_result "$TEST_NAME" "FAIL" "CRIU dump failed."
  exit 1
fi

# ── Save metadata for the restore side ───────────────────────────────
CHECKPOINT_VALUE=$(cat "$COUNTER_FILE" 2>/dev/null || echo "unknown")
log "Counter value at checkpoint: $CHECKPOINT_VALUE"

# Extract actual PIDs from the dump (core-<PID>.img files)
DUMP_PIDS=$(ls "$DUMP_DIR"/core-*.img 2>/dev/null | sed 's/.*core-//; s/\.img//' | sort -n | paste -sd, -)
log "PIDs in dump: $DUMP_PIDS"

cat > "$DUMP_DIR/migration-meta.json" <<EOF
{
  "counter_at_checkpoint": $CHECKPOINT_VALUE,
  "worker_pid": $WORKER_PID,
  "dump_pids": [$DUMP_PIDS],
  "worker_script": "$WORKER_SCRIPT",
  "counter_file": "$COUNTER_FILE",
  "source_hostname": "$(hostname)",
  "source_kernel": "$(uname -r)",
  "source_os": "$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')",
  "criu_version": "$(criu --version 2>&1 | head -1)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Include the worker script so the restore side can place it at the expected path
cp "$WORKER_SCRIPT" "$DUMP_DIR/criu_migrator.sh"

# CRIU validates that files the process had open still exist at their original
# paths AND have the exact same byte size. If the restore side just `touch`es
# empty files, CRIU fails with "File ... has bad size 0 (expect N)".
# Save the actual file contents so the restore side can copy them back.
cp /tmp/criu-migrator-output.log "$DUMP_DIR/saved-output.log" 2>/dev/null || true
cp "$COUNTER_FILE" "$DUMP_DIR/saved-counter" 2>/dev/null || true
log "Saved open files for restore side (CRIU validates file sizes)"

# Fix permissions so artifact upload can read everything
sudo chmod -R a+rX "$DUMP_DIR"

# ── Summary ──────────────────────────────────────────────────────────
log "Dump directory contents:"
ls -la "$DUMP_DIR"
log "Dump directory size: $(du -sh "$DUMP_DIR" | cut -f1)"

log "Migration metadata:"
cat "$DUMP_DIR/migration-meta.json"

ok "SAVE phase complete. Counter was at $CHECKPOINT_VALUE. Ready for cross-worker restore."
record_result "$TEST_NAME" "PASS" "Checkpoint saved. Counter at $CHECKPOINT_VALUE."
append_summary "| CRIU cross-worker SAVE | :white_check_mark: PASS | Counter at $CHECKPOINT_VALUE, dump ready for upload |"
