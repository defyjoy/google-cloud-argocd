#!/usr/bin/env bash
# Print Vault pod list and vault status per replica.
# Env: VAULT_NAMESPACE, VAULT_CLUSTER_PREFIX, VAULT_REPLICAS

set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_CLUSTER_PREFIX="${VAULT_CLUSTER_PREFIX:-local}"
VAULT_REPLICAS="${VAULT_REPLICAS:-3}"

echo "📊 Vault Pod Status"
echo "=================="
echo ""
echo "Pod Details:"
kubectl get pods -n "${VAULT_NAMESPACE}" -l app.kubernetes.io/name=vault
echo ""
echo "Detailed Status for each pod:"
for ((i = 0; i < VAULT_REPLICAS; i++)); do
  pod="${VAULT_CLUSTER_PREFIX}-vault-${i}"
  echo ""
  echo "📋 Status for ${pod}:"
  echo "================================================"
  if kubectl get pod -n "${VAULT_NAMESPACE}" "${pod}" >/dev/null 2>&1; then
    kubectl exec -n "${VAULT_NAMESPACE}" "${pod}" -- vault status 2>/dev/null || echo "❌ Could not retrieve status"
  else
    echo "❌ Pod not found"
  fi
done
