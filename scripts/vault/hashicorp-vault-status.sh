#!/usr/bin/env bash
set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:?}"
VAULT_CLUSTER_PREFIX="${VAULT_CLUSTER_PREFIX:?}"
VAULT_REPLICAS="${VAULT_REPLICAS:?}"

echo "📊 HashiCorp Vault Status and Credentials:"
echo "=========================================="

if [ -f hashicorp-vault-init.json ]; then
  echo ""
  echo "🔐 ROOT TOKEN:"
  echo "=============="
  ROOT_TOKEN=$(cat hashicorp-vault-init.json | jq -r '.root_token')
  echo "$ROOT_TOKEN"
  echo ""
  echo "🔑 UNSEAL KEYS (Base64 encoded):"
  echo "================================"
  cat hashicorp-vault-init.json | jq -r '.unseal_keys_b64[]' | nl -nln
  echo ""
  echo "🔑 UNSEAL KEYS (Hex encoded):"
  echo "============================"
  cat hashicorp-vault-init.json | jq -r '.unseal_keys_hex[]' | nl -nln
  echo ""
  for i in $(seq 0 $((VAULT_REPLICAS - 1))); do
    echo "📋 VAULT STATUS (${VAULT_CLUSTER_PREFIX}-vault-$i):"
    echo "================================================"
    kubectl exec -n "$VAULT_NAMESPACE" "${VAULT_CLUSTER_PREFIX}-vault-$i" -- vault status 2>/dev/null || echo "❌ Failed to get vault status"
    echo ""
  done
  echo ""
  echo "🌐 VAULT URL:"
  echo "============"
  echo "https://vault.vault.svc.cluster.local:8200"
  echo ""
  echo "💡 To access HashiCorp Vault UI:"
  echo "================================"
  echo "kubectl port-forward -n vault svc/vault 8200:8200"
  echo "Then open: https://localhost:8200"
  echo ""
  echo "🔧 To login via CLI:"
  echo "==================="
  echo "export VAULT_ADDR=https://vault.vault.svc.cluster.local:8200"
  echo "export VAULT_TOKEN=$ROOT_TOKEN"
  echo "vault auth -method=token token=$ROOT_TOKEN"
  echo ""
  echo "⚠️  IMPORTANT: Save these credentials securely!"
  echo "   - Root token: $ROOT_TOKEN"
  echo "   - Unseal keys: Store the 5 keys above in a secure location"
else
  echo "❌ hashicorp-vault-init.json not found. HashiCorp Vault may not be initialized."
  echo "   Run 'task hashicorp-vault-init' to initialize Vault first."
fi
