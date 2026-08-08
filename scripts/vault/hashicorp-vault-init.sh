#!/usr/bin/env bash
set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:?}"
VAULT_CLUSTER_PREFIX="${VAULT_CLUSTER_PREFIX:?}"

echo "🚀 Initializing HashiCorp Vault..."
STATUS_OUT=$(kubectl exec -n "$VAULT_NAMESPACE" "${VAULT_CLUSTER_PREFIX}-vault-0" -- vault status 2>/dev/null || true)
if echo "$STATUS_OUT" | grep -q "Initialized.*true"; then
  echo "ℹ️  HashiCorp Vault is already initialized"
  if [ -f hashicorp-vault-init.json ]; then
    echo "📄 Using existing initialization data from hashicorp-vault-init.json"
  else
    echo "⚠️  Vault is initialized but no keys file found. You may need to unseal manually."
  fi
else
  echo "🔧 HashiCorp Vault not initialized, initializing now..."
  kubectl exec -n "$VAULT_NAMESPACE" "${VAULT_CLUSTER_PREFIX}-vault-0" -- vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json > hashicorp-vault-init.json

  if [ $? -eq 0 ] && [ -s hashicorp-vault-init.json ]; then
    echo "✅ HashiCorp Vault initialized successfully"
    echo "📄 Initialization data saved to hashicorp-vault-init.json"
    echo "🔑 Root token and unseal keys have been generated"
  else
    echo "❌ Failed to initialize HashiCorp Vault"
    exit 1
  fi
fi
