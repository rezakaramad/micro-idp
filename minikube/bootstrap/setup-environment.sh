#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Discover tenant clusters dynamically.
# "minikube-mgmt" = management cluster (tunnel only)
# other "minikube-*" profiles = tenants (proxies + Argo CD cluster registration)
# -----------------------------------------------------------------------------

MGMT_PROFILE="minikube-mgmt"

get_tenant_profiles() {
  minikube profile list -o json \
    | jq -r --arg mgmt "$MGMT_PROFILE" '
        .valid[].Name
        | select(startswith("minikube-") and . != $mgmt)
      '
}

# Base port for kubectl API proxies.
# We expose each tenant cluster locally as:
#   9001 → first tenant
#   9002 → second tenant
# so Argo CD can talk to multiple clusters at once.
BASE_PORT=9001

# ----------------------------------------------------------------------------
# Networking
# ----------------------------------------------------------------------------

start_minikube_tunnel() {
  echo "🚇 Ensuring minikube tunnel is running..."

  if ! pgrep -f "minikube tunnel -p minikube-mgmt" >/dev/null; then
    minikube tunnel -p minikube-mgmt >/dev/null 2>&1 &
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
  } | sudo tee -a /etc/hosts >/dev/null
}

start_proxy() {
  local PROFILE=$1
  local PORT=$2

  if ss -ltnp 2>/dev/null | grep -q "kubectl.*:$PORT"; then
    echo "Proxy already running on port $PORT"
    return
  fi

  echo "🚇 Starting proxy for $PROFILE on port $PORT"

  kubectl --context "$PROFILE" proxy \
    --address=0.0.0.0 \
    --accept-hosts='.*' \
    --port="$PORT" \
    >/dev/null 2>&1 &

  sleep 2
}

start_cluster_proxies() {
  local port=$BASE_PORT

  for profile in $(get_tenant_profiles); do
    start_proxy "$profile" "$port"
    ((port++))
  done
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
}

# ----------------------------------------------------------------------------
# Argo CD cluster credentials
# ----------------------------------------------------------------------------

register_clusters() {
  echo "🔐 Writing Argo CD clusters credentials..."

  local port=$BASE_PORT

  for profile in $(get_tenant_profiles); do
    echo "🚀 Cluster $profile → http://host.minikube.internal:$port"

    kubectl --context "$profile" create serviceaccount argocd-manager -n kube-system || true
    kubectl --context "$profile" create clusterrolebinding argocd-manager \
      --clusterrole=cluster-admin \
      --serviceaccount=kube-system:argocd-manager || true

    TOKEN=$(kubectl --context "$profile" -n kube-system create token argocd-manager)
    SERVER="http://host.minikube.internal:$port"

    vault kv put local/management/argocd/clusters/"$profile" \
      server="$SERVER" \
      token="$TOKEN"

    ((port++))
  done
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  start_minikube_tunnel
  # start_cluster_proxies 
  update_hosts
  vault_login
  create_github_app_secret
  register_clusters

  echo "✅ Bootstrap complete"
}

main
