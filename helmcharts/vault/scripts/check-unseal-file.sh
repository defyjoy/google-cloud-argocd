#!/usr/bin/env bash
# Verify unseal keys JSON file exists.
# Env: VAULT_UNSEAL_KEYS_FILE (default: hashicorp-vault-init.json)

set -euo pipefail

VAULT_UNSEAL_KEYS_FILE="${VAULT_UNSEAL_KEYS_FILE:-hashicorp-vault-init.json}"

echo "🔍 Checking for unseal keys file..."
if [[ ! -f "${VAULT_UNSEAL_KEYS_FILE}" ]]; then
  echo "❌ File '${VAULT_UNSEAL_KEYS_FILE}' not found."
  echo "   Please ensure the file exists and contains unseal keys."
  echo "   Expected format:"
  echo '   {'
  echo '     "unseal_keys_b64": ["key1", "key2", "key3", "key4", "key5"]'
  echo '   }'
  exit 1
fi
echo "✅ Unseal keys file found: ${VAULT_UNSEAL_KEYS_FILE}"
