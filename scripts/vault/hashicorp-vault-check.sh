#!/usr/bin/env bash
set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:?}"
VAULT_STATEFULSET_NAME="${VAULT_STATEFULSET_NAME:?}"
VAULT_REPLICAS="${VAULT_REPLICAS:?}"

echo "🔍 Checking HashiCorp Vault StatefulSet status..."
if ! kubectl get namespace "$VAULT_NAMESPACE" >/dev/null 2>&1; then
  echo "❌ Vault namespace '$VAULT_NAMESPACE' does not exist. Please deploy Vault first."
  exit 1
fi

echo "📋 StatefulSet Status:"
kubectl get statefulset -n "$VAULT_NAMESPACE" "$VAULT_STATEFULSET_NAME" || {
  echo "❌ Vault StatefulSet '$VAULT_STATEFULSET_NAME' not found in $VAULT_NAMESPACE namespace"
  exit 1
}

echo ""
echo "📋 Pod Status:"
kubectl get pods -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault

RUNNING_PODS=$(kubectl get pods -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')
TOTAL_PODS=$(kubectl get pods -n "$VAULT_NAMESPACE" -l app.kubernetes.io/name=vault --no-headers | wc -l | tr -d ' ')

if [ "$RUNNING_PODS" -lt "$VAULT_REPLICAS" ]; then
  echo "⚠️  Warning: Only $RUNNING_PODS out of $TOTAL_PODS Vault pods are running"
  echo "   Expected $VAULT_REPLICAS pods. This may cause issues with the unsealing process"
else
  echo "✅ All Vault pods are running"
fi
