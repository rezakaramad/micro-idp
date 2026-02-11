#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="argocd"
TUNNEL_URL_FILE=".cloudflare-url"

echo "👤 Username: admin"
echo -n "🔑 Password: "
kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 --decode; echo


