#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWERDNS_COMPOSE_FILE="${SCRIPT_DIR}/../powerdns/docker-compose.yaml"

MANAGEMENT_PROFILE="minikube-management"

VAULT_BASE_PATH="local/powerdns"
VAULT_DB_PATH="$VAULT_BASE_PATH/db"
VAULT_API_PATH="$VAULT_BASE_PATH/api"
VAULT_ADMIN_PATH="$VAULT_BASE_PATH/admin"
VAULT_EXTERNALDNS_PATH="local/management/external-dns/rfc2136"

# -----------------------------------------------------
# Authenticate to Vault
# -----------------------------------------------------
vault_login() {
  local VAULT_NAMESPACE="vault"

  echo "🔐 Authenticating to Vault..."

  kubectl wait \
    --for=condition=Ready pod \
    -l app.kubernetes.io/name=vault \
    -n "$VAULT_NAMESPACE" \
    --timeout=120s

  VAULT_POD=$(kubectl get pods -n "$VAULT_NAMESPACE" \
    -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].metadata.name}')

  VAULT_TOKEN=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    sh -c "grep 'Initial Root Token:' /vault/data/init.txt | awk '{print \$4}'")

  export VAULT_ADDR="https://vault.rezakara.demo"
  export VAULT_TOKEN="$VAULT_TOKEN"
  export VAULT_SKIP_VERIFY=true

  # Enable KV engine only if not already enabled
  if ! vault secrets list | grep -q '^local/'; then
    vault secrets enable -path=local kv-v2
  fi

  echo "✅ Vault authenticated"
}

# -----------------------------------------------------
# Load + verify + export
# -----------------------------------------------------
load_powerdns_secrets() {
  echo "📥 Loading secrets from Vault..."

  POSTGRES_DB="pdns"
  POSTGRES_USER="pdns"

  POSTGRES_PASSWORD="$(vault kv get -field=password $VAULT_DB_PATH)"
  PDNS_API_KEY="$(vault kv get -field=key $VAULT_API_PATH)"
  PDNS_ADMIN_PASSWORD="$(vault kv get -field=password $VAULT_ADMIN_PATH)"

  [ -n "$POSTGRES_PASSWORD" ] || { echo "❌ DB password missing"; exit 1; }
  [ -n "$PDNS_API_KEY" ] || { echo "❌ API key missing"; exit 1; }
  [ -n "$PDNS_ADMIN_PASSWORD" ] || { echo "❌ Admin password missing"; exit 1; }

  PDNS_ADMIN_PASSWORD_HASH=$(printf "%s" "$PDNS_ADMIN_PASSWORD" | sha256sum | awk '{print $1}')

  [ -n "$PDNS_ADMIN_PASSWORD_HASH" ] || { echo "❌ Failed to generate admin hash"; exit 1; }

  export POSTGRES_DB
  export POSTGRES_USER
  export POSTGRES_PASSWORD

  export PDNS_API_KEY
  export PDNS_ADMIN_PASSWORD_HASH

  echo "✅ Secrets loaded and exported"
}

# -----------------------------------------------------
# Reset + start Docker Compose
# -----------------------------------------------------
start_compose() {
  echo "🧹 Resetting environment (required for new credentials)..."
  docker compose -f "$POWERDNS_COMPOSE_FILE" down -v || true

  echo "🚀 Starting Docker Compose..."
  docker compose -f "$POWERDNS_COMPOSE_FILE" up -d || {
    echo "❌ Docker Compose failed"
    exit 1
  }

  echo "🎉 Stack started"
}

# -----------------------------------------------------
# Main
# -----------------------------------------------------
main() {
vault_login
load_powerdns_secrets
start_compose
}

main "$@"
