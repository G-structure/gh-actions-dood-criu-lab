#!/usr/bin/env bash
# install_criu.sh — Install CRIU on Ubuntu (handles 22.04 and 24.04+)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

section "Installing CRIU"

# Check if already installed
if command -v criu &>/dev/null; then
  log "CRIU already installed: $(criu --version 2>&1 | head -1)"
  exit 0
fi

# Detect Ubuntu version
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || grep VERSION_ID /etc/os-release | cut -d'"' -f2)
log "Detected Ubuntu version: $UBUNTU_VERSION"

install_from_apt() {
  log "Trying direct apt install …"
  retry 3 sudo apt-get update -qq
  sudo apt-get install -y criu 2>&1
}

install_from_ppa() {
  log "Adding CRIU PPA (ppa:criu/ppa) …"
  retry 3 sudo apt-get update -qq
  retry 3 sudo apt-get install -y software-properties-common
  sudo add-apt-repository -y ppa:criu/ppa
  retry 3 sudo apt-get update -qq
  retry 3 sudo apt-get install -y criu
}

# Always prefer PPA for latest CRIU (3.16.1 from 22.04 repos segfaults with newer kernels)
log "Installing CRIU from PPA (recommended for all Ubuntu versions) …"
install_from_ppa || install_from_apt

if command -v criu &>/dev/null; then
  ok "CRIU installed: $(criu --version 2>&1 | head -1)"
else
  fail "Failed to install CRIU."
  exit 1
fi
