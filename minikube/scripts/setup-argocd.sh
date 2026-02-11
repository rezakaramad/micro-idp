#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="argocd"
RELEASE_NAME="argocd"
CHART_PATH="../charts/argocd"

echo "📁 Ensuring namespace 'argocd' exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "🗑️ Removing old TLS secret if present..."
kubectl -n argocd delete secret gateway-tls --ignore-not-found
kubectl -n argocd delete secret argocd-server-tls --ignore-not-found
kubectl -n argocd delete configmap argocd-ca --ignore-not-found

echo "🔐 Creating new TLS secret"
# Client ⇆ Gateway (TLS)
kubectl -n kube-system create secret tls gateway-tls \
  --cert=.certs/gateway.crt --key=.certs/gateway.key
# Gateway ⇆ Argo CD Server
kubectl -n argocd create secret tls argocd-server-tls \
  --cert=.certs/argocd.crt --key=.certs/argocd.key
kubectl -n argocd create configmap argocd-ca \
  --from-file=ca.crt=.certs/rootCA.crt

echo "✅ Certificate chain ready."

echo "📦 Building Helm chart dependencies..."
helm dependency update "$CHART_PATH"

echo "🚀 Installing or upgrading Argo CD (release: $RELEASE_NAME)..."
helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  --wait

echo "📡 Creating the root application..."
kubectl apply -f - <<'EOF'
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gitops-builder
  namespace: argocd
  labels:
    cluster: minikube
    app: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/rezakaramad/charts
    targetRevision: main
    path: charts/gitops-builder
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    syncOptions:
    - ApplyOutOfSyncOnly=true 
EOF
echo "✅ Root Application applied."

echo "🎉 Argo CD installed."
