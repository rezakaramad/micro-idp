#!/usr/bin/env bash
set -euo pipefail

echo "🧹 Cleaning background processes..."

pkill -f "minikube tunnel" || true
pkill -f "kubectl.*proxy" || true

echo "🧨 Deleting all Minikube clusters..."

minikube delete --all

echo "🧼 Cleaning kubeconfig leftovers..."

contexts=$(kubectl config get-contexts -o name | grep '^minikube-' || true)

for context in $contexts; do
  kubectl config delete-context "$context" || true
done

echo "✅ Clean slate ready"
