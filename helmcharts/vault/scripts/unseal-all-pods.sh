#!/usr/bin/env bash
# Unseal all Vault pods using keys from vault operator init JSON.
# Env: VAULT_NAMESPACE, VAULT_CLUSTER_PREFIX, VAULT_REPLICAS, VAULT_UNSEAL_KEYS_FILE

set -u

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_CLUSTER_PREFIX="${VAULT_CLUSTER_PREFIX:-local}"
VAULT_REPLICAS="${VAULT_REPLICAS:-3}"
VAULT_UNSEAL_KEYS_FILE="${VAULT_UNSEAL_KEYS_FILE:-hashicorp-vault-init.json}"

echo "🔓 Starting to unseal all Vault pods..."

UNSEAL_KEYS=$(jq -r '.unseal_keys_b64[]' "${VAULT_UNSEAL_KEYS_FILE}")
if [[ -z "${UNSEAL_KEYS}" ]]; then
  echo "❌ Could not extract unseal keys from JSON file"
  exit 1
fi
echo "✅ Extracted unseal keys from JSON file"

unseal_pod() {
  local pod_name=$1
  echo ""
  echo "🔑 Unsealing pod: ${pod_name}"

  if ! kubectl get pod -n "${VAULT_NAMESPACE}" "${pod_name}" >/dev/null 2>&1; then
    echo "⚠️  Pod ${pod_name} not found, skipping..."
    return 0
  fi

  local vault_status
  vault_status=$(kubectl exec -n "${VAULT_NAMESPACE}" "${pod_name}" -- vault status 2>&1) || true
  local status_exit_code=$?

  local sealed_status
  sealed_status=$(echo "${vault_status}" | grep "Sealed" | awk '{print $NF}')

  if [[ "${sealed_status}" == "false" ]]; then
    echo "✅ Pod ${pod_name} is already unsealed"
    return 0
  elif [[ "${sealed_status}" == "true" ]]; then
    echo "  Pod is sealed (Seal Type: shamir, Threshold: 3)"
  else
    echo "⚠️  Could not determine sealed status from: ${vault_status}"
    echo "   Exit code: ${status_exit_code}"
    return 0
  fi

  echo "  Pod is sealed, applying unseal keys..."

  local first_three_keys
  first_three_keys=$(jq -r '.unseal_keys_b64[0:3] | .[]' "${VAULT_UNSEAL_KEYS_FILE}")

  local keys_applied=0
  local key_index=0
  local result exit_code
  while IFS= read -r key; do
    [[ -z "${key}" ]] && continue
    key_index=$((key_index + 1))
    echo "  Applying key ${key_index} of 3..."

    result=$(kubectl exec -n "${VAULT_NAMESPACE}" "${pod_name}" -- vault operator unseal "${key}" 2>&1)
    exit_code=$?

    if [[ ${exit_code} -eq 0 ]]; then
      keys_applied=$((keys_applied + 1))
      echo "  ✓ Successfully applied key ${keys_applied} of 3"
      if echo "${result}" | grep -q "Sealed.*false"; then
        echo "✅ Pod ${pod_name} successfully unsealed!"
        return 0
      fi
    else
      echo "  ⚠️  Warning: Key ${key_index} had issues (exit code: ${exit_code})"
      echo "     Output: ${result}"
    fi
  done <<< "${first_three_keys}"

  if [[ ${keys_applied} -lt 3 ]]; then
    echo "  ⚠️  Only applied ${keys_applied} out of 3 required keys"
  fi

  local final_status final_sealed
  final_status=$(kubectl exec -n "${VAULT_NAMESPACE}" "${pod_name}" -- vault status 2>&1) || true
  final_sealed=$(echo "${final_status}" | grep "Sealed" | awk '{print $NF}')

  if [[ "${final_sealed}" == "false" ]]; then
    echo "✅ Pod ${pod_name} is now unsealed"
  else
    echo "⚠️  Pod ${pod_name} may not be fully unsealed"
    echo "   Sealed status: ${final_sealed}"
  fi
}

failed_pods=0
for ((i = 0; i < VAULT_REPLICAS; i++)); do
  pod="${VAULT_CLUSTER_PREFIX}-vault-${i}"
  if ! unseal_pod "${pod}"; then
    failed_pods=$((failed_pods + 1))
  fi
done

echo ""
echo "✅ Unseal process completed"
echo "💡 Run 'task status' to check vault status"
