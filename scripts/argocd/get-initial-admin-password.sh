#!/usr/bin/env bash
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:?}"

if kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  PLAINTEXT=$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  ArgoCD Admin Credentials"
  echo "═══════════════════════════════════════════════════════════"
  echo "  Username: admin"
  echo "  Password: $PLAINTEXT"
  echo "═══════════════════════════════════════════════════════════"
  echo ""
  echo "ℹ️  Source: argocd-initial-admin-secret (plaintext)"
  echo ""
else
  echo "❌ argocd-initial-admin-secret not found in namespace '$ARGOCD_NAMESPACE'."
  echo "   The initial plaintext password is only available immediately after install."
  echo "   Use one of the following to set a new password:"
  echo "     task reset-admin-password"
  echo "     task change-admin-password"
  exit 1
fi
