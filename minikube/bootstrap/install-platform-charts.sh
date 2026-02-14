#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Bootstrapping core platform charts..."

# Compute repo root dynamically 
# Returns absolute path to script location, in my case it's '/home/kara/github/r-karamad/micro-idp/minikube/bootstrap'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Go two folders up from where the script lives, and give me that absolute path.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Absolute path to 'charts/'' directory
CHARTS_DIR="$REPO_ROOT/charts"

# Specify platform components namespaces
PLATFORM_NAMESPACE="platform-resources"
VAULT_NAMESPACE="vault"
ARGOCD_NAMESPACE="argocd"

# -----------------------------------------------------------------------------
# helm_install — Small wrapper around `helm upgrade --install`
#
# Usage:
#   helm_install <release> <chart> <namespace> [extra helm args...]
#
# Examples:
#   helm_install cert-manager cert-manager platform-resources
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
  # Remove first 3 args so "$@" contains only extra Helm flags (if any)
  # Example:
  #   before: name chart ns -f values.yaml
  #   after : -f values.yaml
  shift 3

  echo ""
  echo "📦 Installing $name → namespace: $namespace"
  
  helm upgrade --install "$name" "$CHARTS_DIR/$chart" \
    -n "$namespace" \
    --timeout 10m \
    "$@" # Forward any additional Helm arguments
}


echo "🚀 Bootstrapping core platform..."

# ----------------------------------------------------------------------------
# Install Kubernetes Gateway API
# ----------------------------------------------------------------------------

echo "🚀 Installing Kubernetes Gateway API (CRDs + Standard controller)..."

# Step 1: install Gateway API CRDs
echo "📦 Applying official Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml

# Optional: wait until CRDs are registered
echo "⏳ Waiting for CRDs to be established..."
kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=60s

# Step 3: confirm installation
echo "✅ Gateway API CRDs installed:"
kubectl get crds | grep gateway.networking.k8s.io || true

echo "🎉 Gateway API successfully installed on Minikube."

echo "⏳ Waiting for cluster networking..."

kubectl wait --for=condition=Ready nodes --all --timeout=120s
kubectl wait --for=condition=Available deployment/coredns -n kube-system --timeout=120s
kubectl wait --for=condition=Available deployment/kube-proxy -n kube-system --timeout=120s 2>/dev/null || true

# ----------------------------------------------------------------------------
# Install core components
# ----------------------------------------------------------------------------

# Install external-secrets CRDs
CHART_PATH="$CHARTS_DIR/external-secrets"
CHART_VERSION=$(yq '.dependencies[] | select(.name=="external-secrets") | .version' $CHART_PATH/Chart.yaml)

mkdir -p $CHART_PATH/crds
curl -L \
  -o $CHART_PATH/crds/bundle.yaml \
  https://raw.githubusercontent.com/external-secrets/external-secrets/refs/tags/v$CHART_VERSION/deploy/crds/bundle.yaml

kubectl apply --server-side -f $CHART_PATH/crds/bundle.yaml

# Install cert-manager CRDs
CHART_PATH="$CHARTS_DIR/cert-manager"
CHART_VERSION=$(yq '.dependencies[] | select(.name=="cert-manager") | .version' $CHART_PATH/Chart.yaml)

mkdir -p $CHART_PATH/crds
curl -fsSL \
  https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/acme.cert-manager.io_challenges.yaml \
  https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/acme.cert-manager.io_orders.yaml \
  https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/cert-manager.io_certificaterequests.yaml \
  https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/cert-manager.io_certificates.yaml \
  https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/cert-manager.io_clusterissuers.yaml \
  https://raw.githubusercontent.com/cert-manager/cert-manager/refs/tags/v$CHART_VERSION/deploy/crds/cert-manager.io_issuers.yaml \
  > "$CHART_PATH/crds/bundle.yaml"

kubectl apply --server-side -f $CHART_PATH/crds/bundle.yaml

# Install keycloak-operator CRDs
CHART_PATH="$CHARTS_DIR/keycloak-operator"
CHART_VERSION=$(yq '.appVersion' $CHART_PATH/Chart.yaml)

mkdir -p "$CHART_PATH/crds"
curl -fsSL \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$CHART_VERSION/kubernetes/keycloaks.k8s.keycloak.org-v1.yml" \
  -o "$CHART_PATH/crds/keycloaks.k8s.keycloak.org.yaml"

curl -fsSL \
  "https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$CHART_VERSION/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml" \
  -o "$CHART_PATH/crds/keycloakrealmimports.k8s.keycloak.org.yaml"

kubectl apply --server-side -f "$CHART_PATH/crds/"

# Install charts
helm_install platform-scaffold platform-scaffold default \
  -f $CHARTS_DIR/platform-scaffold/values-management.yaml
helm_install cert-manager cert-manager "$PLATFORM_NAMESPACE"
helm_install vault vault "$VAULT_NAMESPACE"
helm_install external-secrets external-secrets "$PLATFORM_NAMESPACE"
helm_install traefik traefik "$PLATFORM_NAMESPACE"

# Argo CD has dependancy to all the above services and controllers, 
# therefore we need to make sure that those are up and running before deploying Argo CD.
echo "⏳ Waiting for platform controllers to be ready..."

kubectl wait --for=condition=Available deployment \
  -l app.kubernetes.io/name=cert-manager \
  -n "$PLATFORM_NAMESPACE" \
  --timeout=180s

kubectl wait --for=condition=Available deployment \
  -l app.kubernetes.io/name=external-secrets \
  -n "$PLATFORM_NAMESPACE" \
  --timeout=180s

kubectl wait \
  --for=condition=Available deployment \
  -l app.kubernetes.io/component=webhook \
  -n "$PLATFORM_NAMESPACE" \
  --timeout=180s

kubectl wait --for=condition=Available deployment \
  -l app.kubernetes.io/name=traefik \
  -n "$PLATFORM_NAMESPACE" \
  --timeout=180s

helm_install argocd argocd "$ARGOCD_NAMESPACE"

echo "⏳ Waiting for external-secrets webhook..."

kubectl wait \
  --for=condition=Available deployment/external-secrets-webhook \
  -n "$PLATFORM_NAMESPACE" \
  --timeout=180s

helm_install platform-global platform-global "default"

helm_install platform-management platform-management "$PLATFORM_NAMESPACE"

# ----------------------------------------------------------------------------
# credentials
# ----------------------------------------------------------------------------

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

CREDS_FILE="$REPO_ROOT/.platform-creds.env"

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
echo "Tip: add this file to .gitignore if not already:"
echo "   .platform-creds.env"
