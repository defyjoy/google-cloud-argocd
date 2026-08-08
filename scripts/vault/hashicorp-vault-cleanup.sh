#!/usr/bin/env bash
set -euo pipefail

echo "🧹 Cleaning up HashiCorp Vault initialization file..."
if [ -f hashicorp-vault-init.json ]; then
  rm hashicorp-vault-init.json
  echo "✅ hashicorp-vault-init.json removed"
  echo "⚠️  Make sure you have securely stored the root token and unseal keys!"
else
  echo "ℹ️  No initialization file found to clean up"
fi
