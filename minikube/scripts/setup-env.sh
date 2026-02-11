#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# Install cloudflared
# ----------------------------------------------------------------------------

echo "🔍 Checking Cloudflare CLI..."

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "📦 Installing cloudflared using official Cloudflare apt repository..."

  # Detect Ubuntu/Debian codename automatically (e.g., noble, jammy, focal)
  CODENAME=$(lsb_release -cs)

  # Add Cloudflare GPG key and apt repository
  sudo mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list

  # Install cloudflared
  sudo apt-get update -y
  sudo apt-get install -y cloudflared

  echo "✅ cloudflared installed successfully."
else
  echo "✅ cloudflared already installed."
fi

echo "ℹ️ Quick Tunnels do not require login or Cloudflare account authentication."
echo "✅ cloudflared is ready to create temporary public tunnels (trycloudflare.com)."

# ----------------------------------------------------------------------------
# Generate certs
# ----------------------------------------------------------------------------

echo "🔐 Generating full TLS chain with SAN extensions..."

mkdir -p .certs

# ------------------------------------------------------------------------------
# 1. ROOT CA
# ------------------------------------------------------------------------------
echo "📌 Generating Root CA..."
openssl req -x509 -new -nodes -days 3650 -newkey rsa:4096 \
  -keyout .certs/rootCA.key -out .certs/rootCA.crt \
  -subj "/CN=Local Root CA/O=Dev" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"

# ------------------------------------------------------------------------------
# 2. GATEWAY CERT (Browser → Gateway)
#    Hostname = argocd.local
# ------------------------------------------------------------------------------
echo "📌 Generating Gateway certificate..."
cat > .certs/gateway-san.cnf <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[dn]
CN = argocd.local

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = argocd.local
DNS.3 = *.trycloudflare.com
EOF

openssl req -new -nodes \
  -keyout .certs/gateway.key \
  -out .certs/gateway.csr \
  -config .certs/gateway-san.cnf

openssl x509 -req -in .certs/gateway.csr \
  -CA .certs/rootCA.crt -CAkey .certs/rootCA.key \
  -CAcreateserial -days 365 \
  -out .certs/gateway.crt \
  -extfile .certs/gateway-san.cnf \
  -extensions req_ext

# ------------------------------------------------------------------------------
# 3. BACKEND CERT (Gateway → ArgoCD)
#    MUST match ArgoCD service DNS:
#       argocd-server.argocd.svc.cluster.local
# ------------------------------------------------------------------------------
echo "📌 Generating ArgoCD backend TLS certificate..."
cat > .certs/argocd-san.cnf <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[dn]
CN = argocd-server.argocd.svc.cluster.local

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = argocd-server.argocd.svc.cluster.local
EOF

openssl req -new -nodes \
  -keyout .certs/argocd.key \
  -out .certs/argocd.csr \
  -config .certs/argocd-san.cnf

openssl x509 -req -in .certs/argocd.csr \
  -CA .certs/rootCA.crt -CAkey .certs/rootCA.key \
  -CAcreateserial -days 365 \
  -out .certs/argocd.crt \
  -extfile .certs/argocd-san.cnf \
  -extensions req_ext

# ------------------------------------------------------------------------------
# 4. GATEWAY CERT (Browser → Gateway)
#    Hostname = vault.local
# ------------------------------------------------------------------------------
echo "📌 Generating Vault Gateway certificate..."
cat > .certs/gateway-vault-san.cnf <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[dn]
CN = vault.local

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = vault.local
DNS.3 = *.trycloudflare.com
EOF

openssl req -new -nodes \
  -keyout .certs/gateway-vault.key \
  -out .certs/gateway-vault.csr \
  -config .certs/gateway-vault-san.cnf

openssl x509 -req -in .certs/gateway-vault.csr \
  -CA .certs/rootCA.crt -CAkey .certs/rootCA.key \
  -CAcreateserial -days 365 \
  -out .certs/gateway-vault.crt \
  -extfile .certs/gateway-vault-san.cnf \
  -extensions req_ext

# ------------------------------------------------------------------------------
# 5. VAULT (Gateway → Vault)
#    MUST match Vault service DNS:
#       vault.vault.svc.cluster.local
# ------------------------------------------------------------------------------

echo "📌 Generating Vault TLS certificate..."
cat > .certs/vault-san.cnf <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[dn]
CN = vault.vault.svc.cluster.local

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = vault.vault.svc.cluster.local
EOF

openssl req -new -nodes \
  -keyout .certs/vault.key \
  -out .certs/vault.csr \
  -config .certs/vault-san.cnf

openssl x509 -req -in .certs/vault.csr \
  -CA .certs/rootCA.crt -CAkey .certs/rootCA.key \
  -CAcreateserial -days 365 \
  -out .certs/vault.crt \
  -extfile .certs/vault-san.cnf \
  -extensions req_ext

echo "✅ All certificates generated successfully!"
echo "📁 Location: ./certs"
