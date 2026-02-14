#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Discover tenant clusters dynamically.
# "minikube-management" = management cluster (tunnel only)
# other "minikube-*" profiles = tenants (proxies + Argo CD cluster registration)
# -----------------------------------------------------------------------------

MANAGEMENT_PROFILE="minikube-management"

get_tenant_profiles() {
  minikube profile list -o json \
    | jq -r --arg mgmt "$MANAGEMENT_PROFILE" '
        .valid[].Name
        | select(startswith("minikube-") and . != $mgmt)
      '
}

# ----------------------------------------------------------------------------
# Networking
# ----------------------------------------------------------------------------

start_minikube_tunnel() {
  echo "🚇 Ensuring minikube tunnel is running..."

  if ! pgrep -f "minikube tunnel -p $MANAGEMENT_PROFILE" >/dev/null; then
    minikube tunnel -p $MANAGEMENT_PROFILE >/dev/null 2>&1 &
    sleep 5
  else
    echo "Tunnel already running"
  fi
}

update_hosts() {
  local PLATFORM_NAMESPACE="platform-resources"

  echo "⚙️  Updating /etc/hosts (requires sudo privileges)"

  LB_IP=$(kubectl get svc traefik \
    -n "$PLATFORM_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

  until [ -n "$LB_IP" ]; do
    sleep 2
    LB_IP=$(kubectl get svc traefik \
      -n "$PLATFORM_NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  done

  sudo sed -i.bak '/fluxdojo.local/d' /etc/hosts

  {
    echo "$LB_IP argocd.fluxdojo.local"
    echo "$LB_IP vault.fluxdojo.local"
    echo "$LB_IP oidc.fluxdojo.local"
  } | sudo tee -a /etc/hosts >/dev/null
}

# ----------------------------------------------------------------------------
# CLI Login to Vault 
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

  vault secrets enable -path=local kv-v2 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# GitHub App secret
# ----------------------------------------------------------------------------

create_github_app_secret() {
  echo "🔐 Writing GitHub App secret..."

  APP_ID=$(pass show private/github/apps/rezakaramad-argocd/app-id | head -n1)
  INSTALLATION_ID=$(pass show private/github/apps/rezakaramad-argocd/installation-id | head -n1)
  PRIVATE_KEY=$(pass show private/github/apps/rezakaramad-argocd/private-key)

  vault kv put local/management/github/apps/argocd \
    app-id="$APP_ID" \
    installation-id="$INSTALLATION_ID" \
    private-key="$PRIVATE_KEY"

  echo "✅ Argo CD GitHub App secret written to Vault"

}

# ----------------------------------------------------------------------------
# Argo CD cluster credentials
# ----------------------------------------------------------------------------

register_clusters() {
  echo "🔐 Writing Argo CD clusters credentials..."

  for profile in $(get_tenant_profiles); do
    IP=$(minikube ip -p "$profile")
    SERVER="https://${IP}:8443"

  echo "🚀 Cluster $profile → $SERVER"

  kubectl --context "$profile" create serviceaccount argocd-manager -n kube-system 2>/dev/null || true

  kubectl --context "$profile" create clusterrolebinding argocd-manager \
    --clusterrole=cluster-admin \
    --serviceaccount=kube-system:argocd-manager 2>/dev/null || true

  TOKEN=$(kubectl --context "$profile" -n kube-system create token argocd-manager)

  vault kv put local/management/argocd/clusters/"$profile" \
    server="$SERVER" \
    token="$TOKEN"

  done

  echo "✅ Argo CD cluster credentials written to Vault"
}

# ----------------------------------------------------------------------------
# Keycloak credentials
# ----------------------------------------------------------------------------

create_keycloak_azure_secret() {
  echo "🔐 Writing Entra ID App secret..."

  VAULT_PATH="local/management/keycloak/azure/apps/fluxdojo-keycloak-management-idp"

  CLIENT_SECRET=$(pass show private/azure/entra-id/apps/keycloak/client-secrets/fluxdojo-keycloak-management-idp/value | head -n1)

  if [[ -z "$CLIENT_SECRET" ]]; then
    echo "❌ Failed to read client secret from pass."
    return 1
  fi

  vault kv put local/management/keycloak/azure/apps/fluxdojo-keycloak-management-idp \
    client-secret="$CLIENT_SECRET" \

  echo "✅ Entra ID client secret stored in Vault"
}

create_keycloak_admin_secret() {
  echo "🔐 Generating Keycloak admin credentials..."

  VAULT_PATH="local/management/keycloak/initial-admin"

  if vault kv get "$VAULT_PATH" >/dev/null 2>&1; then
    echo "⚠️  Admin secret already exists. Skipping."
    return
  fi

  ADMIN_PASSWORD="$(openssl rand -hex 16)"

  vault kv put "$VAULT_PATH" \
    username="admin" \
    password="$ADMIN_PASSWORD" > /dev/null

  echo "✅ Keycloak admin credentials stored in Vault"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  start_minikube_tunnel
  update_hosts
  vault_login
  create_github_app_secret
  register_clusters
  create_keycloak_db_secret
  create_keycloak_admin_secret

  echo "✅ Bootstrap complete"
}

main
