# gh-actions-dood-criu-lab

[![DOOD & CRIU Lab](https://github.com/G-structure/gh-actions-dood-criu-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/G-structure/gh-actions-dood-criu-lab/actions/workflows/ci.yml)

Testing Docker-out-of-Docker (DOOD) and CRIU checkpoint/restore on GitHub-hosted Actions runners.

## What We Test

### 1. Docker-out-of-Docker (DOOD)

DOOD mounts the host's Docker socket (`/var/run/docker.sock`) into a container so the Docker CLI inside the container talks to the **host daemon**. Containers created from inside are "sibling" containers — they appear alongside the caller on the host, not nested inside it.

**Test**: We run a `docker:cli` container with the socket mounted, create a child container from inside, then verify on the host that the child is visible.

### 2. CRIU Process Checkpoint/Restore

[CRIU](https://criu.org/) (Checkpoint/Restore In Userspace) can freeze a running Linux process, save its state to disk, and restore it later — resuming exactly where it left off.

**Test**: We install CRIU on the runner, start a counter process, checkpoint it, kill it, restore it, and verify the counter resumes from where it was (not from zero).

### 3. Docker Checkpoint/Restore

Docker has experimental support for `docker checkpoint create` / `docker start --checkpoint`, which uses CRIU under the hood to snapshot a running container and later resume it.

**Test**: We enable Docker experimental features, install CRIU, start a container with a counter, create a checkpoint, and restore from it — verifying state continuity.

## Results on GitHub-Hosted Runners

> Results will be updated after CI runs complete. See the [Actions tab](https://github.com/G-structure/gh-actions-dood-criu-lab/actions) for the latest.

| Test | ubuntu-latest | ubuntu-22.04 | Notes |
|------|:---:|:---:|-------|
| DOOD | TBD | TBD | Expected to work |
| CRIU process | TBD | TBD | May be blocked by kernel config |
| Docker checkpoint | TBD | TBD | Requires experimental + CRIU |

## Running Locally

```bash
# Clone
git clone https://github.com/G-structure/gh-actions-dood-criu-lab.git
cd gh-actions-dood-criu-lab

# Run individual tests
export RESULTS_DIR=./results
mkdir -p "$RESULTS_DIR"
bash scripts/test_dood.sh
sudo bash scripts/test_criu_process.sh
sudo bash scripts/test_docker_checkpoint.sh

# Or run the full CI locally with act (https://github.com/nektos/act)
act -j test
```

CRIU and Docker checkpoint tests require `sudo` and a Linux kernel with checkpoint support.

## Project Structure

```
.github/workflows/ci.yml    # GitHub Actions workflow
scripts/
  lib.sh                    # Shared helpers (logging, retry, results)
  test_dood.sh              # DOOD test
  test_criu_process.sh      # CRIU process checkpoint/restore
  test_docker_checkpoint.sh # Docker checkpoint/restore
README.md
```

## License

MIT
