#!/usr/bin/env bash
set -euo pipefail

: "${ARGOCD_CHART_DIR:?}"
: "${ARGOCD_NAMESPACE:?}"
: "${ARGOCD_GIT_REPO_KEY:?}"
: "${ARGOCD_GIT_REPO_URL:?}"
: "${ARGOCD_GIT_SSH_PRIVATE_KEY_PATH:?}"

SSH_KEY="${ARGOCD_GIT_SSH_PRIVATE_KEY_PATH}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

if [[ ! -f "$SSH_KEY" ]]; then
  echo "❌ SSH private key not found: $SSH_KEY"
  echo "   Set ARGOCD_GIT_SSH_PRIVATE_KEY_PATH (Taskfile vars or task VAR=...)."
  exit 1
fi

echo "🚀 Installing / upgrading ArgoCD (repo key: ${ARGOCD_GIT_REPO_KEY}, SSH key: ${SSH_KEY})..."

# Optional bootstrap overlay. On a fresh cluster the External Secrets / Gateway API CRDs are
# absent and the kube-system/coredns ConfigMap already exists (Talos-created, un-adoptable by
# Helm), so ARGOCD_BOOTSTRAP_VALUES points at values-bootstrap.yaml, which disables those
# resources for this first install. Argo CD self-heals / adopts them from git afterwards.
BOOTSTRAP_ARGS=()
if [[ -n "${ARGOCD_BOOTSTRAP_VALUES:-}" ]]; then
  if [[ ! -f "$ARGOCD_BOOTSTRAP_VALUES" ]]; then
    echo "❌ Bootstrap overlay not found: $ARGOCD_BOOTSTRAP_VALUES"
    exit 1
  fi
  echo "🧩 Bootstrap mode: overlay ${ARGOCD_BOOTSTRAP_VALUES} (skips dev-cluster ExternalSecret, argocd-server HTTPRoute, kube-system/coredns until their CRDs exist / Argo CD adopts them)"
  BOOTSTRAP_ARGS+=(-f "$ARGOCD_BOOTSTRAP_VALUES")
fi

# --force-conflicts: once Argo CD self-manages this release its field manager co-owns these
# objects, and Helm 4's server-side apply conflicts on API-server-normalized values. See README.
helm upgrade --install argocd "$ARGOCD_CHART_DIR" -n "$ARGOCD_NAMESPACE" --create-namespace \
  --force-conflicts \
  --set-file "argo-cd.configs.repositories.${ARGOCD_GIT_REPO_KEY}.sshPrivateKey=${SSH_KEY}" \
  --set "argo-cd.configs.repositories.${ARGOCD_GIT_REPO_KEY}.url=${ARGOCD_GIT_REPO_URL}" \
  "${BOOTSTRAP_ARGS[@]}"

echo "✅ ArgoCD Helm release applied"
