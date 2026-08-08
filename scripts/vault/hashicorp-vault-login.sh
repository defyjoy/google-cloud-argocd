#!/usr/bin/env bash
set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:?}"
VAULT_CLUSTER_PREFIX="${VAULT_CLUSTER_PREFIX:?}"

POD_NAME="${1:-${VAULT_CLUSTER_PREFIX}-vault-0}"

echo "🔐 Logging into HashiCorp Vault pod..."
echo "📱 Connecting to pod: $POD_NAME"
echo "💡 Use 'vault status' to check vault status"
echo "💡 Use 'vault operator unseal <key>' to unseal manually"
echo "💡 Use 'exit' to return to host shell"
echo ""
kubectl exec -it -n "$VAULT_NAMESPACE" "$POD_NAME" -- /bin/sh
