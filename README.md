# gh-actions-dood-criu-lab

[![DOOD & CRIU Lab](https://github.com/G-structure/gh-actions-dood-criu-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/G-structure/gh-actions-dood-criu-lab/actions/workflows/ci.yml)
[![Cross-Worker Migration](https://github.com/G-structure/gh-actions-dood-criu-lab/actions/workflows/cross-worker.yml/badge.svg)](https://github.com/G-structure/gh-actions-dood-criu-lab/actions/workflows/cross-worker.yml)

Testing Docker-out-of-Docker (DOOD), CRIU checkpoint/restore, and **cross-worker process migration** on GitHub-hosted Actions runners.

## Results

### Same-Worker Tests (`ci.yml`)

| Test | ubuntu-latest (24.04) | ubuntu-22.04 | Notes |
|------|:---:|:---:|-------|
| **DOOD** | PASS | PASS | Works out of the box |
| **CRIU process** | PASS | PASS | Requires CRIU 4.2 from PPA |
| **Docker checkpoint** | PASS | PASS | Requires `--net=host` + experimental + content blob purge |

### Cross-Worker Migration Tests (`cross-worker.yml`)

Checkpoint a process on one GitHub Actions runner, upload the dump as an artifact, download it on a **different** runner, and restore the process there — verifying state continuity.

| Test | Result | Details |
|------|:---:|-------|
| **CRIU cross-worker** | PASS | Counter 8 → 13 across different VMs |
| **Docker cross-worker** | PASS | Counter 8 → 13 via raw checkpoint data import |

## What We Test

### 1. Docker-out-of-Docker (DOOD)

DOOD mounts the host's Docker socket (`/var/run/docker.sock`) into a container so the Docker CLI inside talks to the **host daemon**. Containers created from inside are "sibling" containers visible on the host.

**Test**: Run a `docker:cli` container with the socket mounted, create a child container from inside, verify it's visible on the host.

**Result**: Works on all tested runners with no special configuration.

### 2. CRIU Process Checkpoint/Restore

[CRIU](https://criu.org/) (Checkpoint/Restore In Userspace) freezes a running Linux process, saves its state to disk, and restores it later — resuming exactly where it left off.

**Test**: Install CRIU, start a counter process, checkpoint it, kill it, restore it, verify the counter resumes from where it was.

**Result**: Works on both runners. Key finding: **must use CRIU 4.2 from the PPA** (`ppa:criu/ppa`). The stock Ubuntu 22.04 package (CRIU 3.16.1) segfaults during restore on the Azure 6.8 kernel. Ubuntu 24.04 doesn't ship CRIU at all.

### 3. Docker Checkpoint/Restore

Docker has experimental support for `docker checkpoint create` / `docker start --checkpoint`, using CRIU under the hood to snapshot a running container.

**Test**: Enable Docker experimental, install CRIU, start a container with a counter, checkpoint it, restore, verify state continuity.

**Result**: Works, but requires specific configuration:

1. **Docker experimental mode** — `{"experimental": true}` in `/etc/docker/daemon.json` + restart
2. **`--net=host`** — default bridge networking fails with netns bind-mount errors ([containerd#12141](https://github.com/containerd/containerd/issues/12141))
3. **Containerd content blob purge** before restore — workaround for [moby#42900](https://github.com/moby/moby/issues/42900)
4. `--security-opt seccomp=unconfined --security-opt apparmor=unconfined` recommended

### 4. CRIU Cross-Worker Migration

Checkpoint a bare process with CRIU on Worker A, upload the dump directory as a GitHub Actions artifact, download on Worker B, and restore. The process resumes on a completely different VM.

**Save side** (`checkpoint_criu_save.sh`):
- Starts a counter process, lets it run, checkpoints it with `criu dump`
- Saves the dump images, the worker script, open files (output log + counter), and metadata JSON
- Uploads as artifact `criu-checkpoint-dump`

**Restore side** (`checkpoint_criu_restore.sh`):
- Downloads the dump artifact, installs the worker script at the original path
- Restores open files with exact byte sizes (CRIU validates file sizes on restore)
- Kills any process occupying the dump's PIDs, then runs `criu restore`
- Falls back through progressively more permissive approaches if standard restore fails

**Key lessons learned**:
- **No `setsid`** — `setsid` forks, causing `$!` to capture the wrong PID. The dump PIDs then differ from the metadata, and the restore side kills the wrong processes.
- **Open file sizes must match** — CRIU validates that files the process had open exist at the same paths AND have the exact same byte size. An empty `touch` fails; the save side must copy the actual files.
- **PID conflicts** — extract PIDs from `core-*.img` filenames in the dump, not from metadata, and kill them on the restore side before attempting restore.

### 5. Docker Cross-Worker Migration

Checkpoint a Docker container on Worker A, export the checkpoint data, upload as artifact, import on Worker B, and restore.

**Save side** (`checkpoint_docker_save.sh`):
- Runs a container with `--net=host` + security opts, checkpoints it
- Exports checkpoint data via multiple methods: `ctr` checkpoint, raw checkpoint files from Docker storage, containerd content blobs, and container filesystem

**Restore side** (`checkpoint_docker_restore.sh`):
- Tries three restore methods in order:
  1. `ctr` containerd checkpoint restore (if checkpoint tar available)
  2. Raw checkpoint data import — copies checkpoint files into Docker's internal checkpoint directory, purges stale containerd blobs, restores via `docker start --checkpoint`
  3. Filesystem-only import (fallback — preserves file state but not process state)

**How it works**: Docker stores checkpoint data in `/var/lib/docker/containers/<id>/checkpoints/<name>/`. The save side copies these files out; the restore side creates a fresh container with the same image/config, stops it, injects the checkpoint data into the correct path, purges containerd content blobs (moby#42900 workaround), and starts with `--checkpoint`.

## Key Findings & Workarounds

### CRIU on Ubuntu 24.04
The `criu` package was removed from Ubuntu 24.04 repos ([Bug #2066148](https://bugs.launchpad.net/ubuntu/+source/criu/+bug/2066148)). Install from the official PPA:
```bash
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:criu/ppa
sudo apt-get update && sudo apt-get install -y criu
```
The PPA is also required on Ubuntu 22.04 — the stock CRIU 3.16.1 segfaults on Azure's 6.8 kernel.

### Docker Checkpoint Restore Errors
Two known bugs affect Docker checkpoint/restore on containerd v2:

- **moby/moby#42900**: `"content sha256:... already exists"` — containerd's `writeContent` doesn't handle duplicate blobs. Workaround: purge blobs with `sudo ctr -n moby content rm <digest>` before restoring.
- **containerd#12141**: Network namespace bind-mount fails on default bridge networking. Workaround: use `--net=host`.

### CRIU Cross-Worker File Validation
CRIU validates that files the checkpointed process had open exist at their original paths **with matching byte sizes**. When migrating across workers, the save side must include copies of all open files (stdout/stderr logs, counter files, etc.) so the restore side can place them before calling `criu restore`.

## Running Locally

```bash
git clone https://github.com/G-structure/gh-actions-dood-criu-lab.git
cd gh-actions-dood-criu-lab

export RESULTS_DIR=./results
mkdir -p "$RESULTS_DIR"
echo '[]' > "$RESULTS_DIR/results.json"

# Same-worker tests (CRIU/Docker tests need sudo + Linux)
bash scripts/test_dood.sh
sudo bash scripts/test_criu_process.sh
sudo bash scripts/test_docker_checkpoint.sh

# Cross-worker save/restore (run save first, then restore)
sudo bash scripts/checkpoint_criu_save.sh
sudo bash scripts/checkpoint_criu_restore.sh

sudo bash scripts/checkpoint_docker_save.sh
sudo bash scripts/checkpoint_docker_restore.sh
```

## Project Structure

```
.github/workflows/
  ci.yml                          # Same-worker tests (matrix: ubuntu-latest, ubuntu-22.04)
  cross-worker.yml                # Cross-worker migration (CRIU + Docker, save → restore)
scripts/
  lib.sh                          # Shared helpers: logging, retry, cleanup, result recording
  install_criu.sh                 # CRIU installer (always uses PPA for CRIU 4.2)
  test_dood.sh                    # Docker-out-of-Docker test
  test_criu_process.sh            # CRIU process checkpoint/restore (same worker)
  test_docker_checkpoint.sh       # Docker checkpoint/restore (same worker)
  checkpoint_criu_save.sh         # CRIU cross-worker: checkpoint + export dump
  checkpoint_criu_restore.sh      # CRIU cross-worker: import dump + restore
  checkpoint_docker_save.sh       # Docker cross-worker: checkpoint + export
  checkpoint_docker_restore.sh    # Docker cross-worker: import + restore
README.md
```

## License

MIT
