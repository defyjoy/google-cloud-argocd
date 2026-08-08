#!/usr/bin/env bash
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:?}"

echo "🗑️  Deleting applications..."
kubectl delete applications --all -n "$ARGOCD_NAMESPACE" --ignore-not-found=true
echo "🗑️  Uninstalling ArgoCD..."
helm uninstall argocd -n "$ARGOCD_NAMESPACE" --ignore-not-found
echo "🗑️  Deleting namespace..."
kubectl delete namespace "$ARGOCD_NAMESPACE" --ignore-not-found=true
echo "✅ ArgoCD uninstalled"
