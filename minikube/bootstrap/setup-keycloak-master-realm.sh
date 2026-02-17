#!/usr/bin/env bash
set -euo pipefail

KC=http://keycloak-service:8080

echo "Checking Keycloak socket..."
SOCKET_OK=false
for i in {1..12}; do
  if (echo > /dev/tcp/keycloak-service/8080) >/dev/null 2>&1; then
    SOCKET_OK=true
    break
  fi
  echo "Socket not ready yet..."
  sleep 5
done
[ "$SOCKET_OK" != "true" ] && echo "ERROR: Keycloak service unreachable" && exit 1

echo "Checking Keycloak authentication..."
LOGIN_SUCCESS=false
for i in {1..12}; do
  if /opt/keycloak/bin/kcadm.sh config credentials \
    --server "$KC" --realm master \
    --user "$BOOTSTRAP_USER" --password "$BOOTSTRAP_PASSWORD"; then
    LOGIN_SUCCESS=true
    break
  fi
  echo "Login not ready yet..."
  sleep 5
done
[ "$LOGIN_SUCCESS" != "true" ] && echo "ERROR: Keycloak not ready for authentication" && exit 1

echo "Ensuring breakglass user exists"
USER_ID=$(/opt/keycloak/bin/kcadm.sh get users -r master \
  -q username="$BREAKGLASS_USER" --fields id --format csv \
  | tail -n +2 | head -n 1 | tr -d '"')

if [ -z "$USER_ID" ]; then
  echo "Creating breakglass user"
  CREATE_OUTPUT=$(/opt/keycloak/bin/kcadm.sh create users -r master \
    -s username="$BREAKGLASS_USER" \
    -s enabled=true 2>&1)

  USER_ID=$(echo "$CREATE_OUTPUT" | grep -oE "[0-9a-fA-F-]{36}")
fi

[ -z "$USER_ID" ] && echo "ERROR: Could not resolve breakglass USER_ID" && exit 1

echo "Setting permanent password (creates credential in KC26+)"
/opt/keycloak/bin/kcadm.sh set-password \
  -r master \
  --userid "$USER_ID" \
  --password "$BREAKGLASS_PASSWORD"

echo "Ensuring admin role"
/opt/keycloak/bin/kcadm.sh add-roles -r master --uid "$USER_ID" --rolename admin || true

echo "Breakglass user ready"