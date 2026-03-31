#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# Clean /etc/hosts entries
# -------------------------------
echo "🧼 Cleaning /etc/hosts entries..."

if grep -q 'rezakara.demo' /etc/hosts; then
  echo "🧹 Removing rezakara.demo entries from /etc/hosts"

  sudo cp /etc/hosts /etc/hosts.bak

  sudo sed -i.bak '/rezakara\.demo/d' /etc/hosts

  echo "✅ /etc/hosts cleaned"
else
  echo "✔ No rezakara.demo entries found"
fi

# -------------------------------
# Flush DNS cache
# -------------------------------
echo "🔄 Flushing DNS cache..."
sudo resolvectl flush-caches 2>/dev/null || true
echo "✅ DNS cache flushed"
