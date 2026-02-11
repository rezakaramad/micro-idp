#!/usr/bin/env bash
set -euo pipefail

PROFILE="micro-idp"

echo "🚀 Starting Minikube cluster..."
minikube status -p "$PROFILE" >/dev/null 2>&1 && {
  echo "ℹ️  Minikube already running. Skipping start."
  exit 0
}

minikube start -p "$PROFILE" \
  --kubernetes-version=v1.30.0 \
  --cpus=4 \
  --memory=4096

echo "✅ Minikube ready!"
