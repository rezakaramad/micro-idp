#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="https://vault.fluxdojo.local"
MANAGEMENT_PROFILE="minikube-management"
VAULT_NAMESPACE="vault"

echo "🔐 Configuring Vault access for workload clusters..."

# -----------------------------------------------------
# Authenticate to Vault
# -----------------------------------------------------

vault_login() {

  echo "🔐 Authenticating to Vault..."

  kubectl --context "$MANAGEMENT_PROFILE" wait \
    --for=condition=Ready pod \
    -l app.kubernetes.io/name=vault \
    -n "$VAULT_NAMESPACE" \
    --timeout=120s

  VAULT_POD=$(kubectl --context "$MANAGEMENT_PROFILE" \
    get pods -n "$VAULT_NAMESPACE" \
    -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].metadata.name}')

  VAULT_TOKEN=$(kubectl --context "$MANAGEMENT_PROFILE" \
    exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    sh -c "grep 'Initial Root Token:' /vault/data/init.txt | awk '{print \$4}'")

  export VAULT_ADDR
  export VAULT_TOKEN
  export VAULT_SKIP_VERIFY=true

  echo "✅ Vault authenticated"

  vault secrets enable -path=local kv-v2 2>/dev/null || true
}

# -----------------------------------------------------
# Discover workload clusters
# -----------------------------------------------------

get_minikube_workload_profiles() {
  minikube profile list -o json \
  | jq -r '
      .valid[]
      | select(.Status == "OK")
      | .Name
      | select(startswith("minikube-") and . != "minikube-management")
    '
}

# -----------------------------------------------------
# Ensure reviewer SA + token exist
# -----------------------------------------------------

ensure_reviewer_token() {

  local profile="$1"

  echo "🔎 Ensuring vault-reviewer SA exists in $profile..."

  kubectl --context="$profile" -n kube-system get sa vault-reviewer >/dev/null 2>&1 || {
    echo "❌ vault-reviewer ServiceAccount missing in $profile"
    echo "   Install baseline-workload first."
    exit 1
  }

  if ! kubectl --context="$profile" -n kube-system get secret vault-reviewer-token >/dev/null 2>&1; then

    echo "➕ Creating long-lived reviewer token secret..."

    kubectl --context="$profile" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-reviewer-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: vault-reviewer
type: kubernetes.io/service-account-token
EOF

    echo "⏳ Waiting for token population..."

    for i in {1..10}; do
      if kubectl --context="$profile" -n kube-system \
        get secret vault-reviewer-token -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; then
        break
      fi
      sleep 1
    done
  fi
}

# -----------------------------------------------------
# Configure Kubernetes auth for workload clusters
# -----------------------------------------------------

configure_cluster() {

  local profile="$1"
  local AUTH_PATH="kubernetes-${profile}"

  echo ""
  echo "➡️  Configuring Vault auth for $profile"

  kubectl --context="$profile" wait \
    --for=condition=Ready nodes \
    --all \
    --timeout=120s

  ensure_reviewer_token "$profile"

  API_SERVER=$(kubectl config view --raw \
    -o jsonpath="{.clusters[?(@.name==\"$profile\")].cluster.server}")

  REVIEWER_JWT=$(kubectl --context="$profile" \
    -n kube-system get secret vault-reviewer-token \
    -o jsonpath='{.data.token}' | base64 -d)

  CA_CERT=$(kubectl --context="$profile" \
    -n kube-system get secret vault-reviewer-token \
    -o jsonpath='{.data.ca\.crt}' | base64 -d)

  echo "🔗 API Server: $API_SERVER"

  vault auth enable -path="$AUTH_PATH" kubernetes 2>/dev/null || true

  echo "⚙️ Configuring Kubernetes auth backend..."

  vault write auth/"$AUTH_PATH"/config \
    token_reviewer_jwt="$REVIEWER_JWT" \
    kubernetes_host="$API_SERVER" \
    kubernetes_ca_cert="$CA_CERT" \
    disable_iss_validation=true

  echo "🔑 Creating ESO role..."

  vault write auth/"$AUTH_PATH"/role/external-secrets \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="platform-system" \
    policies="eso-policy" \
    audience="https://kubernetes.default.svc.cluster.local" \
    ttl="1h"

  echo "✅ Vault auth configured for $profile"
}

# -----------------------------------------------------
# Main
# -----------------------------------------------------

vault_login

while read -r profile; do
  configure_cluster "$profile"
done < <(get_minikube_workload_profiles)

echo ""
echo "🎉 Workload clusters successfully configured in Vault"
