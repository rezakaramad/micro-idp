#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Start Minikube clusters
# Idempotent: safe to re-run, skips already running profiles
# Just edit the CLUSTERS map to add/remove environments
# -----------------------------------------------------------------------------

K8S_VERSION="v1.35.0"

MANAGEMENT_PROFILE="minikube-management"

# profile → "cpu memory"
declare -A CLUSTERS=(
  [$MANAGEMENT_PROFILE]="6 10240"
  [minikube-workload]="4 4096"
)

start_cluster () {
  local profile=$1
  local cpus=$2
  local memory=$3
  local service_cidr=$4

  echo "🚀 Starting $profile ($cpus CPU / ${memory}MB)"
  echo "   📡 Service CIDR: $service_cidr"

  if minikube status -p "$profile" >/dev/null 2>&1; then
    echo "   ℹ️ already running — skipping"
    return
  fi

  minikube start -p "$profile" \
    --driver=kvm2 \
    --network=kubepave \
    --kubernetes-version="$K8S_VERSION" \
    --cpus="$cpus" \
    --memory="$memory" \
    --service-cluster-ip-range="$service_cidr"
}

# -----------------------------------------------------------------------------
# Launch clusters
# -----------------------------------------------------------------------------

declare -A CLUSTERS=(
  [minikube-management]="4 8192 10.101.0.0/16"
  [minikube-workload]="4 8192 10.102.0.0/16"
)

for profile in "${!CLUSTERS[@]}"; do
  read -r cpu mem service_cidr <<< "${CLUSTERS[$profile]}"
  start_cluster "$profile" "$cpu" "$mem" "$service_cidr"
done

echo ""
echo "✅ All clusters ready!"

# Switch to mgmt only if it exists
if minikube status -p $MANAGEMENT_PROFILE >/dev/null 2>&1; then
  kubectl config use-context $MANAGEMENT_PROFILE
fi

minikube profile list
