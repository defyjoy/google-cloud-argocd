#!/usr/bin/env bash
set -euo pipefail

echo "🔐 Creating vault-token secret for External Secrets Operator..."

if [ ! -f hashicorp-vault-init.json ]; then
  echo "❌ hashicorp-vault-init.json not found. Please run 'task hashicorp-vault-init' first"
  exit 1
fi

ROOT_TOKEN=$(cat hashicorp-vault-init.json | jq -r '.root_token')
if [ "$ROOT_TOKEN" = "null" ] || [ -z "$ROOT_TOKEN" ]; then
  echo "❌ Could not extract root token from hashicorp-vault-init.json"
  exit 1
fi

echo "✅ Root token extracted successfully"

if kubectl get secret vault-token -n external-secrets >/dev/null 2>&1; then
  echo "⚠️  vault-token secret already exists. Updating..."
  kubectl delete secret vault-token -n external-secrets --ignore-not-found=true
fi

kubectl create secret generic vault-token \
  --from-literal=token="$ROOT_TOKEN" \
  --namespace=external-secrets

echo "✅ vault-token secret created successfully in external-secrets namespace"
echo "📋 Secret details:"
kubectl get secret vault-token -n external-secrets -o yaml | grep -A 2 "data:"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VAULT_SECRETSTORE_MANIFEST="${REPO_ROOT}/helmcharts/external-secrets/templates/vault-secretstore.yaml"

echo ""
echo "💡 Next steps:"
echo "   1. Deploy the Vault SecretStore: kubectl apply -f ${VAULT_SECRETSTORE_MANIFEST}"
echo "   2. Create ExternalSecrets to sync secrets from Vault"
echo "   3. Check External Secrets Operator logs: kubectl logs -n external-secrets deployment/external-secrets"
