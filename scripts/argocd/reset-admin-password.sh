#!/usr/bin/env bash
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:?}"

if ! command -v htpasswd >/dev/null 2>&1; then
  echo "❌ htpasswd not found. Install apache2-utils (e.g., 'brew install httpd')."
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "❌ openssl not found. Please install openssl."
  exit 1
fi

if [ -z "${NEW_PASSWORD:-}" ]; then
  NEW_PASSWORD=$(openssl rand -base64 24 | tr -d '\n' | tr '/+' '-_' | cut -c1-20)
  GENERATED=1
else
  GENERATED=0
fi

echo "🔐 Resetting ArgoCD admin password..."
BCRYPT=$(htpasswd -bnBC 10 '' "${NEW_PASSWORD}" | tr -d ':\n')
B64_BCRYPT=$(printf '%s' "$BCRYPT" | base64)
B64_MTIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" | base64)

kubectl -n "$ARGOCD_NAMESPACE" patch secret argocd-secret \
  --type merge \
  -p "{\"data\":{\"admin.password\":\"$B64_BCRYPT\",\"admin.passwordMtime\":\"$B64_MTIME\"}}" >/dev/null

echo "✅ Admin password updated in argocd-secret"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  ArgoCD Admin New Credentials"
echo "═══════════════════════════════════════════════════════════"
echo "  Username: admin"
echo "  Password: ${NEW_PASSWORD}"
echo "═══════════════════════════════════════════════════════════"
echo ""
if [ "$GENERATED" = "1" ]; then
  echo "💡 A random password was generated. Store it securely."
fi
echo "ℹ️  You may need to restart the server for immediate effect:"
echo "   kubectl -n $ARGOCD_NAMESPACE rollout restart deploy/argocd-server"
