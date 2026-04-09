#!/usr/bin/env bash
set -euo pipefail

# Compute repo root dynamically 
# Returns absolute path to script location, in my case it's '/home/kara/github/r-karamad/kubepave/src/bootstrap/minikube'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Go three folders up from where the script lives, and give me that absolute path.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# Where kubectl plugins are placed
KUBECTL_PLUGIN_DIR="$REPO_ROOT/src/kubectl-plugins"

# -----------------------------------------------------------------------------
# Discover tenant clusters dynamically.
# "minikube-management" = management cluster (tunnel only)
# other "minikube-*" profiles = tenants (proxies + Argo CD cluster registration)
# -----------------------------------------------------------------------------

MANAGEMENT_PROFILE="minikube-management"
KEYCLOAK_ADMIN_USER="admin"
KEYCLOAK_ADMIN_PASSWORD=""
PLATFORM_NAMESPACE="platform-system"

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

# ----------------------------------------------------------------------------
# Networking
# ----------------------------------------------------------------------------

start_minikube_tunnel() {
  echo "🔌 Ensuring minikube tunnels are running..."

  get_minikube_profiles | while IFS= read -r profile; do
    if ! pgrep -f "minikube tunnel -p $profile" >/dev/null; then
      echo "➡️  Starting tunnel for $profile"
      minikube tunnel -p "$profile" >/dev/null 2>&1 &
      sleep 3
    else
      echo "✅ Tunnel already running for $profile"
    fi
  done
}

update_hosts() {

  echo "⚙️  Updating /etc/hosts (requires sudo privileges)"

  # Wait for LoadBalancer IP
  while true; do
    LB_IP=$(kubectl get svc traefik-mgmt \
      -n "$PLATFORM_NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

    [[ -n "$LB_IP" ]] && break
    sleep 2
  done

  sudo cp /etc/hosts /etc/hosts.bak
  sudo sed -i.bak '/rezakara.demo/d' /etc/hosts

  {
    echo "$LB_IP argocd.mgmt.rezakara.demo"
    echo "$LB_IP vault.mgmt.rezakara.demo"
    echo "$LB_IP oidc.mgmt.rezakara.demo"
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

  export VAULT_ADDR="https://vault.mgmt.rezakara.demo"
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

register_clusters_argocd() {
  echo "🔐 Writing Argo CD clusters credentials..."

  get_minikube_tenant_profiles | while IFS= read -r profile; do
    IP=$(minikube ip -p "$profile")
    SERVER="https://${IP}:8443"

    echo "🚀 Registering cluster $profile → $SERVER"

    # Create ServiceAccount for Argo CD cluster access
    kubectl --context "$profile" create serviceaccount argocd-manager -n kube-system 2>/dev/null || true

    # Grant cluster-admin privileges to the ServiceAccount
    kubectl --context "$profile" create clusterrolebinding argocd-manager \
      --clusterrole=cluster-admin \
      --serviceaccount=kube-system:argocd-manager 2>/dev/null || true

    # The command below creates a short-lived ServiceAccount token.
    # This becomes problematic because the token expires and must be
    # manually renewed and reconfigured in Argo CD.
    # TOKEN=$(kubectl --context "$profile" -n kube-system create token argocd-manager)

    # Create a legacy ServiceAccount token secret for a long-lived token
    kubectl --context "$profile" -n kube-system apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

    # Wait until Kubernetes populates the token in the secret
    until kubectl --context "$profile" -n kube-system get secret argocd-manager-token \
      -o jsonpath='{.data.token}' 2>/dev/null | grep -q .; do
      sleep 1
    done

    # Read the legacy long-lived ServiceAccount token from the secret instead of using
    # TokenRequest-generated tokens. This prevents expiration issues with Argo CD in
    # this local environment. Static SA tokens are not recommended for production use.
    TOKEN=$(kubectl --context "$profile" -n kube-system get secret argocd-manager-token \
      -o jsonpath='{.data.token}' | base64 -d)

    echo "🔑 Storing credentials for $profile in Vault"
    vault kv put local/management/argocd/clusters/"$profile" \
      server="$SERVER" \
      token="$TOKEN"

    echo "✅ Credentials for $profile written to Vault"

  done

  echo "🎉 All Argo CD cluster credentials stored in Vault"
}

# ----------------------------------------------------------------------------
# Keycloak credentials
# ----------------------------------------------------------------------------

create_keycloak_azure_secret_management_realm() {
  echo "🔐 Writing Entra ID App secret..."

  VAULT_PATH="local/management/keycloak/azure/apps/rezakara-keycloak-management-idp"

  CLIENT_SECRET=$(pass show private/azure/entra-id/apps/keycloak/client-secrets/rezakara-keycloak-management-idp/value | head -n1)
  CLIENT_ID=$(pass show private/azure/entra-id/apps/keycloak/client-id | head -n1)

  if [[ -z "$CLIENT_SECRET" ]]; then
    echo "❌ Failed to read client secret from pass."
    return 1
  fi

  vault kv put "$VAULT_PATH" \
    client_id="$CLIENT_ID" \
    client_secret="$CLIENT_SECRET"

  echo "✅ Entra ID client secret stored in Vault"
}

create_keycloak_bootstrap_secret() {
  BOOTSTRAP_USERNAME="admin"
  echo "🔐 Generating Keycloak $BOOTSTRAP_USERNAME credentials..."

  VAULT_PATH="local/management/keycloak/bootstrap"

  if vault kv get "$VAULT_PATH" >/dev/null 2>&1; then
    echo "⚠️  Bootstrap user already exists. Skipping."
    return
  fi

  BOOTSTRAP_PASSWORD="$(openssl rand -hex 16)"

  vault kv put "$VAULT_PATH" \
    username="$BOOTSTRAP_USERNAME" \
    password="$BOOTSTRAP_PASSWORD" \
    disabled=0 > /dev/null

  echo "✅ Keycloak bootstrap credentials stored in Vault"
}

create_keycloak_administrator_secret() {
  ADMINISTRATOR_USERNAME="administrator"
  echo "🔐 Generating Keycloak $ADMINISTRATOR_USERNAME credentials..."

  VAULT_PATH="local/management/keycloak/administrator"

  if vault kv get "$VAULT_PATH" >/dev/null 2>&1; then
    echo "⚠️  Administrator user already exists. Skipping."
    return
  fi

  ADMINISTRATOR_PASSWORD="$(openssl rand -hex 16)"

  vault kv put "$VAULT_PATH" \
    username="$ADMINISTRATOR_USERNAME" \
    password="$ADMINISTRATOR_PASSWORD" > /dev/null

  echo "✅ Keycloak administrator credentials stored in Vault"
}

trust_self_signed_ca_certificate() {
  BASE_DIR="$HOME/.local/share/rezakara"
  CA_FILE="$BASE_DIR/ca.crt"
  CERT_FILE="$BASE_DIR/tls.crt"
  KEY_FILE="$BASE_DIR/tls.key"

  JAVA_ALIAS="rezakara-root-ca"
  TRUSTSTORE="$BASE_DIR/java-truststore.jks"
  TRUSTSTORE_PASS="changeit"

  NSS_DIR="$HOME/.pki/nssdb"
  NSS_DB="sql:$NSS_DIR"
  NSS_NAME="RezaKara Root CA"
  NSS_PWFILE="$NSS_DIR/.nss-pwfile"

  SYS_CA_FILE="/usr/local/share/ca-certificates/rezakara-demo.crt"
  KEYCLOAK_HOST="oidc.mgmt.rezakara.demo"

  mkdir -p "$BASE_DIR"

  echo "🔎 Checking ClusterSecretStore readiness..."

  READY=$(kubectl get clustersecretstore vault-local -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

  if [[ "$READY" != "True" ]]; then
    echo "❌ ClusterSecretStore 'vault-local' is not ready"
    kubectl get clustersecretstore vault-local
    exit 1
  fi

  echo "✅ ClusterSecretStore is ready"

  echo "📥 Pull certificates from Vault"

  vault kv get -field=ca.crt local/management/pki > "$CA_FILE"
  vault kv get -field=tls.crt local/management/pki > "$CERT_FILE"
  vault kv get -field=tls.key local/management/pki > "$KEY_FILE"

  chmod 600 "$KEY_FILE"

  echo "📜 Verify certificate files"

  if ! openssl x509 -in "$CA_FILE" -noout >/dev/null 2>&1; then
    echo "❌ Invalid CA certificate returned from Vault"
    exit 1
  fi

  if ! openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1; then
    echo "❌ Invalid TLS certificate returned from Vault"
    exit 1
  fi

  if ! openssl rsa -in "$KEY_FILE" -check -noout >/dev/null 2>&1; then
    echo "❌ Invalid TLS key returned from Vault"
    exit 1
  fi

  echo "🏛️  Verify certificate is a CA"

  if ! openssl x509 -in "$CA_FILE" -noout -ext basicConstraints 2>/dev/null | grep -qi 'CA:TRUE'; then
    echo "❌ Certificate is not a CA"
    openssl x509 -in "$CA_FILE" -noout -subject -issuer || true
    openssl x509 -in "$CA_FILE" -noout -ext basicConstraints || true
    exit 1
  fi

  echo "🟢 Certificate is a CA"

  echo "🔍 Verify CA self-signature"

  if ! openssl verify -CAfile "$CA_FILE" "$CA_FILE" >/dev/null 2>&1; then
    echo "❌ CA self-verification failed"
    exit 1
  fi

  echo "🟢 CA self-verification passed"

  echo "🔍 Verify CA signs $KEYCLOAK_HOST"

  if ! timeout 8 openssl s_client \
        -connect "${KEYCLOAK_HOST}:443" \
        -servername "$KEYCLOAK_HOST" \
        -CAfile "$CA_FILE" \
        -verify_return_error \
        </dev/null >/dev/null 2>&1
  then
    echo "❌ CA does NOT sign the server certificate!"
    echo "Possible causes:"
    echo "  - Wrong secret pushed to Vault"
    echo "  - cert-manager CA rotated"
    echo "  - Wrong hostname"
    echo "  - minikube tunnel not running / wrong /etc/hosts"
    exit 1
  fi

  echo "🟢 CA correctly signs the server certificate"

  echo "☕ Update Java truststore"

  keytool -delete -alias "$JAVA_ALIAS" \
    -keystore "$TRUSTSTORE" \
    -storepass "$TRUSTSTORE_PASS" 2>/dev/null || true

  keytool -importcert \
    -alias "$JAVA_ALIAS" \
    -file "$CA_FILE" \
    -keystore "$TRUSTSTORE" \
    -storepass "$TRUSTSTORE_PASS" \
    -noprompt

  keytool -list -v \
    -keystore "$TRUSTSTORE" \
    -storepass "$TRUSTSTORE_PASS" \
    -alias "$JAVA_ALIAS" | egrep "Owner:|Issuer:|SHA256:|BasicConstraints"

  echo "🟢 Java truststore updated"

  echo "🌐 Update browser trust"

  mkdir -p "$NSS_DIR"
  : > "$NSS_PWFILE"
  chmod 600 "$NSS_PWFILE"

  if [ ! -f "$NSS_DIR/cert9.db" ]; then
    certutil -d "$NSS_DB" -N --empty-password 2>/dev/null || true
  fi

  certutil -d "$NSS_DB" -D -n "$NSS_NAME" -f "$NSS_PWFILE" 2>/dev/null || true
  certutil -d "$NSS_DB" -A -t "C,," -n "$NSS_NAME" -i "$CA_FILE" -f "$NSS_PWFILE"

  echo "🟢 Browser CA updated (restart browser)"

  echo "🔐 Update system trust store"

  sudo install -m 0644 "$CA_FILE" "$SYS_CA_FILE"
  sudo update-ca-certificates --fresh >/dev/null 2>&1 || true

  if [[ ! -f "$SYS_CA_FILE" ]]; then
    echo "❌ Failed to install CA into system trust directory"
    exit 1
  fi

  echo "🟢 System trust files updated"

  export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$TRUSTSTORE -Djavax.net.ssl.trustStorePassword=$TRUSTSTORE_PASS"

  echo
  echo "✅ All trust stores refreshed successfully"
  echo "To persist across shells run:"
  echo "echo 'export JAVA_TOOL_OPTIONS=\"$JAVA_TOOL_OPTIONS\"' >> ~/.bashrc"

  echo "🌐 Seeding CA trust into workload clusters..."

  get_minikube_tenant_profiles | while IFS= read -r profile; do
    echo "➡️  Bootstrap trust into $profile"

    kubectl --context "$profile" -n "$PLATFORM_NAMESPACE" create secret generic root-ca \
      --from-file=ca.crt="$CA_FILE" \
      --from-file=tls.crt="$CERT_FILE" \
      --from-file=tls.key="$KEY_FILE" \
      --dry-run=client -o yaml \
    | kubectl --context "$profile" apply -f -
  done

  echo "🔐 Root CA secret distributed to workload clusters."
}

# ----------------------------------------------------------------------------
# Crossplane credential in Azure
# ----------------------------------------------------------------------------

create_crossplane_azure_secret() {
  echo "🔐 Writing Entra ID App secret..."

  VAULT_PATH="local/management/crossplane/azure/apps/rezakara-crossplane"

  CLIENT_SECRET=$(pass show private/azure/entra-id/apps/crossplane/client-secrets/rezakara-crossplane/value | head -n1)
  CLIENT_ID=$(pass show private/azure/entra-id/apps/crossplane/client-id | head -n1)
  TENANT_ID=$(pass show private/azure/entra-id/apps/crossplane/tenant-id | head -n1)

  if [[ -z "$CLIENT_SECRET" ]]; then
    echo "❌ Failed to read client secret from pass."
    return 1
  fi

  vault kv put "$VAULT_PATH" \
    client_id="$CLIENT_ID" \
    tenant_id="$TENANT_ID" \
    client_secret="$CLIENT_SECRET"

  echo "✅ Entra ID client secret stored in Vault"
}

# ----------------------------------------------------------------------------
# kubectl plugins
# ----------------------------------------------------------------------------
install_kubectl_plugins() {
  echo "🚀 Installing kubectl plugins from $KUBECTL_PLUGIN_DIR"

  for dir in "$KUBECTL_PLUGIN_DIR"/*/; do
    [ -f "$dir/go.mod" ] || continue

    name="$(basename "$dir")"
    binary="kubectl-$name"
    binary_path="$dir/$binary"

    echo "⚙️  Building plugin: $name"
    go build -C "$dir" -o "$binary_path"

    echo "📦 Installing $binary -> /usr/local/bin"
    sudo install -m 0755 "$binary_path" /usr/local/bin/"$binary"

    rm -f "$binary_path"

    echo "✅ Installed kubectl $name"
  done

  echo "🎉 All kubectl plugins installed."
  echo "🔍 Available plugins:"
  kubectl plugin list || true
}

# ----------------------------------------------------------------------------
# TSIG secret for external-dns (RFC2136)
# ----------------------------------------------------------------------------

create_external_dns_tsig_secret() {
  echo "🔐 Generating TSIG secret for external-dns..."

  VAULT_PATH="local/management/external-dns/rfc2136"

  # Check if secret already exists (idempotency)
  if vault kv get "$VAULT_PATH" >/dev/null 2>&1; then
    echo "⚠️  TSIG secret already exists in Vault. Skipping generation."
    return
  fi

  # Generate secure base64 secret (compatible with BIND + external-dns)
  TSIG_SECRET="$(openssl rand -base64 32)"

  vault kv put "$VAULT_PATH" \
    tsig_key_name="externaldns-key" \
    tsig_secret="$TSIG_SECRET" \
    algorithm="hmac-sha256" > /dev/null

  echo "✅ TSIG secret stored in Vault at $VAULT_PATH"
}

# ----------------------------------------------------------------------------
# TSIG secret for external-dns (RFC2136)
# ----------------------------------------------------------------------------

create_powerdns_secrets() {
  VAULT_BASE_PATH="local/powerdns"
  VAULT_DB_PATH="$VAULT_BASE_PATH/db"
  VAULT_API_PATH="$VAULT_BASE_PATH/api"

  POSTGRES_USER="pdns"

  echo "🔐 Generating and storing secrets for PowerDNS..."

  POSTGRES_PASSWORD="$(openssl rand -hex 32)"
  POWERDNS_API_KEY="$(openssl rand -hex 32)"
  POWERDNS_ADMIN_PASSWORD="$(openssl rand -hex 32)"

  vault kv put "$VAULT_DB_PATH" \
      user="$POSTGRES_USER" \
      password="$POSTGRES_PASSWORD" > /dev/null

  vault kv put "$VAULT_API_PATH" \
      key="$POWERDNS_API_KEY" > /dev/null

  echo "✅ Secrets stored in Vault"
}

configure_resolved() {
  echo "Backing up existing config..."
  sudo cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak.$(date +%s)

  echo "Applying new DNS config..."

  sudo tee /etc/systemd/resolved.conf > /dev/null <<EOF
[Resolve]
DNSStubListener=no
DNS=127.0.0.1
FallbackDNS=8.8.8.8 1.1.1.1
Domains=~demo
EOF

  echo "Restarting systemd-resolved..."
  sudo systemctl restart systemd-resolved

  echo "Verifying..."
  resolvectl status | grep -E "DNS Servers|DNS Domain"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
  start_minikube_tunnel
  # Updating /etc/hosts is necessary for bootstrapping because the management cluster's Traefik LoadBalancer IP is dynamic 
  # and must be resolved to access Argo CD, Vault, and Keycloak during setup. 
  # Also it's needed to ensure that the self-signed certificate issued for *.mgmt.rezakara.demo is trusted and matches the hostname used to access the services.
  # After bootstrapping, it will be cleaned up and DNS requestes will be responded by the local PowerDNS instance.
  update_hosts
  configure_resolved
  vault_login
  create_github_app_secret
  register_clusters_argocd
  create_keycloak_azure_secret_management_realm
  create_keycloak_bootstrap_secret
  create_keycloak_administrator_secret
  trust_self_signed_ca_certificate
  create_crossplane_azure_secret
  install_kubectl_plugins
  create_external_dns_tsig_secret
  create_powerdns_secrets

  echo "✅ Bootstrap complete"
}

main "$@"