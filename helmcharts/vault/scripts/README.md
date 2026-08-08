# Vault helper scripts

Bash scripts used by `Taskfile.yml` in the parent directory. You can run them directly:

```bash
cd helmcharts/vault

VAULT_NAMESPACE=vault VAULT_CLUSTER_PREFIX=local VAULT_REPLICAS=3 \
  VAULT_UNSEAL_KEYS_FILE=./hashicorp-vault-init.json \
  bash scripts/unseal-all-pods.sh
```

| Script | Purpose |
|--------|---------|
| `check-cluster.sh` | `kubectl` connectivity and Vault namespace |
| `check-unseal-file.sh` | Init JSON file exists |
| `unseal-all-pods.sh` | Shamir unseal for `${prefix}-vault-0..N-1` |
| `status.sh` | Pod list and `vault status` per replica |
| `credentials.sh` | Print root token and keys from JSON (sensitive) |
| `create-dummy-init.sh` | Fake init JSON for testing only |

Environment variables (defaults in parentheses):

- `VAULT_NAMESPACE` (`vault`)
- `VAULT_CLUSTER_PREFIX` (`local`)
- `VAULT_REPLICAS` (`3`)
- `VAULT_UNSEAL_KEYS_FILE` (`hashicorp-vault-init.json`)

Requires: `bash`, `kubectl`, `jq`.
