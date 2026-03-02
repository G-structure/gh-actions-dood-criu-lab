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

# On 24.04+ the package is missing from default repos; use PPA
case "$UBUNTU_VERSION" in
  22.04*)
    install_from_apt || install_from_ppa
    ;;
  24.04*|25.*|26.*)
    log "Ubuntu $UBUNTU_VERSION — criu not in default repos, using PPA."
    install_from_ppa
    ;;
  *)
    # Try direct first, fall back to PPA
    install_from_apt || install_from_ppa
    ;;
esac

if command -v criu &>/dev/null; then
  ok "CRIU installed: $(criu --version 2>&1 | head -1)"
else
  fail "Failed to install CRIU."
  exit 1
fi
