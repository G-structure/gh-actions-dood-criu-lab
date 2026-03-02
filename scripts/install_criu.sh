#!/usr/bin/env bash
# install_criu.sh — Install CRIU 4.2 from the official PPA (ppa:criu/ppa).
#
# Always prefers the PPA over distro packages because:
#   - Ubuntu 24.04 removed criu from repos entirely (LP Bug #2066148)
#   - Ubuntu 22.04 ships CRIU 3.16.1, which segfaults on Azure's 6.8 kernel
# Falls back to direct `apt install` if the PPA fails.
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

# PPA provides CRIU 4.2; stock 22.04 has 3.16.1 which segfaults on Azure 6.8 kernel
log "Installing CRIU from PPA (recommended for all Ubuntu versions) …"
install_from_ppa || install_from_apt

if command -v criu &>/dev/null; then
  ok "CRIU installed: $(criu --version 2>&1 | head -1)"
else
  fail "Failed to install CRIU."
  exit 1
fi
