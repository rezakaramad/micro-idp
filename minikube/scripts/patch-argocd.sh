#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="argocd"
TUNNEL_URL_FILE=".cloudflare-url"

if [[ ! -f "$TUNNEL_URL_FILE" ]]; then
  echo "❌ No Cloudflare URL file found!"
  echo "Make sure cloudflared tunnel started and exported URL."
  exit 1
fi

CLOUDFLARE_URL=$(cat "$TUNNEL_URL_FILE")

echo "🔧 Patching Argo CD with public URL: $CLOUDFLARE_URL"

kubectl patch configmap argocd-cm -n "$NAMESPACE" \
  -p "{\"data\": {\"url\": \"$CLOUDFLARE_URL\"}}"

kubectl rollout restart deployment argocd-server -n "$NAMESPACE"

echo "🌍 Access Argo CD at: $CLOUDFLARE_URL"
