#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Discover tenant clusters dynamically.
# "minikube-management" = management cluster (tunnel only)
# other "minikube-*" profiles = tenants (proxies + Argo CD cluster registration)
# -----------------------------------------------------------------------------

MANAGEMENT_PROFILE="minikube-management"
KEYCLOAK_ADMIN_USER="admin"
KEYCLOAK_ADMIN_PASSWORD=""

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

create_keycloak_azure_secret_management_realm() {
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
  BASE_DIR="$HOME/.local/share/fluxdojo"
  CA_FILE="$BASE_DIR/root-ca.crt"
  JAVA_ALIAS="fluxdojo-root-ca"
  TRUSTSTORE="$BASE_DIR/java-truststore.jks"
  TRUSTSTORE_PASS="changeit"
  NSS_DIR=$HOME/.pki/nssdb
  NSS_DB="sql:$NSS_DIR"
  NSS_NAME="Fluxdojo Root CA"
  NSS_PWFILE="$NSS_DIR/.nss-pwfile"
  SYS_CA_FILE="/usr/local/share/ca-certificates/fluxdojo-local.crt"
  KEYCLOAK_HOST="oidc.fluxdojo.local"

  mkdir -p "$BASE_DIR"

  echo "📥 Pull CA from Vault"
  vault kv get -field=ca.crt local/management/pki > "$CA_FILE"

  # ----- Validate certificate file -----
  echo "📜 Verify certificate file"
  if ! openssl x509 -in "$CA_FILE" -noout >/dev/null 2>&1; then
    echo "❌ Vault did not return a valid certificate (login expired?)"
    exit 1
  fi

  echo "🏛️ Verify certificate is a CA"
  if ! openssl x509 -in "$CA_FILE" -noout -ext basicConstraints 2>/dev/null | grep -qi 'CA:TRUE'; then
    echo "❌ Certificate is not a CA (BasicConstraints is not CA:TRUE)"
    openssl x509 -in "$CA_FILE" -noout -subject -issuer || true
    openssl x509 -in "$CA_FILE" -noout -ext basicConstraints || true
    exit 1
  fi
  echo "🟢 Certificate is a CA"

  # ----- Verify CA -----
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

  # ----- Java truststore -----
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

  # ----- Browser NSS trust -----
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

  # ----- System trust -----
  echo "🔐 Update system trust store"
  sudo rm -f "$SYS_CA_FILE"
  sudo cp "$CA_FILE" "$SYS_CA_FILE"
  sudo update-ca-certificates --fresh >/dev/null 2>&1 || true
  openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$CA_FILE"

  export JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=$TRUSTSTORE -Djavax.net.ssl.trustStorePassword=$TRUSTSTORE_PASS"

  echo
  echo "✅ All trust stores refreshed successfully"
  echo "To persist across shells run:"
  echo "echo 'export JAVA_TOOL_OPTIONS=\"$JAVA_TOOL_OPTIONS\"' >> ~/.bashrc"
}

create_keycloak_client_crossplane (){
  CLIENT_ID="crossplane-admin"
  REALM="master"
  VAULT_PATH="local/management/pki"

  echo "🔐 Authenticate to Keycloak"
  kcadm.sh config credentials \
          --server https://oidc.fluxdojo.local \
          --realm "$REALM" \
          --user admin \
          --password "3b8a4a178a3faf4892d1b6581642a3be"

  echo "🔎 Check if client exists"
  CID=$(kcadm.sh get clients \
    -r "$REALM" \
    -q clientId="$CLIENT_ID" \
    --fields id \
    --format csv --noquotes | head -n1)

  if [[ -z "$CID" ]]; then
    echo "➕ Create client $CLIENT_ID"

    kcadm.sh create clients \
      -r "$REALM" \
      -s "clientId=$CLIENT_ID" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s serviceAccountsEnabled=true \
      -s standardFlowEnabled=false \
      -s directAccessGrantsEnabled=false

    # Wait until client appears
    for i in {1..20}; do
      CID=$(kcadm.sh get clients \
        -r "$REALM" \
        -q clientId="$CLIENT_ID" \
        --fields id \
        --format csv \
        --noquotes | head -n1)
      if [[ -n "$CID" ]]; then
        SA_UID=$(kcadm.sh get "clients/$CID/service-account-user" \
          -r "$REALM" \
          --fields id \
          --format csv \
          --noquotes 2>/dev/null || true)
        [[ -n "$SA_UID" ]] && break
      fi
      sleep 1
    done
  else
    echo "🤷 Client already exists"
  fi

  if [[ -z "$CID" ]]; then
    echo "🛑 Failed to resolve client ID"
    exit 1
  fi

  # ---- Resolve service account ----
  echo "🔎 Resolve service account"
  SA_UID=$(kcadm.sh get "clients/$CID/service-account-user" \
    -r "$REALM" \
    --fields id \
    --format csv --noquotes)

  if [[ -z "$SA_UID" ]]; then
    echo "🛑 Failed to resolve service account user"
    exit 1
  fi

  echo "Service account UID: $SA_UID"

  # Grant admin role (idempotent) ----
  echo "🛡️ Ensure admin role"
  HAS_ADMIN=$(kcadm.sh get-roles \
    -r "$REALM" \
    --uid "$SA_UID" \
    | jq -r '.[]?.name' \
    | grep -c '^admin$' || true)

  if [[ "$HAS_ADMIN" == "0" ]]; then
    kcadm.sh add-roles \
      -r "$REALM" \
      --uid "$SA_UID" \
      --rolename admin
    echo "👑 Admin role granted"
  else
    echo "🟢 Admin role already present"
  fi

  # ---- Fetch client secret ----
  echo "🔑 Fetch client secret"
  CLIENT_SECRET=$(kcadm.sh get "clients/$CID/client-secret" -r "$REALM" | jq -r .value)

  if [[ -z "$CLIENT_SECRET" || "$CLIENT_SECRET" == "null" ]]; then
    echo "🛑 Failed to fetch secret"
    exit 1
  fi

  vault kv patch "$VAULT_PATH" \
    client_id="$CLIENT_ID" \
    client_secret="$CLIENT_SECRET" >/dev/null
  
  echo "✅ Crossplane client stored in Vault"
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
  create_keycloak_azure_secret_management_realm
  create_keycloak_bootstrap_secret
  create_keycloak_administrator_secret
  trust_self_signed_ca_certificate
  # create_keycloak_client_crossplane 

  echo "✅ Bootstrap complete"
}

main
