#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# check-dependencies.sh
#
# Ensures all required CLI tools for the platform bootstrap are installed.
# Fails fast if any dependency (minikube, kubectl, helm, vault, jq, etc.)
# is missing to prevent runtime errors during setup.
# -----------------------------------------------------------------------------

echo "🔍 Checking required dependencies..."

missing=()

check() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "   ✅ $1"
  else
    echo "   ❌ $1"
    missing+=("$1")
  fi
}

# dependencies in start-minikube-clusters.sh
check minikube
check kubectl
check virsh
# dependencies in install-platform-charts.sh
check helm
check yq
check curl
check base64
# dependencies in setup-environment.sh
check jq
check vault
check pass
check ss
check certutil
# dependencies in setup-keycloak-master-realm.sh
check kcadm.sh

# -----------------------------------------------------------------------------
# Result
# -----------------------------------------------------------------------------

if [ ${#missing[@]} -ne 0 ]; then
  echo ""
  echo "❌ Missing required tools:"
  for cmd in "${missing[@]}"; do
    echo "   - $cmd"
  done

  echo ""
  echo "Install them first, then re-run bootstrap."
  exit 1
fi

echo "✅ All dependencies installed"
