#!/usr/bin/env bash
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:?}"

if ! command -v htpasswd >/dev/null 2>&1; then
  echo "❌ htpasswd not found. Install apache2-utils (e.g., 'brew install httpd')."
  exit 1
fi

trap 'stty echo 2>/dev/null || true' EXIT

printf "Enter new ArgoCD admin password: "
stty -echo
read -r NEW_PASSWORD
stty echo
echo ""
printf "Confirm new password: "
stty -echo
read -r CONFIRM_PASSWORD
stty echo
echo ""

if [ "${NEW_PASSWORD}" != "${CONFIRM_PASSWORD}" ]; then
  echo "❌ Passwords do not match. Aborting."
  exit 1
fi

if [ -z "${NEW_PASSWORD}" ]; then
  echo "❌ Password cannot be empty."
  exit 1
fi

echo "🔐 Updating ArgoCD admin password..."
BCRYPT=$(htpasswd -bnBC 10 '' "${NEW_PASSWORD}" | tr -d ':\n')
B64_BCRYPT=$(printf '%s' "$BCRYPT" | base64)
B64_MTIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" | base64)

kubectl -n "$ARGOCD_NAMESPACE" patch secret argocd-secret \
  --type merge \
  -p "{\"data\":{\"admin.password\":\"$B64_BCRYPT\",\"admin.passwordMtime\":\"$B64_MTIME\"}}" >/dev/null

echo "✅ Admin password updated in argocd-secret"
echo "ℹ️  For immediate effect, you may restart the server:"
echo "   kubectl -n $ARGOCD_NAMESPACE rollout restart deploy/argocd-server"
