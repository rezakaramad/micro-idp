#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIND9_DIR="${SCRIPT_DIR}/../bind9"

PORT=1053
VAULT_PATH="local/management/external-dns/rfc2136"

echo "⚙️ Using bind9 config from: ${BIND9_DIR}"

# ----------------------------------------------------------------------------
# Vault login
# ----------------------------------------------------------------------------
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

  export VAULT_ADDR="https://vault.fluxdojo.local"
  export VAULT_TOKEN="$VAULT_TOKEN"
  export VAULT_SKIP_VERIFY=true

  # Enable KV engine only if not already enabled
  if ! vault secrets list | grep -q '^local/'; then
    vault secrets enable -path=local kv-v2
  fi

  echo "✅ Vault authenticated"
}

# ----------------------------------------------------------------------------
# Sanity checks
# ----------------------------------------------------------------------------
check_bind9_files() {
  echo "🔍 Checking bind9 configuration..."

  if [[ ! -f "${BIND9_DIR}/named.conf" ]]; then
    echo "❌ named.conf not found at ${BIND9_DIR}"
    exit 1
  fi

  if [[ ! -d "${BIND9_DIR}/zones" ]]; then
    echo "❌ zones directory not found at ${BIND9_DIR}"
    exit 1
  fi

  echo "✅ bind9 config OK"
}

# ----------------------------------------------------------------------------
# Fetch TSIG secret
# ----------------------------------------------------------------------------
fetch_tsig_secret() {
  echo "🔐 Fetching TSIG secret from Vault..."

  if ! TSIG_SECRET=$(vault kv get -field=tsig_secret "$VAULT_PATH" 2>/dev/null); then
    echo "❌ Failed to fetch TSIG secret from Vault at $VAULT_PATH"
    echo "👉 Did you run bootstrap (create_external_dns_tsig_secret)?"
    exit 1
  fi

  # Safety check
  if [[ -z "${TSIG_SECRET:-}" ]]; then
    echo "❌ TSIG_SECRET is empty"
    exit 1
  fi

  # Validate base64
  if ! echo "$TSIG_SECRET" | base64 -d >/dev/null 2>&1; then
    echo "❌ TSIG_SECRET is not valid base64"
    exit 1
  fi

  export TSIG_SECRET

  echo "✅ TSIG secret loaded"
}

# ----------------------------------------------------------------------------
# Create TSIG key file
# ----------------------------------------------------------------------------
create_tsig_key_file() {
  local TSIG_FILE="${BIND9_DIR}/tsig.key"

  echo "🔐 Creating TSIG key file..."

  cat > "$TSIG_FILE" <<EOF
key "externaldns-key" {
    algorithm hmac-sha256;
    secret "${TSIG_SECRET}";
};
EOF

  chmod 644 "$TSIG_FILE"

  echo "✅ TSIG key file created → $TSIG_FILE"
}

# ----------------------------------------------------------------------------
# Validate BIND config
# ----------------------------------------------------------------------------
validate_named_conf() {
  echo "🔍 Validating named.conf..."

  docker run --rm \
    --entrypoint named-checkconf \
    -v "${BIND9_DIR}/named.conf:/etc/bind/named.conf" \
    -v "${BIND9_DIR}/tsig.key:/etc/bind/tsig.key" \
    -v "${BIND9_DIR}/zones:/zones" \
    internetsystemsconsortium/bind9:9.18 \
    /etc/bind/named.conf

  echo "✅ named.conf is valid"
}

# ----------------------------------------------------------------------------
# Port check
# ----------------------------------------------------------------------------
check_port() {
  echo "🔍 Checking if port ${PORT} is free..."

  if lsof -iTCP:${PORT} -sTCP:LISTEN -Pn >/dev/null 2>&1 || \
     lsof -iUDP:${PORT} -Pn >/dev/null 2>&1; then

    echo "❌ Port ${PORT} is already in use"
    echo ""
    echo "Processes using port ${PORT}:"
    lsof -i :${PORT} || true
    echo ""
    echo "👉 Either stop the process or change the port"
    exit 1
  fi

  echo "✅ Port ${PORT} is free"
}

# ----------------------------------------------------------------------------
# Cleanup old container
# ----------------------------------------------------------------------------
cleanup_existing_container() {
  if docker ps -a --format '{{.Names}}' | grep -q '^bind9$'; then
    echo "🧹 Removing existing bind9 container"
    docker rm -f bind9 >/dev/null 2>&1 || true
  fi
}

# ----------------------------------------------------------------------------
# Start BIND9
# ----------------------------------------------------------------------------
start_bind9() {
  echo "🚀 Starting BIND9..."

  CONTAINER_ID=$(docker run -d \
    --name bind9 \
    -p ${PORT}:53/udp \
    -p ${PORT}:53/tcp \
    -v "${BIND9_DIR}/named.conf:/etc/bind/named.conf" \
    -v "${BIND9_DIR}/tsig.key:/etc/bind/tsig.key" \
    -v "${BIND9_DIR}/zones:/zones" \
    internetsystemsconsortium/bind9:9.18 \
    -c /etc/bind/named.conf -g)

  echo "✅ BIND9 started → $CONTAINER_ID"
}

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
verify() {
  echo "🔍 Running DNS checks..."
  echo "Checking nameserver record"
  dig @127.0.0.1 -p ${PORT} ns.fluxdojo.demo +short
  echo "Checking zone authority"
  dig @127.0.0.1 -p ${PORT} fluxdojo.demo +noall +authority
  echo "Checking recursion is disabled"
  dig @127.0.0.1 -p ${PORT} google.com | grep status
  echo "✅ DNS sanity checks complete"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  vault_login
  check_bind9_files
  fetch_tsig_secret
  create_tsig_key_file
  validate_named_conf
  check_port
  cleanup_existing_container
  start_bind9
  verify
}

main "$@"