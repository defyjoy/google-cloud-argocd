# Vault Kubernetes Authentication Configuration

This document provides instructions for configuring Vault with Kubernetes authentication for the external-secrets operator.

## Manual Configuration Steps

### 1. Access Vault Pod

```bash
export KUBECONFIG=/Volumes/Workhub/Personal/Technology/Homelab/Proxmox/Proxmox/rke2.yaml
kubectl exec -it -n vault local-vault-0 -- sh
```

### 2. Set Vault Environment Variables

```bash
export VAULT_ADDR="http://localhost:8200"
export VAULT_SKIP_VERIFY="true"
```

### 3. Enable Kubernetes Authentication

```bash
vault auth enable kubernetes
```

### 4. Configure Kubernetes Authentication

```bash
vault write auth/kubernetes/config \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_host="https://kubernetes.default.svc.cluster.local" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  disable_iss_validation=true
```

### 5. Create Policies

#### External Secrets Policy

```bash
vault policy write external-secrets-policy - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list"]
}
EOF
```

#### Vault Agent Policy

```bash
vault policy write vault-agent-policy - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
EOF
```

### 6. Create Roles

#### External Secrets Role

```bash
vault write auth/kubernetes/role/external-secrets-operator \
  bound_service_account_names=local-external-secrets-operator \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-policy \
  ttl=24h
```

#### Vault Agent Injector Role

```bash
vault write auth/kubernetes/role/vault-agent-injector \
  bound_service_account_names=vault-agent-injector \
  bound_service_account_namespaces=vault \
  policies=vault-agent-policy \
  ttl=24h
```

### 7. Create Test Secrets

```bash
vault kv put kv/alarmify/local/cloudflared/token \
  token="test-cloudflare-api-token"
```

(The `cloudflared/` path segment is historical — it's the Cloudflare DNS API token external-dns
reads, not tunnel credentials; the Cloudflare Tunnel itself was removed. See
`helmcharts/vault/README.md`.)

### 8. Test Authentication

```bash
vault write auth/kubernetes/login \
  role=external-secrets-operator \
  jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
```

## Automated Configuration

The Helm chart includes templates for automated configuration:

- `kubernetes-auth-configmap.yaml`: Contains the configuration script
- `kubernetes-auth-job.yaml`: Runs the configuration as a Helm hook

To enable automated configuration, ensure `vaultConfig.kubernetesAuth.enabled: true` in your values.yaml.

## Verification

After configuration, verify that the external-secrets operator can authenticate:

```bash
kubectl logs -n external-secrets deployment/local-external-secrets-operator
```

You should see successful authentication messages instead of "context deadline exceeded" errors.

## Troubleshooting

### Common Issues

1. **Permission Denied**: Ensure Vault is unsealed and you have proper permissions
2. **Service Account Not Found**: Verify the service account exists in the correct namespace
3. **Authentication Failed**: Check that the Kubernetes auth method is properly configured
4. **Context Deadline Exceeded**: Usually indicates Vault connectivity or authentication issues

### Debug Commands

```bash
# Check Vault status
vault status

# List auth methods
vault auth list

# Check policies
vault policy list

# Test authentication
vault write auth/kubernetes/login role=external-secrets-operator jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
```
