#!/usr/bin/env bash
# Print root token and unseal keys from vault init JSON (sensitive).
# Env: VAULT_UNSEAL_KEYS_FILE

set -euo pipefail

VAULT_UNSEAL_KEYS_FILE="${VAULT_UNSEAL_KEYS_FILE:-hashicorp-vault-init.json}"

echo "🔐 Vault Credentials"
echo "==================="

if [[ ! -f "${VAULT_UNSEAL_KEYS_FILE}" ]]; then
  echo "❌ File '${VAULT_UNSEAL_KEYS_FILE}' not found."
  exit 1
fi

echo ""
echo "🔑 ROOT TOKEN:"
echo "=============="
jq -r '.root_token' "${VAULT_UNSEAL_KEYS_FILE}"
echo ""
echo "🔑 UNSEAL KEYS (Base64 encoded):"
echo "================================"
jq -r '.unseal_keys_b64[]' "${VAULT_UNSEAL_KEYS_FILE}" | nl -nln
echo ""
echo "🔑 UNSEAL KEYS (Hex encoded):"
echo "============================"
jq -r '.unseal_keys_hex[]' "${VAULT_UNSEAL_KEYS_FILE}" | nl -nln
echo ""
echo "⚠️  IMPORTANT: Store these credentials securely!"
