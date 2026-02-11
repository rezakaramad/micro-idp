#!/usr/bin/env bash

PROFILE="argocd"

echo "🔥 Stopping Cloudflare tunnel..."
# Kill cloudflared if running
pkill -f "cloudflared tunnel" 2>/dev/null || true

echo "🔥 Stopping kubectl port-forward..."
# Kill any port-forward targeting your gateway or argocd namespace
pkill -f "kubectl port-forward" 2>/dev/null || true

echo "🔥 Deleting Minikube cluster '$PROFILE'..."
minikube delete -p "$PROFILE" || true
echo "✅ Cluster deleted."

echo "🧹 Cleaning certificate directory..."
rm -rf .certs/ || true

echo "🧹 Removing Cloudflare URL file..."
rm -f .cloudflare-url || true

echo "✨ Cleanup complete!"
