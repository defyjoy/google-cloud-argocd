#!/usr/bin/env bash
set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:?}"
VAULT_CLUSTER_PREFIX="${VAULT_CLUSTER_PREFIX:?}"
VAULT_REPLICAS="${VAULT_REPLICAS:?}"

echo "🏥 Checking HashiCorp Vault health across all pods..."
for i in $(seq 0 $((VAULT_REPLICAS - 1))); do
  pod="${VAULT_CLUSTER_PREFIX}-vault-$i"
  echo ""
  echo "📋 Health check for $pod:"
  echo "=========================="
  if kubectl get pod -n "$VAULT_NAMESPACE" "$pod" >/dev/null 2>&1; then
    kubectl exec -n "$VAULT_NAMESPACE" "$pod" -- vault status 2>/dev/null || echo "❌ Failed to get status from $pod"
  else
    echo "❌ Pod $pod not found"
  fi
done
