# HashiCorp Vault Backups on Kubernetes → Azure Blob / AWS S3 / GCS

> **Goal**: Create an internal, automated, least‑privileged backup process for Vault running on Kubernetes that produces consistent snapshots and pushes them to Azure Blob Storage, AWS S3, or Google Cloud Storage—complete with retention, integrity checks, and a tested restore plan.

---

## 0) Quick map of approaches

**If your storage backend is Raft (Integrated Storage)** (recommended):

* Use `vault operator raft snapshot save` (or the HTTP API `sys/storage/raft/snapshot`) to create a point‑in‑time snapshot.
* Automate via a Kubernetes `CronJob` that authenticates to Vault using the **Kubernetes auth method** with a strictly scoped policy that grants snapshot capability.
* Upload the snapshot artifact to your chosen cloud bucket (Azure Blob, S3, or GCS).

**If your storage backend is Consul**:

* Use `consul snapshot save` to back up Consul data (which includes Vault’s data when using the Consul storage backend).
* Automate via a `CronJob` that runs `consul snapshot save`, then ships the artifact to your bucket.

> The guide below focuses on **Raft (Integrated Storage)** first (most common), then shows the **Consul** variant near the end.

---

## 1) Assumptions & prerequisites

* Vault is deployed on Kubernetes (Helm or Operator), reachable at a stable Service DNS (e.g. `https://vault.vault.svc:8200`).
* You’re using **Vault OSS or Enterprise** with **Integrated Storage (Raft)**.
* You can enable/configure **Vault Kubernetes Auth**.
* A dedicated **Namespace** (e.g. `vault`) exists. Adjust manifests accordingly if not.
* A dedicated **cloud bucket** (Azure Blob / S3 / GCS) and IAM principal with write‑only permissions for a path/prefix.
* Cluster nodes’ time is NTP‑synced; you have somewhere to store and rotate secrets.

### Security model

* **Snapshot is already encrypted at rest** by Raft (it contains encrypted WAL and metadata). Still, treat it as sensitive.
* Use **separate cloud creds** (least privilege: write and list **only** the target prefix; no delete unless you manage retention from the job, otherwise use bucket lifecycle rules).
* Optionally **envelope‑encrypt** the artifact with KMS or `age`/PGP for defense‑in‑depth.

---

## 2) Minimal Vault setup for snapshot permissions

We’ll create a **policy** that allows creating Raft snapshots and a **Kubernetes role** that issues tokens with that policy.

> Requires a privileged administrator token for the one‑time setup.

```bash
# 2.1 Enable Kubernetes auth (once)
vault auth enable kubernetes

# 2.2 Configure the Kubernetes auth method (point Vault to your K8s API & issuer)
# Replace values with your cluster’s details.
vault write auth/kubernetes/config \
  kubernetes_host="https://$K8S_API:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  issuer="https://kubernetes.default.svc.cluster.local"

# 2.3 Create a least‑privileged policy for raft snapshot
cat > raft-snapshot.hcl << 'EOF'
# Allow creating and downloading raft snapshots
path "sys/storage/raft/snapshot" {
  capabilities = ["read", "update", "sudo"]
}
# Optional: allow reading the leader status (for logging/health)
path "sys/leader" {
  capabilities = ["read"]
}
EOF

vault policy write raft-snapshot raft-snapshot.hcl

# 2.4 Create a Kubernetes auth role bound to a ServiceAccount used by the CronJob
vault write auth/kubernetes/role/vault-backup \
  bound_service_account_names=vault-backup-sa \
  bound_service_account_namespaces=vault \
  policies=raft-snapshot \
  ttl=1h
```

**Notes**

* The snapshot API requires elevated capability (`sudo`). Keep this policy dedicated to the backup SA only.
* If Vault is namespaced differently or Kubernetes Auth is mounted at a different path (e.g., `auth/k8s`), adjust paths.

---

## 3) Kubernetes objects (ServiceAccount, Secret, and CronJob)

We’ll implement one CronJob that:

1. Logs into Vault via Kubernetes auth.
2. Produces a Raft snapshot file.
3. Computes checksums.
4. Uploads to Azure Blob **or** S3 **or** GCS using **rclone** (single binary supports all three).

> Swap in native CLIs (awscli / azcopy / gsutil) if you prefer. Rclone simplifies multi‑cloud.

### 3.1 Namespace & ServiceAccount

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vault
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-backup-sa
  namespace: vault
```

### 3.2 Cloud credentials as Kubernetes Secret(s)

Create **one** Secret for rclone’s config (supports multi‑remote) **or** separate Secrets per provider.

**Option A — single `rclone.conf` (recommended)**

```ini
# rclone.conf example with 3 remotes
# store this exact file as key rclone.conf in a Secret
[s3]
 type = s3
 provider = AWS
 env_auth = false
 access_key_id = REPLACE_ME
 secret_access_key = REPLACE_ME
 region = ap-south-1

[azure]
 type = azureblob
 account = REPLACE_ME
 key = REPLACE_ME

[gcs]
 type = google cloud storage
 project_number = REPLACE_ME
 # For Service Account JSON, set via RCLONE_CONFIG_GCS_SERVICE_ACCOUNT_CREDENTIALS env var instead
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-rclone-config
  namespace: vault
stringData:
  rclone.conf: |
    # paste the ini above with your real credentials or use env-based auth
```

> For GCS with a service account JSON, you can omit credentials in `rclone.conf` and provide `RCLONE_CONFIG_GCS_SERVICE_ACCOUNT_CREDENTIALS` env var with the JSON content via a separate Secret.

### 3.3 CronJob manifest (Raft snapshots → multi‑cloud via rclone)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vault-raft-backup
  namespace: vault
spec:
  schedule: "0 * * * *"    # hourly; adjust to your RPO
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          serviceAccountName: vault-backup-sa
          restartPolicy: Never
          containers:
          - name: backup
            image: alpine:3.20
            imagePullPolicy: IfNotPresent
            env:
              # Vault access
              - name: VAULT_ADDR
                value: "https://vault.vault.svc:8200"
              - name: VAULT_AUTH_MOUNT
                value: "auth/kubernetes"
              - name: VAULT_K8S_ROLE
                value: "vault-backup"

              # Choose one of: s3://, azure:, gcs:
              - name: TARGET_REMOTE
                value: "s3"      # change to azure or gcs for those remotes
              - name: TARGET_PATH
                value: "vault-backups/cluster-a/raft"   # remote prefix/folder

              # Optional: extra encryption of the artifact (age public key)
              - name: AGE_RECIPIENT
                value: ""   # e.g., age1... leave empty to skip

              # (Optional) For GCS JSON, inject whole JSON as an env var
              # - name: RCLONE_CONFIG_GCS_SERVICE_ACCOUNT_CREDENTIALS
              #   valueFrom:
              #     secretKeyRef:
              #       name: gcs-sa-json
              #       key: sa.json

            volumeMounts:
              - name: rclone-config
                mountPath: /etc/rclone
              - name: tmp
                mountPath: /work
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
            resources:
              requests:
                cpu: "100m"
                memory: "128Mi"
              limits:
                cpu: "500m"
                memory: "512Mi"
            command:
              - /bin/sh
              - -ceu
              - |
                set -euo pipefail
                apk add --no-cache curl jq rclone age bash coreutils

                cd /work
                TS=$(date -u +"%Y%m%dT%H%M%SZ")
                SNAP=raft-snapshot-${TS}.snap

                echo "[1/6] Login to Vault via Kubernetes auth"
                SA_JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
                LOGIN_JSON=$(curl -sS \
                  --request POST \
                  --data '{"role":"'"${VAULT_K8S_ROLE}"'","jwt":"'"${SA_JWT}"'"}' \
                  ${VAULT_ADDR}/${VAULT_AUTH_MOUNT}/login)
                VAULT_TOKEN=$(echo "$LOGIN_JSON" | jq -r .auth.client_token)
                export VAULT_TOKEN

                echo "[2/6] Create raft snapshot"
                # Use API to avoid depending on the vault CLI binary
                curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN}" \
                  -o ${SNAP} \
                  ${VAULT_ADDR}/v1/sys/storage/raft/snapshot

                echo "[3/6] Integrity hashes"
                sha256sum ${SNAP} | tee ${SNAP}.sha256
                md5sum ${SNAP} | tee ${SNAP}.md5

                if [ -n "${AGE_RECIPIENT}" ]; then
                  echo "[4/6] Optional: encrypting with age"
                  age -r "${AGE_RECIPIENT}" -o ${SNAP}.age ${SNAP}
                  ARTIFACT=${SNAP}.age
                else
                  ARTIFACT=${SNAP}
                fi

                echo "[5/6] Upload via rclone to ${TARGET_REMOTE}:${TARGET_PATH}"
                # Remote path includes year/month/day hierarchy for easy lifecycle rules
                KEY=${TARGET_PATH}/$(date -u +"%Y/%m/%d")/${SNAP}
                if [ -n "${AGE_RECIPIENT}" ]; then KEY=${KEY}.age; fi
                rclone copy ${ARTIFACT} ${TARGET_REMOTE}:${KEY} --config /etc/rclone/rclone.conf --s3-no-check-bucket
                rclone copy ${SNAP}.sha256 ${TARGET_REMOTE}:${KEY}.sha256 --config /etc/rclone/rclone.conf --s3-no-check-bucket
                rclone copy ${SNAP}.md5    ${TARGET_REMOTE}:${KEY}.md5    --config /etc/rclone/rclone.conf --s3-no-check-bucket

                echo "[6/6] Done: ${KEY}"

          volumes:
            - name: rclone-config
              secret:
                secretName: vault-rclone-config
            - name: tmp
              emptyDir: {}
```

**What this does**

* Authenticates with Vault using your pod’s SA token (bound to the `vault-backup` role).
* Calls the raft snapshot API and writes a timestamped `*.snap` file.
* Produces SHA256 and MD5 checksums.
* Optionally envelope‑encrypts with `age` (set `AGE_RECIPIENT`).
* Uploads artifact + checksums to the cloud bucket via rclone.
* Stores under `remote:TARGET_PATH/YYYY/MM/DD/raft-snapshot-<UTC>.snap[.age]` for easy lifecycle.

> For **Azure**, the remote URL is `azure:container/prefix`. For **S3**, `s3:bucket/prefix`. For **GCS**, `gcs:bucket/prefix`. With the sample `TARGET_PATH` above, set `TARGET_REMOTE` to `s3`, `azure`, or `gcs`.

---

## 4) Bucket‑side retention & immutability

Use **cloud lifecycle rules** so the CronJob doesn’t need delete permissions:

* **S3**: Lifecycle policy to **expire** and optionally **transition** to Glacier (e.g., keep 30 daily, 12 monthly, 7 yearly). Consider **Object Lock** (Compliance/WORM) if required.
* **Azure Blob**: Lifecycle Management rules for tiering/expiration. Consider **Immutable Blob Storage** for legal hold/WORM.
* **GCS**: Lifecycle rules for delete/transition, **Bucket Lock** for retention policies.

> Keep **at least one recent snapshot per day** and a few monthly/yearly; align with your RPO/RTO.

---

## 5) Health checks & alerting

* Emit **Kubernetes Events** and Container logs; scrape and alert on job **failures** (e.g., with Prometheus/Alertmanager).
* Alert on **missing artifacts** (e.g., S3 object count for today == 0).
* Periodic **restore‑test** (see §7) in non‑prod to validate snapshots.

---

## 6) Variant: use the Vault CLI instead of raw API

If you prefer the CLI, install the `vault` binary in the job image and run:

```bash
vault write -format=json ${VAULT_AUTH_MOUNT}/login role=${VAULT_K8S_ROLE} jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
  | jq -r .auth.client_token > /work/token
export VAULT_TOKEN=$(cat /work/token)

vault operator raft snapshot save /work/${SNAP}
```

Functionally equivalent to the API approach.

---

## 7) **Restore** procedures (Raft)

> Practice this in a disposable environment. Restores replace the entire data store.

**Scenario A — restoring to a fresh cluster**

1. Stand up Vault with **Integrated Storage**, initialized but **SEALED** (or uninitialized and in recovery flow per your bootstrap). Ensure `api_addr` and listener are correct.
2. Copy the snapshot to a pod with the `vault` binary (or curl approach) — or mount from a secured PVC.
3. Run (on the active node or via API to the active):

   ```bash
   export VAULT_ADDR="https://vault.vault.svc:8200"
   export VAULT_TOKEN=<recovery-root-token-or-sufficiently-privileged-token>
   vault operator raft snapshot restore -force /path/to/snapshot.snap
   ```
4. Unseal (if sealed) and start Vault. Confirm `vault status` → active/standby.
5. Validate: `vault kv list` / `vault kv get` for known paths; run your app smoke tests.

**Scenario B — in‑place replacement on an existing cluster**

* **Plan downtime**. Back up current state first.
* Stop traffic (or firewall off) and **seal** Vault.
* `vault operator raft snapshot restore -force ...` to replace the store.
* Unseal and verify.

**Notes**

* `-force` is required because restore is destructive.
* If you used **age** encryption, **decrypt** first (e.g., `age -d -i key.txt -o snapshot.snap snapshot.snap.age`).

---

## 8) Variant: Vault with **Consul** storage backend

If Vault uses Consul for storage, back up **Consul**, not Vault:

**Policy/auth**: Not required on Vault for snapshots. You need Consul ACLs sufficient to snapshot (usually operator or server‑side permissions).

**CronJob** (key steps):

```bash
consul snapshot save /work/consul-${TS}.snap \
  -http-addr=http://consul-server.consul.svc:8500 \
  -token=$CONSUL_HTTP_TOKEN
# then upload via rclone as shown earlier
```

**Restore**:

```bash
consul snapshot restore /path/consul-<TS>.snap \
  -http-addr=http://consul-server.consul.svc:8500 \
  -token=$CONSUL_HTTP_TOKEN
```

> After Consul restore, start Vault and verify as in §7.

---

## 9) Hardening & ops best practices

* **Network**: Restrict the CronJob pod egress so it can only reach Vault and the cloud bucket endpoint.
* **Secrets**: Mount creds as **projected service account tokens** (short‑lived), use CSI Secrets Store or external secret managers.
* **Scopes**: The Vault policy grants only `sys/storage/raft/snapshot`. Nothing else.
* **Audit**: Ensure Vault audit device(s) are enabled; monitor snapshot calls from this job.
* **TLS**: Always `https` with valid certs; pin CA bundle in the job image if needed.
* **Compression**: Snapshots are compact; consider `zstd` before upload if size matters.
* **Sharding**: For very large clusters, ensure job has enough CPU/mem and generous `activeDeadlineSeconds`.
* **Scheduling**: Run during off‑peak; ensure at least hourly/daily as per RPO.
* **Object layout**: Use `YYYY/MM/DD/` partitions; it simplifies lifecycle and audits.

---

## 10) Observability hooks (Prometheus / Grafana)

* **Exporters**: Scrape the batch job’s logs via Promtail/Fluent Bit or expose a tiny HTTP endpoint incrementing `backup_success_total` and `backup_failure_total`.
* **Alerts**:

  * No successful backups in 24h.
  * Snapshot size anomaly (too small/too big vs baseline).
  * Upload latency spikes / HTTP 5xx from bucket.

---

## 11) Testing checklist (copy/paste)

* [ ] Vault policy and k8s role created; token TTL reasonable (≤1h)
* [ ] CronJob runs and produces `*.snap` + checksums
* [ ] Cloud bucket shows objects in `YYYY/MM/DD/`
* [ ] Verify SHA256 on a downloaded artifact matches
* [ ] Perform quarterly restore test to a scratch cluster
* [ ] Document RPO/RTO and retention in runbooks

---

## 12) Troubleshooting

* **HTTP 403 from Vault** → The token lacks `sudo` on `sys/storage/raft/snapshot`. Re‑check policy/role.
* **Leader redirect loops** → Use the Vault Service VIP (not a single pod IP); ensure `api_addr` is correct.
* **TLS issues** → Provide CA bundle to curl/rclone or disable only for a test (`-k`)—do not keep insecure in prod.
* **Upload fails** → Check rclone remote config & network egress; validate IAM scoped to the container’s source IP.
* **GCS SA JSON parsing** → Prefer `RCLONE_CONFIG_GCS_SERVICE_ACCOUNT_CREDENTIALS` with full JSON.

---

## 13) Native‑CLI upload alternatives (samples)

**S3 (awscli)**

```bash
aws s3 cp ${ARTIFACT} s3://my-bucket/vault-backups/cluster-a/raft/${TS}/
```

**Azure (azcopy)**

```bash
azcopy copy ${ARTIFACT} "https://<account>.blob.core.windows.net/<container>/vault-backups/cluster-a/raft/${TS}/<file>?<SAS>"
```

**GCS (gsutil)**

```bash
gsutil cp ${ARTIFACT} gs://my-bucket/vault-backups/cluster-a/raft/${TS}/
```

---

## 14) Summary

* Use **Raft snapshots** (or **Consul snapshots** if applicable).
* Run an **internal CronJob** with **Kubernetes auth → least‑privileged policy**.
* Push to **Azure/S3/GCS** using rclone or native CLIs; manage retention with **bucket lifecycle**.
* **Test restores** regularly; treat snapshots as sensitive, optionally re‑encrypt.

This pattern is portable, cloud‑agnostic, and production‑ready with minimal moving parts.
