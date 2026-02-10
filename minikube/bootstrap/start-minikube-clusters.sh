#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Start Minikube clusters
# Idempotent: safe to re-run, skips already running profiles
# Just edit the CLUSTERS map to add/remove environments
# -----------------------------------------------------------------------------

K8S_VERSION="v1.35.0"

# profile → "cpu memory"
declare -A CLUSTERS=(
  [minikube-mgmt]="4 4096"
  [minikube-dev]="2 2048"
)

start_cluster () {
  local profile=$1
  local cpus=$2
  local memory=$3

  echo "🚀 Starting $profile ($cpus CPU / ${memory}MB)"

  if minikube status -p "$profile" >/dev/null 2>&1; then
    echo "   ℹ️ already running — skipping"
    return
  fi

  minikube start -p "$profile" \
    --driver=docker \
    --kubernetes-version="$K8S_VERSION" \
    --cpus="$cpus" \
    --memory="$memory"
}

# -----------------------------------------------------------------------------
# Launch clusters
# -----------------------------------------------------------------------------

for profile in "${!CLUSTERS[@]}"; do
  read -r cpu mem <<< "${CLUSTERS[$profile]}"
  start_cluster "$profile" "$cpu" "$mem"
done

echo ""
echo "✅ All clusters ready!"

# Switch to mgmt only if it exists
if minikube status -p minikube-mgmt >/dev/null 2>&1; then
  kubectl config use-context minikube-mgmt
fi

minikube profile list
