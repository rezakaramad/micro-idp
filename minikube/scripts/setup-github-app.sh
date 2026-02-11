#!/usr/bin/env bash
set -euo pipefail

# Below is the way I organized the credentials for the GitHub App:
# private/github/apps/rezakaramad-argocd
# ├── app-id
# ├── client-id
# ├── installation-id
# └── private-key

echo "🔐 Fetching the GitHub App credentials from passwordstore (https://www.passwordstore.org/)..."
GITHUB_APP_PATH="private/github/apps/rezakaramad-argocd"
export GITHUB_APP_ID
GITHUB_APP_ID="$(pass show "${GITHUB_APP_PATH}/app-id")"
export GITHUB_APP_INSTALLATION_ID
GITHUB_APP_INSTALLATION_ID="$(pass show "${GITHUB_APP_PATH}/installation-id")"
RAW_KEY="$(pass show "${GITHUB_APP_PATH}/private-key")"
export GITHUB_APP_PRIVATE_KEY
GITHUB_APP_PRIVATE_KEY="$(printf '%s\n' "${RAW_KEY}" | sed 's/^/    /')"

echo "📡 Creating GitHub App Secret..."
envsubst <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: github-app
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
type: Opaque
stringData:
  url: https://github.com/rezakaramad
  githubAppID: "${GITHUB_APP_ID}"
  githubAppInstallationID: "${GITHUB_APP_INSTALLATION_ID}"
  githubAppPrivateKey: |
${GITHUB_APP_PRIVATE_KEY}
YAML

echo "✅ Secret applied."

echo "🎉 GitHub App ready!"
