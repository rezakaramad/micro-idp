#!/usr/bin/env bash
set -euo pipefail

echo "🧹 Cleaning background processes..."

pkill -f "minikube tunnel" || true
pkill -f "kubectl.*proxy" || true

# -------------------------------
# Stop and remove BIND9 container
# -------------------------------
echo "🧹 Cleaning BIND9 container..."

if docker ps -a --format '{{.Names}}' | grep -q '^bind9$'; then
  docker rm -f bind9 >/dev/null 2>&1 || true
else
  echo "✔ No bind9 container found"
fi

# -------------------------------
# Delete all Minikube clusters and clean kubeconfig
# -------------------------------

echo "🧨 Deleting all Minikube clusters..."

minikube delete --all

echo "🧼 Cleaning kubeconfig leftovers..."

contexts=$(kubectl config get-contexts -o name | grep '^minikube-' || true)

for context in $contexts; do
  kubectl config delete-context "$context" || true
done

echo "✅ Clean slate ready"

# -------------------------------
# Clean /etc/hosts entries
# -------------------------------
echo "🧼 Cleaning /etc/hosts entries..."

if grep -q 'rezakara.demo' /etc/hosts; then
  echo "🧹 Removing rezakara.demo entries from /etc/hosts"

  sudo cp /etc/hosts /etc/hosts.bak

  sudo sed -i.bak '/rezakara\.demo/d' /etc/hosts

  echo "✅ /etc/hosts cleaned"
else
  echo "✔ No rezakara.demo entries found"
fi
