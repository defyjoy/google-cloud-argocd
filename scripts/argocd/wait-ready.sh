#!/usr/bin/env bash
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:?}"

echo "⏳ Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-server -n "$ARGOCD_NAMESPACE"
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-repo-server -n "$ARGOCD_NAMESPACE"
kubectl wait --for=condition=available --timeout=300s \
  deployment/argocd-applicationset-controller -n "$ARGOCD_NAMESPACE"
# Application controller is a StatefulSet in current argo-cd Helm charts; wait so sync/self-manage is safe.
if kubectl get statefulset argocd-application-controller -n "$ARGOCD_NAMESPACE" &>/dev/null; then
  echo "⏳ Waiting for Argo CD application controller..."
  kubectl rollout status statefulset/argocd-application-controller -n "$ARGOCD_NAMESPACE" --timeout=300s
fi
echo "✅ ArgoCD is ready"
