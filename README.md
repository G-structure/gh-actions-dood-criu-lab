# gh-actions-dood-criu-lab

[![DOOD & CRIU Lab](https://github.com/G-structure/gh-actions-dood-criu-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/G-structure/gh-actions-dood-criu-lab/actions/workflows/ci.yml)

Testing Docker-out-of-Docker (DOOD) and CRIU checkpoint/restore on GitHub-hosted Actions runners.

## Results on GitHub-Hosted Runners

| Test | ubuntu-latest (24.04) | ubuntu-22.04 | Notes |
|------|:---:|:---:|-------|
| **DOOD** | PASS | PASS | Works out of the box |
| **CRIU process** | PASS | PASS | Requires CRIU 4.2 from PPA (3.16.1 segfaults on 6.8 kernel) |
| **Docker checkpoint** | PASS | PASS | Requires `--net=host` + experimental + content blob purge |

All three capabilities work on GitHub-hosted runners with the right configuration.

## What We Test

### 1. Docker-out-of-Docker (DOOD)

DOOD mounts the host's Docker socket (`/var/run/docker.sock`) into a container so the Docker CLI inside talks to the **host daemon**. Containers created from inside are "sibling" containers visible on the host.

**Test**: Run a `docker:cli` container with the socket mounted, create a child container from inside, verify it's visible on the host.

**Result**: Works on all tested runners with no special configuration.

### 2. CRIU Process Checkpoint/Restore

[CRIU](https://criu.org/) (Checkpoint/Restore In Userspace) freezes a running Linux process, saves its state to disk, and restores it later — resuming exactly where it left off.

**Test**: Install CRIU, start a counter process, checkpoint it, kill it, restore it, verify the counter resumes from where it was.

**Result**: Works on both runners. Key finding: **must use CRIU 4.2 from the PPA** (`ppa:criu/ppa`). The stock Ubuntu 22.04 package (CRIU 3.16.1) segfaults during restore on the Azure 6.8 kernel. Ubuntu 24.04 doesn't ship CRIU at all.

```
# Example output (ubuntu-latest):
[PASS] State continuity verified: counter advanced from 5 to 9
```

### 3. Docker Checkpoint/Restore

Docker has experimental support for `docker checkpoint create` / `docker start --checkpoint`, using CRIU under the hood to snapshot a running container.

**Test**: Enable Docker experimental, install CRIU, start a container with a counter, checkpoint it, restore, verify state continuity.

**Result**: Works, but requires specific configuration:

1. **Docker experimental mode** must be enabled (`/etc/docker/daemon.json` → `{"experimental": true}` + restart)
2. **`--net=host`** is required — default bridge networking fails with `bind-mount /proc/0/ns/net -> .../netns/<ID>: no such file or directory` (tracked as [containerd#12141](https://github.com/containerd/containerd/issues/12141))
3. **Containerd content blob purge** before restore to work around [moby#42900](https://github.com/moby/moby/issues/42900) (`"content sha256:... already exists"`)
4. `--security-opt seccomp=unconfined --security-opt apparmor=unconfined` recommended

```
# Example output (ubuntu-22.04):
[PASS] State continuity verified: counter 5 -> 10 (net=host + seccomp=unconfined)
```

## Key Findings & Workarounds

### CRIU on Ubuntu 24.04
The `criu` package was removed from Ubuntu 24.04 repos due to build issues ([Bug #2066148](https://bugs.launchpad.net/ubuntu/+source/criu/+bug/2066148)). Install from the official PPA:
```bash
sudo apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:criu/ppa
sudo apt-get update && sudo apt-get install -y criu
```

### Docker Checkpoint Restore Errors
Two known bugs affect Docker checkpoint/restore on containerd v2:

- **moby/moby#42900**: `"content sha256:... already exists"` — The `writeContent` function in containerd doesn't handle duplicate content blobs. Workaround: purge blobs with `sudo ctr -n moby content rm <digest>` before restoring.
- **containerd#12141**: Network namespace bind-mount fails on default bridge networking. Workaround: use `--net=host`.

## Running Locally

```bash
git clone https://github.com/G-structure/gh-actions-dood-criu-lab.git
cd gh-actions-dood-criu-lab

# Run individual tests (CRIU/Docker tests need sudo + Linux)
export RESULTS_DIR=./results
mkdir -p "$RESULTS_DIR"

bash scripts/test_dood.sh
sudo bash scripts/test_criu_process.sh
sudo bash scripts/test_docker_checkpoint.sh
```

## Project Structure

```
.github/workflows/ci.yml        # GitHub Actions workflow (matrix: ubuntu-latest, ubuntu-22.04)
scripts/
  lib.sh                        # Shared helpers (logging, retry, cleanup, result recording)
  install_criu.sh               # CRIU installer (handles PPA for 22.04/24.04)
  test_dood.sh                  # Docker-out-of-Docker test
  test_criu_process.sh          # CRIU process checkpoint/restore test
  test_docker_checkpoint.sh     # Docker checkpoint/restore test
README.md
```

## License

MIT
