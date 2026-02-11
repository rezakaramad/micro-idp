#!/usr/bin/env bash
set -euo pipefail

# Ensure bash (even when Taskfile runs under fish)
if [ -n "${FISH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

NAMESPACE="argocd"
OUTPUT_FILE=".cloudflare-url"
LOGFILE="/tmp/cloudflared.log"
PF_LOG="/tmp/portforward.log"

echo "🌐 Starting Cloudflare quick tunnel to local Gateway (port-forwarded at 8085)..."

# Clean logs
rm -f "$LOGFILE" "$PF_LOG"

### -----------------------------------------------------------
### 1. PORT-FORWARD GATEWAY → localhost:8085
### -----------------------------------------------------------
echo "🔌 Starting port-forward: svc/argocd-gateway → localhost:8085 ..."

kubectl port-forward -n kube-system svc/default 8085:443 > "$PF_LOG" 2>&1 &
PF_PID=$!

echo "🔧 Port-forward PID: $PF_PID"
sleep 2

# Check if port-forward failed immediately
if ! ps -p $PF_PID > /dev/null; then
  echo "❌ Port-forward failed. Check $PF_LOG"
  exit 1
fi

### -----------------------------------------------------------
### 2. START CLOUDFLARED → https://localhost:8085
### -----------------------------------------------------------
echo "🚀 Launching cloudflared tunnel → https://localhost:8085 ..."

cloudflared tunnel --no-tls-verify --url https://localhost:8085 > "$LOGFILE" 2>&1 &
CLOUDFLARED_PID=$!

echo "🌀 cloudflared PID: $CLOUDFLARED_PID"
echo "⏳ Waiting for Cloudflare to generate public URL..."

### -----------------------------------------------------------
### 3. WAIT FOR TRY-CLOUDFLARE URL
### -----------------------------------------------------------
for i in {1..20}; do
    URL=$(grep -o 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' "$LOGFILE" | head -n 1 || true)

    if [[ -n "$URL" ]]; then
        echo "✅ Public URL: $URL"
        echo "$URL" > "$OUTPUT_FILE"
        echo "📁 Saved to $OUTPUT_FILE"
        exit 0
    fi

    sleep 1
done

echo "❌ Failed to detect Cloudflare URL after waiting."
echo "Check logs:"
echo "  PF:  $PF_LOG"
echo "  CF:  $LOGFILE"

exit 1
