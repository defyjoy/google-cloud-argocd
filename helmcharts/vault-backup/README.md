# vault-backup

Daily Raft snapshots to S3 for the management cluster (ArgoCD ApplicationSet
`vault-backup-as.yaml`, label `vault-backup: "true"`).

Uses the standard Vault CLI:

```bash
vault operator raft snapshot save <filename>.snap
vault operator raft snapshot restore -force <filename>.snap
```

The CronJob runs `snapshot save`, then uploads the `.snap` (+ sha256) to S3 with rclone.
A Raft snapshot includes **all** secret engines (including every KV version).

Auth: static Vault token + AWS keys via ExternalSecret from `kv/infra/vault-backup/s3`.

Policy file: [`vault-backup.hcl`](./vault-backup.hcl).

---

## Least-privilege Vault policy (backup + restore only)

This policy allows **only** Raft snapshot backup and force-restore.

### `vault-backup.hcl`

```hcl
# Take a snapshot (backup)
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# Optional: leader check
path "sys/leader" {
  capabilities = ["read"]
}

# Force-restore a snapshot
path "sys/storage/raft/snapshot-force" {
  capabilities = ["update"]
}
```

### Apply the policy

```bash
vault policy write vault-backup vault-backup.hcl
```

Or inline:

```bash
vault policy write vault-backup - <<'EOF'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
path "sys/leader" {
  capabilities = ["read"]
}
path "sys/storage/raft/snapshot-force" {
  capabilities = ["update"]
}
EOF
```

### Create a limited orphan periodic token

```bash
vault token create \
  -policy=vault-backup \
  -display-name="vault-backup-cron" \
  -period=768h \
  -orphan
```

### Store credentials for ExternalSecret

| Vault KV property         | CronJob / K8s Secret key |
|---------------------------|--------------------------|
| `VAULT_ACCESS_KEY_ID`     | `AWS_ACCESS_KEY_ID`      |
| `VAULT_SECRET_ACCESS_KEY` | `AWS_SECRET_ACCESS_KEY`  |
| `VAULT_TOKEN`             | `VAULT_TOKEN`            |

```bash
vault kv put kv/infra/vault-backup/s3 \
  VAULT_ACCESS_KEY_ID='AKIA...' \
  VAULT_SECRET_ACCESS_KEY='...' \
  VAULT_TOKEN='hvs....'

# Or patch only the token later
vault kv patch kv/infra/vault-backup/s3 \
  VAULT_TOKEN='hvs....'
```

---

## Manual restore (Raft)

```bash
export VAULT_ADDR='http://local-vault-active.vault.svc:8200'
export VAULT_TOKEN='hvs....'   # vault-backup policy (or root)

vault operator raft snapshot restore -force /path/to/raft-snapshot-....snap
```

Restore is destructive; practice on a non-prod cluster first.

---

## GitOps / Helm values

- Chart: `helmcharts/vault-backup`
- ApplicationSet: `helmcharts/argocd-apps/templates/applicationsets/vault-backup-as.yaml`
- Cluster gate: `vault-backup: "true"` on `helmcharts/argocd/templates/cluster/local-cluster-secret.yaml`
- Bucket / region: `helmcharts/vault-backup/values/local.yaml`

Schedule defaults to `0 2 * * *` (02:00 UTC daily).

Object layout:

`s3://<bucket>/<prefix>/YYYY/MM/DD/raft-snapshot-<UTC>.snap`

---

## This deployment's configuration

Daily raft snapshots to S3. **management-only** — there is no `values/dev.yaml`, and the
ApplicationSet gates it accordingly.

### Schedule and target

```yaml
# Daily schedule in UTC; override per environment in values/<environment>.yaml
```

Snapshots prefer the **active/leader** Vault Service, which is what
`vault operator raft snapshot save` requires. TLS verification is skipped because management's
Vault runs with `tls_disable = 1`.

Object keys land at:

```
s3://<bucket>/<prefix>/YYYY/MM/DD/raft-snapshot-....snap
```

`prefix` takes no leading or trailing slash.

### Credentials

Delivered via the `ClusterSecretStore`. The target Secret must carry three keys:
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `VAULT_TOKEN`.

The image is the official Vault image, which provides
`vault operator raft snapshot save/restore`.

> 🔓 The namespace uses **baseline** PSA (set by the ApplicationSet), because `apk` needs uid 0
> to install rclone.

### One-time Vault setup

```bash
vault policy write vault-backup vault-backup.hcl
vault token create -policy=vault-backup -display-name=vault-backup-cron -period=768h -orphan

vault kv put kv/infra/vault-backup/s3 \
  VAULT_ACCESS_KEY_ID=... \
  VAULT_SECRET_ACCESS_KEY=... \
  VAULT_TOKEN=...
```

See `README.md`'s own sections plus `vault-backup.hcl` for the policy contents.
