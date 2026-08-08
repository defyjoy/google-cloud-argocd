#!/usr/bin/env bash
# Verify kubectl connectivity and Vault namespace exists.
# Env: VAULT_NAMESPACE (default: vault)

set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"

echo "🔍 Checking cluster connectivity..."
if ! kubectl cluster-info &>/dev/null; then
  echo "❌ Cannot connect to Kubernetes cluster. Check your kubeconfig."
  exit 1
fi
echo "✅ Cluster connectivity verified"

if ! kubectl get namespace "${VAULT_NAMESPACE}" >/dev/null 2>&1; then
  echo "❌ Vault namespace '${VAULT_NAMESPACE}' does not exist."
  exit 1
fi
echo "✅ Vault namespace exists"
