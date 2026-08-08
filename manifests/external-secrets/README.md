# External Secrets Operator Manifests

This directory contains example manifests for the External Secrets Operator.

## Files

- `aws-secrets-manager-secretstore.yaml` - Example SecretStore for AWS Secrets Manager
- `vault-secretstore.yaml` - Example SecretStore for HashiCorp Vault
- `example-externalsecret.yaml` - Example ExternalSecret resource

## Usage

### 1. Create a SecretStore

First, create a SecretStore to configure access to your external secret management system:

```bash
kubectl apply -f aws-secrets-manager-secretstore.yaml
```

### 2. Create an ExternalSecret

Then, create an ExternalSecret to sync secrets from the external system:

```bash
kubectl apply -f example-externalsecret.yaml
```

### 3. Verify the Secret

Check that the secret was created:

```bash
kubectl get secrets -n external-secrets
kubectl describe secret my-kubernetes-secret -n external-secrets
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

## Security Best Practices

1. **Use dedicated service accounts** with minimal required permissions
2. **Rotate credentials regularly** for external secret management systems
3. **Use namespaced SecretStores** when possible instead of ClusterSecretStores
4. **Enable webhook validation** for ExternalSecret resources
5. **Monitor secret sync status** using the operator's metrics
6. **Use least privilege access** for external secret management systems
7. **Encrypt secrets in transit and at rest**
8. **Regularly audit secret access** and usage

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

## References

- [External Secrets Operator Documentation](https://external-secrets.io/)
- [External Secrets Operator GitHub](https://github.com/external-secrets/external-secrets)
- [External Secrets Operator Helm Chart](https://github.com/external-secrets/external-secrets/tree/main/deploy/charts/external-secrets)
