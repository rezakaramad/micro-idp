#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Bootstrapping core platform charts..."

# Compute repo root dynamically 
# Returns absolute path to script location, in my case it's '/home/kara/github/r-karamad/kubepave/src/bootstrap/minikube'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Go three folders up from where the script lives, and give me that absolute path.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# Absolute path to 'charts/'' directory
CHARTS_DIR="$REPO_ROOT/charts"

# Specify platform components namespaces
PLATFORM_NAMESPACE="platform-system"
VAULT_NAMESPACE="vault"
ARGOCD_NAMESPACE="argocd"

# Gateway API version
GATEWAY_API_VERSION="v1.4.1"

MANAGEMENT_PROFILE="minikube-management"

# CoreDNS Adjustment
COREDNS_NS="kube-system"
TRAEFIK_SVC="traefik-mgmt"
DNS_DOMAIN="mgmt.rezakara.demo"
DNS_HOSTS=(
  vault
)

# -----------------------------------------------------------------------------
# Discover Minikube clusters
# -----------------------------------------------------------------------------

# All clusters
get_minikube_profiles() {
  minikube profile list -o json \
    | jq -r '
        .valid[]
        | select(.Status == "OK")
        | .Name
        | select(startswith("minikube-"))
      '
}

# Workload clusters only
get_minikube_tenant_profiles() {
  minikube profile list -o json \
    | jq -r --arg mgmt "$MANAGEMENT_PROFILE" '
        .valid[]
        | select(.Status == "OK")
        | .Name
        | select(startswith("minikube-") and . != $mgmt)
      '
}

# -----------------------------------------------------------------------------
# helm_install — Small wrapper around `helm upgrade --install`
#
# Usage:
#   helm_install <release> <chart> <namespace> [extra helm args...]
#
# Examples:
#   helm_install cert-manager cert-manager platform-system
#   helm_install platform-namespaces platform-namespaces default -f values.yaml
#   helm_install vault vault vault --set server.dev.enabled=true
#
# Any arguments after the first 3 are forwarded directly to Helm.
# This lets us pass -f, --set, --wait, etc. without modifying this function.
# -----------------------------------------------------------------------------
helm_install () {
  local name=$1        # Helm release name
  local chart=$2       # Chart folder name (../charts/<chart>)
  local namespace=$3   # Target namespace
  local profile=${4:-minikube-management}   # Minikube profile
  # Remove first 3 args so "$@" contains only extra Helm flags (if any)
  # Example:
  #   before: name chart ns -f values.yaml
  #   after : -f values.yaml

  if [[ $# -ge 4 ]]; then
    shift 4
  else
    shift 3
  fi

  echo ""
  echo "📦 Installing $name → namespace: $namespace (context: $profile)"
  
  helm upgrade --install "$name" "$CHARTS_DIR/$chart" \
    -n "$namespace" \
    --kube-context "$profile" \
    --timeout 10m \
    --force \
    "$@" # Forward any additional Helm arguments
}

# -----------------------------------------------------------------------------
# Traefik LoadBalancer IP in management cluster
# -----------------------------------------------------------------------------

start_minikube_tunnel() {
  echo "🔌 Ensuring minikube tunnel is running..."

  if ! pgrep -f "minikube tunnel -p $MANAGEMENT_PROFILE" >/dev/null; then
    minikube tunnel -p $MANAGEMENT_PROFILE >/dev/null 2>&1 &
    sleep 5
  else
    echo "Tunnel already running"
  fi
}

wait_for_traefik_ip() {
  local ip=""

  echo "🌐 Waiting for Traefik IP in $MANAGEMENT_PROFILE..." >&2

  for _ in {1..60}; do
    ip=$(kubectl --context "$MANAGEMENT_PROFILE" -n "$PLATFORM_NAMESPACE" \
      get svc "$TRAEFIK_SVC" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi

    sleep 2
  done

  echo "❌ Traefik IP not found in $MANAGEMENT_PROFILE" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# Update CoreDNS in workload clusters
# -----------------------------------------------------------------------------

update_dns() {
  local profile=$1
  local ip=$2
  shift 2
  local hosts=("$@")
  local corefile
  local hosts_block=""

  if [[ ${#hosts[@]} -eq 0 ]]; then
    echo "❌ No DNS hosts provided"
    return 1
  fi

  echo "✏️  Updating CoreDNS in $profile"

  for host in "${hosts[@]}"; do
    printf "   %-30s → %s\n" "$host.$DNS_DOMAIN" "$ip"
  done

  corefile=$(kubectl --context "$profile" -n "$COREDNS_NS" \
    get cm coredns -o jsonpath='{.data.Corefile}')

  corefile=$(sed '/# BEGIN rezakara DNS/,/# END rezakara DNS/d' <<< "$corefile")

  for host in "${hosts[@]}"; do
    hosts_block+="        $ip $host.$DNS_DOMAIN"$'\n'
  done

  corefile="$corefile

# BEGIN rezakara DNS
$DNS_DOMAIN:53 {
    hosts {
$hosts_block        fallthrough
    }
    cache 30
}
# END rezakara DNS
"

  kubectl --context "$profile" -n "$COREDNS_NS" patch cm coredns \
    --type merge \
    -p "{\"data\":{\"Corefile\":$(jq -Rs . <<< "$corefile")}}"

  kubectl --context "$profile" -n "$COREDNS_NS" \
    rollout restart deployment coredns >/dev/null

  echo "✅ DNS updated"
}

# ----------------------------------------------------------------------------
# Install Kubernetes Gateway API on Minikube clusters
# ----------------------------------------------------------------------------

install_gateway_api() {

  echo "🚀 Installing Kubernetes Gateway API..."

  GATEWAY_API_URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

  get_minikube_profiles | while read -r profile; do
    echo "🔎 Checking API readiness..."
    kubectl --context="$profile" get --raw=/readyz >/dev/null

    if ! kubectl --context="$profile" get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
      echo "🚀 Installing Gateway API on $profile..."
      kubectl --context="$profile" apply -f "$GATEWAY_API_URL"
    else
      echo "✅ Gateway API already installed on $profile"
    fi

    echo "⏳ Waiting for CRDs in $profile..."
    kubectl --context="$profile" wait \
      --for=condition=Established \
      crd/gateways.gateway.networking.k8s.io \
      --timeout=60s

    echo "🎉 Gateway API successfully installed on Minikube $profile"
    kubectl --context="$profile" get crd \
      gateways.gateway.networking.k8s.io \
      httproutes.gateway.networking.k8s.io \
      gatewayclasses.gateway.networking.k8s.io || true

    echo "⏳ Waiting for cluster networking in $profile cluster..."
    kubectl --context="$profile" wait --for=condition=Ready nodes --all --timeout=120s
    kubectl --context="$profile" wait --for=condition=Available deployment/coredns -n kube-system --timeout=120s
    kubectl --context="$profile" wait --for=condition=Available deployment/kube-proxy -n kube-system --timeout=120s 2>/dev/null || true
  done
}

# ----------------------------------------------------------------------------
# Install core components
# ----------------------------------------------------------------------------

install_crds() {
  # Install external-secrets CRDs
  CHART_PATH="$CHARTS_DIR/external-secrets"
  CHART_VERSION=$(yq '.dependencies[] | select(.name=="external-secrets") | .version' "$CHART_PATH/Chart.yaml")

  mkdir -p "$CHART_PATH/crds"
  curl -L \
    -o $CHART_PATH/crds/bundle.yaml \
    https://raw.githubusercontent.com/external-secrets/external-secrets/refs/tags/v$CHART_VERSION/deploy/crds/bundle.yaml

  kubectl apply --server-side -f "$CHART_PATH/crds/bundle.yaml"

  # Install cert-manager CRDs
  CHART_PATH="$CHARTS_DIR/cert-manager"
  CHART_VERSION=$(yq '.dependencies[] | select(.name=="cert-manager") | .version' "$CHART_PATH/Chart.yaml")

  mkdir -p "$CHART_PATH/crds"
  curl -fsSL \
    https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/acme.cert-manager.io_challenges.yaml \
    https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/acme.cert-manager.io_orders.yaml \
    https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/cert-manager.io_certificaterequests.yaml \
    https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/cert-manager.io_certificates.yaml \
    https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/cert-manager.io_clusterissuers.yaml \
    https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/cert-manager.io_issuers.yaml \
    > "$CHART_PATH/crds/bundle.yaml"

  kubectl apply --server-side -f $CHART_PATH/crds/bundle.yaml

}

# ----------------------------------------------------------------------------
# Install platform charts
# ----------------------------------------------------------------------------
install_platform_components() {

  helm_install baseline-management baseline-management "default"
  helm_install cert-manager cert-manager "$PLATFORM_NAMESPACE"
  helm_install vault vault "$VAULT_NAMESPACE"
  helm_install external-secrets external-secrets "$PLATFORM_NAMESPACE"
  helm_install external-dns external-dns "$PLATFORM_NAMESPACE"
  helm_install traefik-mgmt traefik "$PLATFORM_NAMESPACE"

  # Argo CD has dependancy to all the above services and controllers, 
  # therefore we need to make sure that those are up and running before deploying Argo CD.
  echo "⏳ Waiting for components to become ready..."

  kubectl wait --for=condition=Available deployment \
    -l app.kubernetes.io/name=traefik \
    -n "$PLATFORM_NAMESPACE" \
    --timeout=180s

  # We must enable 'minikube tunnel' first otherwise Traefik service can not aquire an external IP.
  start_minikube_tunnel

  ip=$(wait_for_traefik_ip)

  get_minikube_profiles | while read -r profile; do
    echo "🔎 Cluster: $profile"
    update_dns "$profile" "$ip" "${DNS_HOSTS[@]}"
    echo "--------------------------------"
  done

  echo "🏁 Done"

  kubectl wait --for=condition=Available deployment \
    -l app.kubernetes.io/name=cert-manager \
    -n "$PLATFORM_NAMESPACE" \
    --timeout=180s

  kubectl wait --for=condition=Available deployment \
    -l app.kubernetes.io/name=external-secrets \
    -n "$PLATFORM_NAMESPACE" \
    --timeout=180s

  kubectl wait --for=condition=Available deployment \
    -l app.kubernetes.io/component=webhook \
    -n "$PLATFORM_NAMESPACE" \
    --timeout=180s

  helm_install argocd argocd "$ARGOCD_NAMESPACE"

  echo "⏳ Waiting for external-secrets webhook..."

  kubectl wait --for=condition=Available deployment \
    -l app.kubernetes.io/name=external-secrets-webhook \
    -n "$PLATFORM_NAMESPACE" \
    --timeout=180s

  # This readiness verification is required because components deployed later depend on it.
  echo "⏳ Waiting for ClusterSecretStore to become ready..."

  kubectl --context="$MANAGEMENT_PROFILE" wait \
    --for=condition=Ready \
    clustersecretstore.external-secrets.io/vault-local \
    --timeout=180s


  # Bootstrap the GitOps structure (application folders and system AppProject resources).
  helm_install gitops-platform gitops-platform "$PLATFORM_NAMESPACE"
}

# ----------------------------------------------------------------------------
# Install workload charts
# ----------------------------------------------------------------------------
install_workload_components() {

  get_minikube_tenant_profiles | while read -r profile; do
    helm_install baseline-workload baseline-workload "default" "$profile"
    helm_install external-secrets external-secrets "$PLATFORM_NAMESPACE" "$profile"
  done

}


# ----------------------------------------------------------------------------
# credentials
# ----------------------------------------------------------------------------
fetch_credentials() {
  echo ""
  echo "🔐 Fetching credentials..."

  # -----------------------------
  # Argo CD admin password
  # -----------------------------

  until kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret >/dev/null 2>&1; do
    sleep 2
  done

  ARGOCD_ADMIN_PASSWORD=$(
    kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" | base64 -d
  )

  # -----------------------------
  # Vault root token
  # -----------------------------

  kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=vault \
    -n "$VAULT_NAMESPACE" \
    --timeout=180s

  VAULT_POD=$(kubectl get pods -n "$VAULT_NAMESPACE" \
    -l app.kubernetes.io/name=vault \
    -o jsonpath='{.items[0].metadata.name}')

  VAULT_ROOT_TOKEN=$(
    kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
      sh -c "grep 'Initial Root Token:' /vault/data/init.txt | awk '{print \$4}'"
  )

  # ----------------------------------------------------------------------------
  # Write credentials to local .env file
  # ----------------------------------------------------------------------------

  CREDS_FILE="$REPO_ROOT/.platform.env"

  cat > "$CREDS_FILE" <<EOF
# ------------------------------------------------------------------
# 🚨 AUTO-GENERATED FILE — DO NOT COMMIT
# Run: source .platform.env
# ------------------------------------------------------------------

export ARGOCD_ADMIN_PASSWORD="$ARGOCD_ADMIN_PASSWORD"
export VAULT_ROOT_TOKEN="$VAULT_ROOT_TOKEN"
EOF

  chmod 600 "$CREDS_FILE"

  echo ""
  echo "✅ Credentials saved to:"
  echo "   $CREDS_FILE"
  echo ""
  echo "Next step:"
  echo "   source .platform.env"
  echo ""
}

main() {
  echo "------------ Gateway API ------------"
  install_gateway_api

  echo "------------ CRDs -------------------"
  install_crds

  echo "-------- Platform components --------"
  install_platform_components

  echo "------- Workload components ---------"
  install_workload_components

  echo "------------ Credentials ------------"
  fetch_credentials
}

main "$@"
