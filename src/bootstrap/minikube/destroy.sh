#!/usr/bin/env bash
set -euo pipefail

echo "🧹 Cleaning background processes..."

pkill -f "minikube tunnel" || true
pkill -f "kubectl.*proxy" || true

# -------------------------------
# Stop and remove PowerDNS containers
# -------------------------------
for container in pdns pdns-admin pdns-db; do
  if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
    docker rm -f "$container" >/dev/null 2>&1 || true
    echo "🗑 Removed $container"
  else
    echo "✅ No $container container found"
  fi
done

# -------------------------------
# Delete all Minikube clusters and clean kubeconfig
# -------------------------------

echo "🧨 Deleting all Minikube clusters..."

minikube delete --all --purge || true

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
  echo "✅ No rezakara.demo entries found"
fi

# -------------------------------
# Flush DNS cache
# -------------------------------
echo "🔄 Flushing DNS cache..."
sudo resolvectl flush-caches 2>/dev/null || true
echo "✅ DNS cache flushed"
