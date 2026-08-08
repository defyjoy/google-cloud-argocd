# External Secrets Operator Helm Chart

This Helm chart deploys the External Secrets Operator, which is a Kubernetes operator that integrates with external secret management systems like AWS Secrets Manager, HashiCorp Vault, Google Secret Manager, Azure Key Vault, and many more.

## Overview

The External Secrets Operator reads information from external APIs and automatically injects the values into a Kubernetes Secret. Each Secret is synced with the external secret management system.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.2.0+
- RBAC enabled cluster

## Installation

### Add the Helm Repository

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
```

### Install the Chart

```bash
helm install external-secrets ./external-secrets \
  --namespace external-secrets \
  --create-namespace
```

## Configuration

The following table lists the configurable parameters and their default values:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `enabled` | Enable the external-secrets chart | `true` |
| `external-secrets.installCRDs` | Install Custom Resource Definitions | `true` |
| `external-secrets.externalSecrets.image.repository` | Image repository | `external-secrets/external-secrets` |
| `external-secrets.externalSecrets.image.tag` | Image tag | `v0.10.0` |
| `external-secrets.externalSecrets.image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `external-secrets.externalSecrets.resources.limits.cpu` | CPU limit | `100m` |
| `external-secrets.externalSecrets.resources.limits.memory` | Memory limit | `128Mi` |
| `external-secrets.externalSecrets.resources.requests.cpu` | CPU request | `50m` |
| `external-secrets.externalSecrets.resources.requests.memory` | Memory request | `64Mi` |
| `external-secrets.externalSecrets.metrics.enabled` | Enable metrics | `true` |
| `external-secrets.externalSecrets.metrics.serviceMonitor.enabled` | Enable ServiceMonitor | `true` |
| `external-secrets.externalSecrets.webhook.enabled` | Enable webhook | `true` |
| `external-secrets.externalSecrets.rbac.create` | Create RBAC resources | `true` |
| `external-secrets.externalSecrets.rbac.serviceAccount.create` | Create service account | `true` |
| `external-secrets.externalSecrets.security.podSecurityContext.runAsNonRoot` | Run as non-root user | `true` |
| `external-secrets.externalSecrets.security.podSecurityContext.runAsUser` | User ID | `65534` |
| `external-secrets.externalSecrets.security.containerSecurityContext.allowPrivilegeEscalation` | Allow privilege escalation | `false` |
| `external-secrets.externalSecrets.security.containerSecurityContext.readOnlyRootFilesystem` | Read-only root filesystem | `true` |
| `external-secrets.externalSecrets.security.containerSecurityContext.capabilities.drop` | Drop capabilities | `["ALL"]` |

## Usage

### Create a SecretStore

First, create a SecretStore to configure access to your external secret management system:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: external-secrets
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        secretRef:
          accessKeyIDSecretRef:
            name: aws-credentials
            key: access-key
          secretAccessKeySecretRef:
            name: aws-credentials
            key: secret-access-key
```

### Create an ExternalSecret

Then, create an ExternalSecret to sync secrets from the external system:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-secret
  namespace: external-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: my-kubernetes-secret
  data:
    - secretKey: username
      remoteRef:
        key: /path/to/secret
        property: username
    - secretKey: password
      remoteRef:
        key: /path/to/secret
        property: password
```

## HashiCorp Vault Integration

### 🚨 The Vault address differs per cluster — deliberately

```yaml
# values.yaml (management) — in-cluster Service DNS
vaultClusterSecretStore:
  vault:
    server: "http://local-vault.vault.svc.cluster.local:8200"
```

```yaml
# values/dev.yaml — public hostname, accepted risk
vaultClusterSecretStore:
  vault:
    server: "https://vault.workquark.org"
```

**Management must never use the public hostname.** Vault runs in that same cluster, so it never
needs to route out through Cloudflare at all. Pointing it at `vault.workquark.org` creates a
**circular dependency**: external-dns and external-secrets need Vault to obtain their Cloudflare
API token, but Vault would then be reachable *only through* Cloudflare's tunnel — so a single
Cloudflare or DNS hiccup takes out Vault access cluster-wide with no independent path to
recover it.

> 💥 This was confirmed as the **actual root cause of the 2026-07-19 outage** that took down
> `ui.workquark.org`, `harbor.workquark.org` and `zitadel.workquark.org`.

dev has no local Vault and therefore *must* use the public hostname. That cross-cluster
dependency is a known, accepted risk **for dev only** — which is precisely why the two clusters
must not share a default.

### Token secret is created out-of-band

Token auth references the Secret named by `tokenSecret.name` in `tokenSecret.namespace`.

> 🔐 **Never store Vault tokens in this repo or in Helm values.** Create the Secret separately —
> `kubectl create secret generic vault-token …`, SealedSecrets, SOPS, or your secrets pipeline.

### dev resource overrides

```yaml
# values/dev.yaml
external-secrets:
  externalSecrets:
    resources:
      requests: { cpu: 25m, memory: 32Mi }
      limits:   { cpu: 50m, memory: 64Mi }
    webhook:
      resources: { … same … }
    logLevel: debug
```

dev runs a smaller footprint than management.

> ⏳ **`logLevel: debug` is not the default** and is worth reviewing — it is the only chart in
> this repo shipping debug logging as steady state.

### Quick Start - Token Generation

**Fastest way to get started:**

```bash
# 1. Generate Vault token using Task (repository root)
# cd /path/to/ArgoCD
task hashicorp-vault                    # Initialize and unseal Vault
task hashicorp-vault-create-secret      # Create token secret

# 2. Deploy External Secrets Operator
cd ../../external-secrets
helm install external-secrets . --namespace external-secrets --create-namespace

# 3. Deploy Vault SecretStore
kubectl apply -f templates/vault-secretstore.yaml
```

**Manual token generation:**
```bash
# Get root token from Vault
kubectl exec -it -n vault local-vault-0 -- vault status
kubectl exec -it -n vault local-vault-0 -- vault operator init -key-shares=5 -key-threshold=3

# Create token secret
kubectl create secret generic vault-token \
  --from-literal=token="<your-vault-token>" \
  --namespace=external-secrets
```

### Prerequisites

Before using HashiCorp Vault with External Secrets Operator, ensure:

1. **Vault is deployed and accessible** in your cluster
2. **Vault is initialized and unsealed** (see Vault management tasks below)
3. **Vault token is available** for authentication
4. **External Secrets Operator is installed** in the cluster

### Complete Workflow

Here's the complete workflow to set up Vault integration with External Secrets Operator:

```bash
# 1. Deploy and initialize Vault (from repository root)
task hashicorp-vault

# 2. Create vault-token secret for External Secrets Operator
task hashicorp-vault-create-secret

# 3. Deploy External Secrets Operator (if not already deployed)
cd ../../external-secrets
helm install external-secrets . \
  --namespace external-secrets \
  --create-namespace

# 4. Deploy Vault SecretStore
kubectl apply -f templates/vault-secretstore.yaml

# 5. Create ExternalSecrets to sync secrets from Vault
# (See examples below)
```

### Generating Vault Token

There are several methods to generate and obtain a Vault token for External Secrets Operator authentication:

#### Method 1: Using ArgoCD Bootstrap Taskfile (Recommended)

If you have the repository root `Taskfile.yml` available, use the built-in Vault management tasks:

```bash
# From repository root — run the complete Vault management workflow
task hashicorp-vault

# Or run individual tasks
task hashicorp-vault-init    # Initialize Vault (if not already done)
task hashicorp-vault-unseal  # Unseal Vault pods
task hashicorp-vault-status  # Display token and keys
```

The `hashicorp-vault-status` task will display:
- Root token for Vault authentication
- Unseal keys (store securely)
- Vault status for all pods

#### Method 2: Manual Vault Initialization and Token Generation

If Vault is not yet initialized, initialize it manually:

```bash
# Login to the Vault pod
kubectl exec -it -n vault local-vault-0 -- /bin/sh

# Check Vault status
vault status

# If Vault is not initialized, initialize it
vault operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/vault-init.json

# Save the initialization output (contains root token and unseal keys)
cat /tmp/vault-init.json

# Copy the initialization data to your local machine.
# Use exactly this destination path — `hashicorp-vault-init.json` is the only
# filename covered by .gitignore. Copying it to ./vault-init.json (or any other
# name) leaves the root token and all five unseal keys tracked and committable.
exit
kubectl cp vault/local-vault-0:/tmp/vault-init.json \
  ./helmcharts/argocd/bootstrap/hashicorp-vault-init.json
```

The initialization output will contain:
```json
{
  "unseal_keys_b64": ["key1", "key2", "key3", "key4", "key5"],
  "unseal_keys_hex": ["hex1", "hex2", "hex3", "hex4", "hex5"],
  "unseal_shares": 5,
  "unseal_threshold": 3,
  "recovery_keys_b64": [],
  "recovery_keys_hex": [],
  "recovery_keys_shares": 0,
  "recovery_keys_threshold": 0,
  "root_token": "hvs.xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```

#### Method 3: Unsealing Vault and Getting Root Token

If Vault is already initialized but sealed:

```bash
# Login to the Vault pod
kubectl exec -it -n vault local-vault-0 -- /bin/sh

# Check Vault status
vault status

# Unseal Vault using the unseal keys (need 3 out of 5)
vault operator unseal <unseal-key-1>
vault operator unseal <unseal-key-2>
vault operator unseal <unseal-key-3>

# Verify Vault is unsealed
vault status

# If you have the root token, set it
export VAULT_TOKEN=<your-root-token>
vault auth -method=token token=$VAULT_TOKEN

# Verify access
vault kv list secret/
```

#### Method 4: Creating a New Token (Non-Root)

For production environments, it's recommended to create a dedicated token instead of using the root token:

```bash
# Login to Vault with root token
kubectl exec -it -n vault local-vault-0 -- /bin/sh
export VAULT_TOKEN=<your-root-token>

# Create a policy for External Secrets Operator
vault policy write external-secrets - <<EOF
path "secret/*" {
  capabilities = ["read"]
}

path "kv/*" {
  capabilities = ["read"]
}
EOF

# Create a token with the policy
vault token create -policy=external-secrets -format=json > /tmp/external-secrets-token.json

# Extract the token
cat /tmp/external-secrets-token.json | jq -r '.auth.client_token'
```

#### Method 5: Using Vault UI

If Vault UI is accessible:

1. Open Vault UI in your browser (usually `https://vault.your-domain.com:8200`)
2. Login with your root token
3. Navigate to **Access** → **Tokens** → **Create Token**
4. Configure the token:
   - **Token type**: Service
   - **Policies**: Select appropriate policies (e.g., `external-secrets`)
   - **TTL**: Set appropriate expiration time
5. Click **Create Token**
6. Copy the generated token

#### Method 6: Using Vault CLI with Service Account

For automated environments:

```bash
# Create a service account token (if using Kubernetes auth)
kubectl create serviceaccount external-secrets -n external-secrets

# Create a Vault role for the service account
kubectl exec -it -n vault local-vault-0 -- /bin/sh
export VAULT_TOKEN=<your-root-token>

# Enable Kubernetes auth (if not already enabled)
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://kubernetes.default.svc.cluster.local" \
  kubernetes_ca_cert="$(cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)"

# Create a role for External Secrets Operator
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets \
  ttl=1h
```

### Token Security Best Practices

1. **Use Non-Root Tokens**: Create dedicated tokens with minimal required permissions
2. **Set Appropriate TTL**: Use short-lived tokens when possible
3. **Rotate Tokens Regularly**: Implement token rotation in production
4. **Store Tokens Securely**: Use Kubernetes secrets or external secret management
5. **Monitor Token Usage**: Enable Vault audit logs
6. **Use Policies**: Create specific policies for different applications

### Creating Vault Token Secret

Once you have the Vault token, create a Kubernetes secret for External Secrets Operator.

Never paste a real token into this file — or any file in this repo. The authoritative
copy of the Vault init output (root token and unseal keys) lives in
`helmcharts/argocd/bootstrap/hashicorp-vault-init.json`, which is gitignored; read the
token from there at the moment you need it rather than transcribing it. See
`helmcharts/argocd/bootstrap/hashicorp-vault-init.example.json` for the file's shape.

#### Method 1: Using kubectl

```bash
# Read the root token straight out of the gitignored init file
VAULT_TOKEN="$(jq -r '.root_token' helmcharts/argocd/bootstrap/hashicorp-vault-init.json)"

# Create the vault-token secret
kubectl create secret generic vault-token \
  --from-literal=token="$VAULT_TOKEN" \
  --namespace=external-secrets
```

If you are typing the value by hand instead, it looks like
`hvs.EXAMPLE_ROOT_TOKEN_REDACTED` — substitute your own and do not commit it.

#### Method 2: Using YAML manifest

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: external-secrets
type: Opaque
data:
  token: <base64-encoded-vault-token>
```

To encode the token:
```bash
echo -n "<your-vault-token>" | base64
```

#### Method 3: Using the Taskfile (Automated)

The ArgoCD bootstrap Taskfile can automatically create the secret:

```bash
# From repository root — create the vault-token secret automatically
task hashicorp-vault-create-secret
```

This task will:
- Extract the root token from `hashicorp-vault-init.json`
- Create or update the `vault-token` secret in the `external-secrets` namespace
- Verify the secret was created successfully
- Provide next steps for deployment

### Vault SecretStore Configuration

The chart includes a pre-configured Vault SecretStore template. Here's how to use it:

#### Basic Configuration

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-secretstore
spec:
  provider:
    vault:
      server: "http://local-vault.vault.svc.cluster.local:8200"
      path: "kv"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          key: token
          namespace: external-secrets
```

#### Production Configuration (with TLS)

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-secretstore
spec:
  provider:
    vault:
      server: "https://vault.your-domain.com:8200"
      path: "kv"
      version: "v2"
      auth:
        tokenSecretRef:
          name: vault-token
          key: token
          namespace: external-secrets
      caProvider:
        type: Secret
        name: vault-ca
        key: ca.crt
```

### Creating ExternalSecret for Vault

Once the SecretStore is configured, create ExternalSecrets to sync secrets:

#### Basic Example

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-vault-secret
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-secretstore
    kind: ClusterSecretStore
  target:
    name: my-kubernetes-secret
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: secret/myapp
        property: username
    - secretKey: password
      remoteRef:
        key: secret/myapp
        property: password
```

#### Advanced Example with Template

The chart includes an example ExternalSecret template (`templates/example-externalsecret.yaml`) that demonstrates:

- Multiple secret sources from different Vault paths
- Secret templating with labels and annotations
- Different data types and structures

To use the example:

```bash
# Deploy the example ExternalSecret
kubectl apply -f templates/example-externalsecret.yaml

# Check the status
kubectl get externalsecret example-vault-secret
kubectl describe externalsecret example-vault-secret

# Check the generated secret
kubectl get secret example-kubernetes-secret
kubectl describe secret example-kubernetes-secret
```

**Note**: Before deploying the example, ensure you have the corresponding secrets in Vault:

```bash
# Login to Vault
kubectl exec -it -n vault local-vault-0 -- /bin/sh

# Create example secrets
vault kv put secret/myapp username="admin" password="secret123"
vault kv put secret/database url="postgresql://user:pass@db:5432/mydb"
vault kv put secret/api-keys github="ghp_xxx" slack="xoxb-xxx"
```

### Vault Secret Path Structure

For KV v2 engine, secrets are stored with the following structure:

```
secret/
├── myapp/
│   ├── username: "admin"
│   └── password: "secret123"
├── database/
│   ├── host: "db.example.com"
│   ├── port: "5432"
│   └── credentials: "user:pass"
└── api-keys/
    ├── github: "ghp_xxx"
    └── slack: "xoxb-xxx"
```

### Troubleshooting Vault Integration

#### Check Vault Connectivity

```bash
# Test Vault connectivity from within the cluster
kubectl run vault-test --image=curlimages/curl --rm -it --restart=Never -- \
  curl -k http://local-vault.vault.svc.cluster.local:8200/v1/sys/health
```

#### Check SecretStore Status

```bash
# Check SecretStore status
kubectl get clustersecretstore vault-secretstore
kubectl describe clustersecretstore vault-secretstore

# Check for authentication errors
kubectl logs -n external-secrets deployment/external-secrets | grep -i vault
```

#### Check ExternalSecret Status

```bash
# Check ExternalSecret status
kubectl get externalsecret -A
kubectl describe externalsecret my-vault-secret

# Check generated secrets
kubectl get secrets
kubectl describe secret my-kubernetes-secret
```

#### Common Issues

1. **Vault not accessible**: Check Vault service and network policies
2. **Authentication failed**: Verify token secret exists and is correct
3. **Permission denied**: Check Vault token permissions and policies
4. **Secret not found**: Verify secret path and key names in Vault

#### Token Generation Issues

**Problem**: Cannot initialize Vault
```bash
# Check if Vault is already initialized
kubectl exec -n vault local-vault-0 -- vault status

# If already initialized, get existing token
kubectl exec -n vault local-vault-0 -- vault auth -method=token token=<existing-token>
```

**Problem**: Vault is sealed
```bash
# Unseal Vault using unseal keys
kubectl exec -n vault local-vault-0 -- vault operator unseal <key1>
kubectl exec -n vault local-vault-0 -- vault operator unseal <key2>
kubectl exec -n vault local-vault-0 -- vault operator unseal <key3>
```

**Problem**: Token secret creation fails
```bash
# Check if namespace exists
kubectl get namespace external-secrets

# Create namespace if needed
kubectl create namespace external-secrets

# Verify token format
echo -n "<your-token>" | wc -c  # Should be around 24 characters for root tokens
```

**Problem**: Token has insufficient permissions
```bash
# Check token capabilities
kubectl exec -n vault local-vault-0 -- vault token capabilities <your-token> secret/

# Create a policy with proper permissions
kubectl exec -n vault local-vault-0 -- vault policy write external-secrets - <<EOF
path "secret/*" {
  capabilities = ["read"]
}
path "kv/*" {
  capabilities = ["read"]
}
EOF
```

## Supported Providers

The External Secrets Operator supports many external secret management systems:

- AWS Secrets Manager
- AWS Parameter Store
- HashiCorp Vault
- Google Secret Manager
- Azure Key Vault
- IBM Cloud Secrets Manager
- Oracle Cloud Infrastructure Vault
- Yandex Lockbox
- Kubernetes Secrets
- And many more...

## Security

This chart is configured with security best practices:

- Runs as non-root user (65534)
- Read-only root filesystem
- Drops all capabilities
- Uses Pod Security Standards
- Implements security contexts
- Uses RBAC for authorization

## Monitoring

The chart includes monitoring capabilities:

- Prometheus metrics endpoint
- ServiceMonitor for Prometheus
- PodMonitor for Prometheus
- PrometheusRule for alerting
- Grafana dashboard support

## Troubleshooting

### Check Operator Status

```bash
kubectl get pods -n external-secrets
kubectl logs -n external-secrets deployment/external-secrets
```

### Check SecretStore Status

```bash
kubectl get secretstore -n external-secrets
kubectl describe secretstore aws-secrets-manager -n external-secrets
```

### Check ExternalSecret Status

```bash
kubectl get externalsecret -n external-secrets
kubectl describe externalsecret my-secret -n external-secrets
```

### Check Generated Secrets

```bash
kubectl get secrets -n external-secrets
kubectl describe secret my-kubernetes-secret -n external-secrets
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test your changes
5. Submit a pull request

## License

This chart is licensed under the Apache 2.0 License.
