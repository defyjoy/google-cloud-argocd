# HashiCorp Vault Integration with External Secrets Operator

This document explains how to configure and use the External Secrets Operator with HashiCorp Vault to securely manage secrets for your applications.

## 🔧 Configuration Overview

The External Secrets Operator has been configured with comprehensive Vault integration support, including:

- **Vault SecretStore** configuration template
- **Multiple authentication methods** (Kubernetes, Token, AppRole, UserPass, LDAP, JWT)
- **TLS configuration** for secure communication
- **Flexible vault path** configuration

## 📋 Prerequisites

1. **HashiCorp Vault** deployed and accessible
2. **External Secrets Operator** deployed in your cluster
3. **Vault authentication** configured (recommended: Kubernetes auth)
4. **Secrets stored** in Vault at your configured path

## 🚀 Quick Start

### 1. Configure Vault SecretStore

The Vault SecretStore is automatically created when you deploy the external-secrets chart. The configuration is defined in the raw YAML template at `templates/vault-secretstore.yaml`:

```yaml
# templates/vault-secretstore.yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-secretstore
  namespace: external-secrets
spec:
  provider:
    vault:
      server: "https://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets-operator"
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

**To customize the configuration:**
1. Edit the `templates/vault-secretstore.yaml` file directly
2. Update the Vault server URL, path, and authentication settings
3. Redeploy the chart

### 2. Store Secrets in Vault

Store your secrets in Vault using the configured path:

```bash
# Example: Store cloudflared credentials
vault kv put secret/cloudflared/credentials \
  tunnel_id="your-tunnel-id" \
  tunnel_name="your-tunnel-name" \
  tunnel_secret="your-tunnel-secret"
```

### 3. Configure ExternalSecret

Create ExternalSecret resources to pull secrets from Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secrets
  namespace: my-namespace
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-secretstore
    kind: SecretStore
  target:
    name: my-app-secrets
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: secret/my-app
        property: username
    - secretKey: password
      remoteRef:
        key: secret/my-app
        property: password
```

## 🔐 Authentication Methods

### Kubernetes Authentication (Recommended)

This is the most secure and recommended method:

```yaml
vault:
  auth:
    kubernetes:
      enabled: true
      mountPath: "kubernetes"
      role: "external-secrets-operator"
      serviceAccount:
        name: "external-secrets"
        namespace: "external-secrets"
```

**Vault Configuration Required:**
```bash
# Enable Kubernetes auth
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://kubernetes.default.svc.cluster.local" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Create role for external-secrets
vault write auth/kubernetes/role/external-secrets-operator \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-policy \
  ttl=24h
```

### Token Authentication

For development or simple setups:

```yaml
vault:
  auth:
    token:
      enabled: true
      secretName: "vault-token"
      secretKey: "token"
```

Create the token secret:
```bash
kubectl create secret generic vault-token \
  --from-literal=token="your-vault-token" \
  -n external-secrets
```

### AppRole Authentication

For automated systems:

```yaml
vault:
  auth:
    appRole:
      enabled: true
      roleId: "your-role-id"
      secretName: "vault-approle-secret"
      secretKey: "secret-id"
```

## 🏗️ Cloudflared Integration Example

The cloudflared chart includes an ExternalSecret template that automatically pulls credentials from Vault:

### 1. Store Cloudflared Credentials in Vault

```bash
vault kv put secret/cloudflared/credentials \
  cert="-----BEGIN CERTIFICATE-----\nYour certificate content here\n-----END CERTIFICATE-----" \
  credentials='{"AccountTag":"your-account-tag","TunnelSecret":"your-tunnel-secret","TunnelID":"your-tunnel-id"}'
```

### 2. Enable ExternalSecret in Cloudflared

The ExternalSecret is automatically created when you deploy the cloudflared chart. The configuration is defined in the raw YAML template at `templates/externalsecret.yaml`:

```yaml
# templates/externalsecret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: cloudflared-credentials
  namespace: cloudflared
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-secretstore
    kind: SecretStore
  target:
    name: cloudflared-credentials
    creationPolicy: Owner
  data:
    - secretKey: cert.pem
      remoteRef:
        key: /cloudflared/credentials
        property: cert
    - secretKey: credentials.json
      remoteRef:
        key: /cloudflared/credentials
        property: credentials
```

**To customize the configuration:**
1. Edit the `templates/externalsecret.yaml` file directly
2. Update the Vault path and secret keys as needed
3. Redeploy the chart

### 3. Deploy Cloudflared

The ExternalSecret will automatically:
- Pull credentials from Vault
- Create a Kubernetes secret named `cloudflared-credentials`
- Cloudflared will use the generated secret

## 🔒 Security Best Practices

### 1. Least Privilege Access

Create minimal Vault policies:

```hcl
# external-secrets-policy.hcl
path "secret/data/*" {
  capabilities = ["read"]
}

path "secret/metadata/*" {
  capabilities = ["list"]
}
```

Apply the policy:
```bash
vault policy write external-secrets-policy external-secrets-policy.hcl
```

### 2. TLS Configuration

Enable TLS for secure communication:

```yaml
vault:
  tls:
    enabled: true
    certSecretRef:
      name: "vault-ca"
      key: "tls.crt"
  caProvider:
    type: "Secret"
    name: "vault-ca"
    key: "ca.crt"
```

### 3. Secret Rotation

Configure appropriate refresh intervals:

```yaml
# Refresh every hour
refreshInterval: "1h"

# Or for critical secrets, refresh more frequently
refreshInterval: "5m"
```

## 🔍 Troubleshooting

### Common Issues

#### 1. Authentication Failures

**Check Vault logs:**
```bash
vault auth list
vault read auth/kubernetes/config
```

**Verify service account:**
```bash
kubectl get serviceaccount external-secrets -n external-secrets
kubectl describe serviceaccount external-secrets -n external-secrets
```

#### 2. Secret Not Found

**Check Vault path:**
```bash
vault kv get secret/your-path
vault kv list secret/
```

**Verify ExternalSecret status:**
```bash
kubectl describe externalsecret my-secret -n my-namespace
kubectl get events -n my-namespace
```

#### 3. TLS Issues

**Verify certificates:**
```bash
kubectl get secret vault-ca -n external-secrets
kubectl describe secret vault-ca -n external-secrets
```

### Debug Commands

```bash
# Check External Secrets Operator logs
kubectl logs -n external-secrets deployment/external-secrets

# Check SecretStore status
kubectl describe secretstore vault-secretstore -n external-secrets

# Check ExternalSecret status
kubectl describe externalsecret my-secret -n my-namespace

# Check generated secrets
kubectl get secrets -n my-namespace
kubectl describe secret my-secret -n my-namespace
```

## 📊 Monitoring

### Key Metrics

Monitor these External Secrets Operator metrics:

- `external_secrets_sync_calls_total` - Number of sync operations
- `external_secrets_sync_duration_seconds` - Sync operation duration
- `external_secrets_secret_sync_calls_total` - Secret-specific sync calls
- `external_secrets_webhook_requests_total` - Webhook requests

### Prometheus Queries

```promql
# Sync success rate
rate(external_secrets_sync_calls_total{status="success"}[5m])

# Sync duration
histogram_quantile(0.95, rate(external_secrets_sync_duration_seconds_bucket[5m]))

# Failed syncs
rate(external_secrets_sync_calls_total{status="error"}[5m])
```

## 🔄 Maintenance

### Regular Tasks

1. **Monitor secret expiry** in Vault
2. **Review ExternalSecret refresh intervals**
3. **Check authentication token expiry**
4. **Update Vault policies** as needed
5. **Monitor External Secrets Operator metrics**

### Upgrade Procedure

1. **Backup Vault policies and secrets**
2. **Update External Secrets Operator**
3. **Verify SecretStore configuration**
4. **Test ExternalSecret functionality**
5. **Monitor for any issues**

## 📚 Additional Resources

- [External Secrets Operator Documentation](https://external-secrets.io/)
- [HashiCorp Vault Documentation](https://www.vaultproject.io/docs)
- [Kubernetes Authentication with Vault](https://www.vaultproject.io/docs/auth/kubernetes)
- [External Secrets Operator Vault Provider](https://external-secrets.io/v0.8.5/api/vault/)

---

**Last Updated:** October 19, 2025  
**Version:** 1.0
