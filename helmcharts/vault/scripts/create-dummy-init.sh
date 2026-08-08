#!/usr/bin/env bash
# Write a fake vault operator init JSON for testing task/script flow only.
# Env: VAULT_UNSEAL_KEYS_FILE

set -euo pipefail

VAULT_UNSEAL_KEYS_FILE="${VAULT_UNSEAL_KEYS_FILE:-hashicorp-vault-init.json}"

echo "🔧 Creating dummy initialization file..."
echo '{"unseal_keys_b64":["ZHVtbXkta2V5LTEtYmFzZTY0LWVuY29kZWQtdGVzdC1rZXk=","ZHVtbXkta2V5LTItYmFzZTY0LWVuY29kZWQtdGVzdC1rZXk=","ZHVtbXkta2V5LTMtYmFzZTY0LWVuY29kZWQtdGVzdC1rZXk=","ZHVtbXkta2V5LTQtYmFzZTY0LWVuY29kZWQtdGVzdC1rZXk=","ZHVtbXkta2V5LTUtYmFzZTY0LWVuY29kZWQtdGVzdC1rZXk="],"unseal_keys_hex":["dummy-key-1-hex","dummy-key-2-hex","dummy-key-3-hex","dummy-key-4-hex","dummy-key-5-hex"],"unseal_shares":5,"unseal_threshold":3,"recovery_keys_b64":[],"recovery_keys_hex":[],"recovery_keys_shares":0,"recovery_keys_threshold":0,"root_token":"hvs.DUMMYTESTTOKEN1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ"}' > "${VAULT_UNSEAL_KEYS_FILE}"
jq . "${VAULT_UNSEAL_KEYS_FILE}" > /tmp/vault-init-formatted.json
mv /tmp/vault-init-formatted.json "${VAULT_UNSEAL_KEYS_FILE}"

echo "✅ Dummy initialization file created: ${VAULT_UNSEAL_KEYS_FILE}"
echo ""
echo "⚠️  WARNING: This is a DUMMY file with FAKE credentials!"
echo "   - Root token: hvs.DUMMYTESTTOKEN1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ"
echo "   - Unseal keys: dummy-key-* (Base64 encoded)"
echo ""
echo "💡 This file can be used to test the unseal script syntax"
echo "   but will NOT work with real Vault instances."
echo ""
echo "📋 To use with real Vault:"
echo "   1. Initialize Vault: vault operator init -format=json"
echo "   2. Save the output to this file"
echo "   3. Run: task unseal"
