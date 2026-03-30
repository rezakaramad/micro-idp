#!/usr/bin/env bash
set -euo pipefail

echo "⏳ Waiting for DB..."
until PGPASSWORD="$POSTGRES_PASSWORD" psql -h db -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c '\q'; do
sleep 2
done

echo "⏳ Waiting for user table..."
MAX_RETRIES=60
COUNT=0

until PGPASSWORD="$POSTGRES_PASSWORD" psql -h db -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='user'" | grep -q 1; do
  sleep 2
  COUNT=$((COUNT+1))
  if [ "$COUNT" -ge "$MAX_RETRIES" ]; then
    echo "❌ Timeout waiting for user table"
    exit 1
  fi
done

[ -n "$PDNS_ADMIN_PASSWORD_HASH" ] || { echo "❌ ADMIN_HASH not set"; exit 1; }

echo "👤 Creating admin user..."

PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -h db -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOF
INSERT INTO "user" (username, password, firstname, lastname, email, role_id, confirmed)
VALUES ('rezakara', '$PDNS_ADMIN_PASSWORD_HASH', 'Reza', 'Karamad', 'r.karamad@gmail.com', 1, true)
ON CONFLICT (username) DO UPDATE
SET password = EXCLUDED.password;
EOF

echo "✅ Admin user ready"
