#!/usr/bin/env bash
set -euo pipefail

VAULT_NAMESPACE="${VAULT_NAMESPACE:?}"
VAULT_CLUSTER_PREFIX="${VAULT_CLUSTER_PREFIX:?}"
VAULT_REPLICAS="${VAULT_REPLICAS:?}"

INIT_FILE="hashicorp-vault-init.json"

echo "🔓 Unsealing HashiCorp Vault pods..."
if [ ! -f "$INIT_FILE" ]; then
  echo "❌ $INIT_FILE not found in $(pwd)."
  echo "   Run 'task hashicorp-vault-init' (fresh Vault) or 'task hashicorp-vault-init-template' (paste saved keys) first."
  exit 1
fi

if grep -q "REPLACE_WITH" "$INIT_FILE"; then
  echo "❌ $INIT_FILE still contains REPLACE_WITH_* placeholders — fill in the real keys first."
  exit 1
fi

echo "📄 Using saved initialization data from $INIT_FILE"
THRESHOLD=$(jq -r '.unseal_threshold // 3' "$INIT_FILE")
mapfile -t UNSEAL_KEYS < <(jq -r '.unseal_keys_b64[]' "$INIT_FILE")

if [ "${#UNSEAL_KEYS[@]}" -lt "$THRESHOLD" ]; then
  echo "❌ Unseal threshold is $THRESHOLD but only ${#UNSEAL_KEYS[@]} key(s) present in $INIT_FILE"
  exit 1
fi

# True when the pod reports sealed=false.
pod_is_unsealed() {
  local pod_name=$1
  kubectl exec -n "$VAULT_NAMESPACE" "$pod_name" -- vault status -format=json 2>/dev/null \
    | jq -e '.sealed == false' >/dev/null 2>&1
}

unseal_vault_pod() {
  local pod_name=$1

  local phase
  phase=$(kubectl get pod -n "$VAULT_NAMESPACE" "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$phase" != "Running" ]; then
    echo "⚠️  $pod_name phase='${phase:-<unreachable>}' (not Running), skipping..."
    return 1
  fi

  if pod_is_unsealed "$pod_name"; then
    echo "✅ $pod_name already unsealed"
    return 0
  fi

  echo "🔑 Unsealing $pod_name (threshold $THRESHOLD)..."
  local n=0 out=""
  for key in "${UNSEAL_KEYS[@]}"; do
    if ! out=$(kubectl exec -n "$VAULT_NAMESPACE" "$pod_name" -- vault operator unseal "$key" 2>&1); then
      echo "   ⚠️  unseal key rejected/errored on $pod_name:"
      echo "$out" | sed 's/^/      /'
    fi
    n=$((n + 1))
    if pod_is_unsealed "$pod_name"; then
      echo "✅ $pod_name unsealed after $n key(s)"
      return 0
    fi
    [ "$n" -ge "$THRESHOLD" ] && break
  done

  echo "❌ $pod_name still sealed after feeding $n key(s). Last unseal output:"
  echo "${out:-<none>}" | sed 's/^/      /'
  return 1
}

rc=0
for i in $(seq 0 $((VAULT_REPLICAS - 1))); do
  unseal_vault_pod "${VAULT_CLUSTER_PREFIX}-vault-$i" || rc=1
done

if [ "$rc" -eq 0 ]; then
  echo "✅ HashiCorp Vault unsealing process completed — all pods unsealed"
else
  echo "⚠️  HashiCorp Vault unsealing incomplete — see messages above"
fi
exit "$rc"
