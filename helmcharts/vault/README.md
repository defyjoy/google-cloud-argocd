# HashiCorp Vault Helm Chart

This Helm chart deploys HashiCorp Vault in High Availability (HA) mode with production-ready configurations to your Kubernetes cluster.

**Operator docs (this repo):** [Vault Helm chart access — external URL, UI, CLI, Step CA TLS](https://github.com/Alarmify/alarmify-docs/blob/main/docs/vault/VAULT-HELM-CHART-ACCESS.md) · [Vault troubleshooting (incl. laptop CLI TLS)](https://github.com/Alarmify/alarmify-docs/blob/main/docs/vault/VAULT-TROUBLESHOOTING-PLAN.md).

## Features

- **High Availability**: 3-replica Raft-based cluster for fault tolerance
- **Integrated Storage**: Raft consensus protocol for data replication
- **Auto-scaling**: Pod disruption budgets and anti-affinity rules
- **Security**: TLS support, auto-unseal options, and security contexts
- **Monitoring**: Prometheus metrics and telemetry enabled
- **Audit Logging**: Persistent audit log storage
- **Vault Agent Injector**: Automatic secret injection into pods
- **UI Enabled**: Web interface for Vault management

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- Persistent Volume provisioner support in the underlying infrastructure
- (Optional) cert-manager for TLS certificate management
- (Optional) Ingress controller (nginx recommended)
- (Optional) Cloud KMS for auto-unseal (AWS KMS, GCP KMS, or Azure Key Vault)

## Architecture

This chart deploys Vault in HA mode with:
- **3 Vault server pods** using Raft storage for consensus
- **2 Vault agent injector pods** for secret injection
- **Persistent volumes** for data and audit logs
- **Service mesh ready** with proper service configuration

## Installation

### 1. Update Dependencies

```bash
helm dependency update
```

### 2. Configure Values

Edit `values.yaml` to customize your deployment:

#### Required Configuration Changes

1. **Ingress Hostname**: Update the ingress hostname
```yaml
vault:
  server:
    ingress:
      hosts:
        - host: vault.yourdomain.com
```

2. **Storage Class**: Set appropriate storage class for your cluster
```yaml
vault:
  server:
    dataStorage:
      storageClass: "fast-ssd"  # or your storage class name
```

3. **TLS Configuration**: For production, enable TLS
```yaml
vault:
  global:
    tlsDisable: false
```

### 3. Install the Chart

```bash
# Install in the vault namespace
helm install vault . -f values.yaml -n vault --create-namespace

# Or with custom values
helm install vault . -f values.yaml -f custom-values.yaml -n vault --create-namespace
```

## Post-Installation Steps

### 1. Initialize Vault

After installation, Vault needs to be initialized:

```bash
# Get a shell to the first Vault pod
kubectl exec -n vault vault-0 -- vault operator init

# Save the unseal keys and root token securely!
# Output will look like:
# Unseal Key 1: ...
# Unseal Key 2: ...
# Unseal Key 3: ...
# Unseal Key 4: ...
# Unseal Key 5: ...
# Initial Root Token: ...
```

**⚠️ IMPORTANT**: Store the unseal keys and root token in a secure location (e.g., password manager, encrypted storage). You'll need 3 out of 5 keys to unseal Vault.

### 2. Unseal Vault Pods

Vault starts in a sealed state. You need to unseal each pod:

```bash
# Unseal vault-0 (you need to provide 3 different unseal keys)
kubectl exec -n vault vault-0 -- vault operator unseal <key1>
kubectl exec -n vault vault-0 -- vault operator unseal <key2>
kubectl exec -n vault vault-0 -- vault operator unseal <key3>

# Repeat for vault-1 and vault-2
kubectl exec -n vault vault-1 -- vault operator unseal <key1>
kubectl exec -n vault vault-1 -- vault operator unseal <key2>
kubectl exec -n vault vault-1 -- vault operator unseal <key3>

kubectl exec -n vault vault-2 -- vault operator unseal <key1>
kubectl exec -n vault vault-2 -- vault operator unseal <key2>
kubectl exec -n vault vault-2 -- vault operator unseal <key3>
```

### 3. Join Raft Peers (if needed)

If pods don't automatically join the Raft cluster:

```bash
# From vault-1
kubectl exec -n vault vault-1 -- vault operator raft join http://vault-0.vault-internal:8200

# From vault-2
kubectl exec -n vault vault-2 -- vault operator raft join http://vault-0.vault-internal:8200
```

### 4. Configure Kubernetes Authentication

Enable Kubernetes auth method for the Vault Agent Injector:

```bash
# Login to Vault
kubectl exec -n vault vault-0 -- vault login <root-token>

# Enable Kubernetes auth
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

# Configure Kubernetes auth
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"
```

### 5. Enable Audit Logging

Configure audit logging to the persistent volume:

```bash
kubectl exec -n vault vault-0 -- vault audit enable file file_path=/vault/audit/audit.log
```

### 6. Seed bootstrap secrets

```bash
task provision-vault-secrets              # env local == management cluster
task provision-vault-secrets VAULT_ENV=dev
```

Some secrets have to exist in Vault before the cluster can reach Vault over the network.
cloudflared cannot serve `vault.workquark.org` until it has its tunnel credentials, and
those credentials live in Vault — so the public endpoint is unusable at exactly the moment
it is needed. dev makes this sharper: dev's `ClusterSecretStore` points at the *public*
`https://vault.workquark.org`, so a dev cluster whose tunnel credential is wrong can never
self-heal.

`scripts/vault/provision-vault-secrets.sh` breaks the cycle by running the `vault` CLI inside the
Vault pod over `kubectl exec` — that path goes through the API server and needs no tunnel,
Gateway or HTTPRoute. It writes to the active Raft node; a standby would only redirect.

The pod has no access to `~/.cloudflared`, so the two files are streamed in over the exec
stdin as a single JSON object and consumed by `vault kv put <path> -`:

```bash
{ printf '%s\n' "$VAULT_TOKEN"
  jq -n --rawfile cert "$CERT" --rawfile credentials "$CREDS" \
        '{cert: $cert, credentials: $credentials}'
} | kubectl exec -i -n vault local-vault-0 -- sh -c 'IFS= read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"' sh kv put "$CF_PATH" -
```

Nothing is written to the pod filesystem, and neither the root token nor the secret bodies
appear in `argv` — the token arrives as the first stdin line, the payload as the rest.

The field names `cert` and `credentials` are load-bearing: `helmcharts/cloudflared`'s
ExternalSecret reads them as `spec.data[].remoteRef.property`, and ESO fails the *whole*
ExternalSecret if either is missing.

The script refuses to write when `credentials.json`'s `TunnelID` does not match the tunnel
expected for that env (`local` → `9da192fd-…`, `dev` → `64478596-…`). cloudflared takes its
identity from `credentials.json`, **not** from the chart's `tunnelConfig.name`, so seeding
one cluster's credentials under another cluster's path silently puts both clusters' pods on
one tunnel — Cloudflare then load-balances hostnames onto connectors in the wrong cluster,
which answer with an empty-body 404 while every pod still reports healthy. That is exactly
what happened on 2026-07-30.

## Configuration

### High Availability Configuration

The chart is pre-configured for HA with:
- **3 replicas** for fault tolerance
- **Raft storage** for data replication
- **Pod anti-affinity** to distribute pods across nodes
- **Pod disruption budget** allowing max 1 unavailable pod

### Auto-Unseal Configuration

For production, configure auto-unseal to avoid manual unsealing. Uncomment the appropriate seal stanza in `values.yaml`:

#### AWS KMS Auto-Unseal

```yaml
vault:
  server:
    extraEnvironmentVars:
      AWS_REGION: us-east-1
    extraSecretEnvironmentVars:
      - envName: AWS_ACCESS_KEY_ID
        secretName: vault-aws-credentials
        secretKey: AWS_ACCESS_KEY_ID
      - envName: AWS_SECRET_ACCESS_KEY
        secretName: vault-aws-credentials
        secretKey: AWS_SECRET_ACCESS_KEY
    ha:
      raft:
        config: |
          # ... other config ...
          seal "awskms" {
            region     = "us-east-1"
            kms_key_id = "your-kms-key-id"
          }
```

#### GCP KMS Auto-Unseal

```yaml
vault:
  server:
    extraEnvironmentVars:
      GOOGLE_PROJECT: your-gcp-project
      GOOGLE_REGION: global
    ha:
      raft:
        config: |
          # ... other config ...
          seal "gcpckms" {
            project     = "your-gcp-project"
            region      = "global"
            key_ring    = "vault-keyring"
            crypto_key  = "vault-key"
          }
```

#### Azure Key Vault Auto-Unseal

```yaml
vault:
  server:
    ha:
      raft:
        config: |
          # ... other config ...
          seal "azurekeyvault" {
            tenant_id      = "your-tenant-id"
            vault_name     = "your-keyvault-name"
            key_name       = "vault-key"
          }
```

### TLS Configuration

For production, enable TLS:

1. Create TLS certificates (using cert-manager or manual):
```bash
# Using cert-manager (recommended)
# The ingress annotation cert-manager.io/cluster-issuer: "letsencrypt-prod" will auto-generate certificates
```

2. Update values.yaml:
```yaml
vault:
  global:
    tlsDisable: false
  server:
    ha:
      raft:
        config: |
          listener "tcp" {
            tls_disable = 0
            tls_cert_file = "/vault/tls/tls.crt"
            tls_key_file  = "/vault/tls/tls.key"
            address         = "[::]:8200"
            cluster_address = "[::]:8201"
          }
```

### Resource Configuration

Default resource limits (adjust based on your workload):

```yaml
vault:
  server:
    resources:
      requests:
        memory: 512Mi
        cpu: 500m
      limits:
        memory: 2Gi
        cpu: 2000m
  
  injector:
    resources:
      requests:
        memory: 256Mi
        cpu: 250m
      limits:
        memory: 512Mi
        cpu: 500m
```

### Storage Configuration

Configure persistent storage:

```yaml
vault:
  server:
    dataStorage:
      enabled: true
      size: 50Gi
      storageClass: "fast-ssd"  # Use your storage class
      accessMode: ReadWriteOnce
    
    auditStorage:
      enabled: true
      size: 20Gi
      storageClass: "fast-ssd"
```

## Using Vault Agent Injector

### Inject Secrets into Pods

Annotate your pods to automatically inject secrets:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: myapp
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "myapp-role"
    vault.hashicorp.com/agent-inject-secret-database: "secret/data/database/config"
    vault.hashicorp.com/agent-inject-template-database: |
      {{- with secret "secret/data/database/config" -}}
      {
        "username": "{{ .Data.data.username }}",
        "password": "{{ .Data.data.password }}"
      }
      {{- end }}
spec:
  serviceAccountName: myapp
  containers:
    - name: myapp
      image: myapp:latest
```

### Configure Vault Policy and Role

```bash
# Create policy
kubectl exec -n vault vault-0 -- vault policy write myapp-policy - <<EOF
path "secret/data/database/config" {
  capabilities = ["read"]
}
EOF

# Create Kubernetes auth role
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/myapp-role \
    bound_service_account_names=myapp \
    bound_service_account_namespaces=default \
    policies=myapp-policy \
    ttl=24h
```

## Monitoring and Metrics

### Prometheus Integration

Metrics are exposed at `/v1/sys/metrics` and can be scraped by Prometheus:

```yaml
# If using Prometheus Operator
vault:
  serverTelemetry:
    prometheusOperator: true
```

### Monitoring Vault Health

```bash
# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# Check Raft cluster status
kubectl exec -n vault vault-0 -- vault operator raft list-peers

# View logs
kubectl logs -n vault vault-0 -f
```

## Backup and Disaster Recovery

### Taking Raft Snapshots

```bash
# Take a snapshot
kubectl exec -n vault vault-0 -- vault operator raft snapshot save /tmp/vault-snapshot.snap

# Copy snapshot out of the pod
kubectl cp vault/vault-0:/tmp/vault-snapshot.snap ./vault-snapshot-$(date +%Y%m%d).snap
```

### Restoring from Snapshot

```bash
# Copy snapshot to pod
kubectl cp ./vault-snapshot.snap vault/vault-0:/tmp/vault-snapshot.snap

# Restore snapshot (WARNING: This will overwrite current data)
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/vault-snapshot.snap
```

### Automated Backups

Consider setting up a CronJob for automated backups:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vault-backup
  namespace: vault
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: vault
          containers:
          - name: backup
            image: hashicorp/vault:1.20.4
            command:
            - /bin/sh
            - -c
            - |
              vault operator raft snapshot save /backup/vault-snapshot-$(date +%Y%m%d-%H%M%S).snap
              # Upload to S3, GCS, or other storage
          restartPolicy: OnFailure
```

## Upgrading

### Upgrade Vault Version

1. Update the image tag in values.yaml:
```yaml
vault:
  server:
    image:
      tag: "1.21.0"  # New version
```

2. Perform rolling upgrade:
```bash
helm upgrade vault . -f values.yaml -n vault
```

### Migration Strategy

For major version upgrades:
1. Take a full snapshot backup
2. Test upgrade in staging environment
3. Perform upgrade during maintenance window
4. Verify all nodes are healthy and unsealed

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl get pods -n vault

# Check pod logs
kubectl logs -n vault vault-0

# Describe pod for events
kubectl describe pod -n vault vault-0
```

### Vault Sealed

```bash
# Check seal status
kubectl exec -n vault vault-0 -- vault status

# Unseal if needed
kubectl exec -n vault vault-0 -- vault operator unseal
```

### Raft Cluster Issues

```bash
# Check Raft peer list
kubectl exec -n vault vault-0 -- vault operator raft list-peers

# Remove dead peer
kubectl exec -n vault vault-0 -- vault operator raft remove-peer <peer-id>
```

### Performance Issues

1. Check resource utilization:
```bash
kubectl top pods -n vault
```

2. Review and adjust resource limits in values.yaml
3. Consider scaling horizontally (increase replicas)
4. Review audit log size and rotate if needed

## Security Best Practices

1. **Enable TLS**: Always use TLS in production (`tlsDisable: false`)
2. **Auto-Unseal**: Use cloud KMS for auto-unsealing
3. **Limit Root Token**: Revoke root token after initial setup
4. **Enable Audit Logs**: Always enable and monitor audit logs
5. **Network Policies**: Implement Kubernetes network policies
6. **RBAC**: Use Kubernetes RBAC to limit access to Vault pods
7. **Secrets Rotation**: Implement regular secret rotation policies
8. **Backup Encryption**: Encrypt Raft snapshots before storing

## Uninstall

```bash
# Uninstall the chart
helm uninstall vault -n vault

# Delete PVCs (WARNING: This deletes all data)
kubectl delete pvc -n vault -l app.kubernetes.io/name=vault

# Delete namespace
kubectl delete namespace vault
```

## Dependencies

This chart depends on the official HashiCorp Vault Helm chart:
- **Repository**: https://helm.releases.hashicorp.com
- **Chart**: vault
- **Version**: 0.31.0
- **App Version**: 1.20.4

## Resources

- [HashiCorp Vault Documentation](https://developer.hashicorp.com/vault/docs)
- [Vault on Kubernetes Guide](https://developer.hashicorp.com/vault/docs/platform/k8s)
- [Vault Helm Chart](https://github.com/hashicorp/vault-helm)
- [Vault Production Hardening](https://developer.hashicorp.com/vault/tutorials/operations/production-hardening)
- [Vault High Availability](https://developer.hashicorp.com/vault/docs/concepts/ha)
- [Raft Storage Backend](https://developer.hashicorp.com/vault/docs/configuration/storage/raft)

## Support

For issues and questions:
- HashiCorp Vault: https://github.com/hashicorp/vault/issues
- Vault Helm Chart: https://github.com/hashicorp/vault-helm/issues

---

## This deployment's configuration

### The `httproute` values block is unused

> 📌 `templates/httproute.yaml` **hardcodes** `parentRefs` to `istio-gateway`/`istio-system`
> along with the hostname and path (a Phase 3 special case). The corresponding block in
> `values.yaml` is inert — editing it changes nothing.

### Raft config is embedded HCL

`vault.server.ha.raft.config` is a YAML **block scalar** holding Vault's HCL configuration. The
`#` lines inside it are **HCL comments — part of the string value**, not YAML comments, and are
retained deliberately.

> ⚠️ `tls_disable = 1` is set. Fine for this cluster (TLS terminates at the gateway), but set it
> to false in any production deployment with proper TLS.

### Agent Injector resources

The injector is an admission webhook that is idle most of the time (~4m observed usage in
VictoriaMetrics), so it has been trimmed twice:

| Date | Change |
|---|---|
| 2026-07-10 | cpu `250m/500m` → `50m/250m`; memory untouched |
| 2026-07-11 | cpu limit halved again — 24h peak 2.5m |

The 2026-07-10 trim also freed request headroom to unblock `alarmify-ui` /
`alarmify-incident-api` waypoint scheduling, when the cluster's three schedulable nodes were at
97–99% CPU-request saturation.

### PodSecurity

`seccompProfile` is set on both the pod and the injector container — the chart's own defaults
omit the profile, which fails `restricted` PodSecurity.
