# cert-manager Helm Chart

This Helm chart deploys cert-manager v1.19.1, a Kubernetes add-on that automatically manages and issues TLS certificates from various issuing sources.

## Features

- **Automated Certificate Management**: Automatically issues and renews TLS certificates
- **Multiple Issuer Types**: Support for Let's Encrypt, HashiCorp Vault, and other certificate authorities
- **Webhook Integration**: Secure webhook for certificate validation
- **Prometheus Monitoring**: Built-in metrics and ServiceMonitor integration
- **Security Hardened**: Runs with non-root user and restricted security contexts

## Prerequisites

- Kubernetes cluster (1.21+)
- Helm 3.x
- ArgoCD (for GitOps deployment)
- Cluster with cert-manager label enabled

## Installation

### Via ArgoCD ApplicationSet (Recommended)

This chart is designed to be deployed via ArgoCD using the ApplicationSet pattern. The applicationset is located at:

```
helmcharts/argocd-apps/templates/applicationsets/cert-manager-as.yaml
```

The ApplicationSet will automatically deploy cert-manager to clusters labeled with `cert-manager: "true"`.

### Manual Installation

```bash
# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version 1.19.1 \
  --set installCRDs=true
```

## Configuration

### Key Configuration Options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `cert-manager.installCRDs` | Install cert-manager CRDs | `true` |
| `cert-manager.global.leaderElection.namespace` | Leader election namespace | `cert-manager` |
| `cert-manager.prometheus.enabled` | Enable Prometheus monitoring | `true` |
| `cert-manager.webhook.enabled` | Enable webhook | `true` |
| `cert-manager.cainjector.enabled` | Enable CA injector | `true` |

> ⚠️ **This chart ships no `ClusterIssuer`.** The Proxmox repo this was forked from rendered one
> for a self-hosted Step CA; that was dropped along with the `stepca` chart. Nothing here issues
> a certificate until you add an `Issuer`/`ClusterIssuer` — on GCP that is typically Let's
> Encrypt with a DNS-01 solver against Cloud DNS.

### Security Configuration

The chart is configured with security best practices:
- Non-root user execution (UID 1000)
- Restricted security contexts
- Pod Security Standards compliance
- Seccomp profiles enabled

### Gateway API solver is required

```yaml
cert-manager:
  extraArgs:
    - --enable-gateway-api=true
```

Enables the **Gateway API HTTP-01 solver** for ACME. Required whenever a ClusterIssuer uses
`solvers.gatewayHTTPRoute`. Left on so a Gateway-based issuer works the moment one is added;
without the flag those challenges never get solved.

### Resources

```yaml
cert-manager:
  replicaCount: 1
  podDisruptionBudget:
    enabled: true
```

> 📉 **CPU limits halved on 2026-07-11** across all three components, measured against 24h peak
> usage per VictoriaMetrics: controller 3.2m, webhook 0.7m, cainjector 1.9m — each well under
> half the previous limit.

### Monitoring

cert-manager includes built-in Prometheus metrics:
- ServiceMonitor resource for Prometheus Operator
- Metrics endpoint on port 9402
- Default scrape interval of 60 seconds

> ⚠️ The ServiceMonitor must be **disabled on dev** — see below.

---

## dev overlay — `values/dev.yaml`

### ServiceMonitor must be off on dev

```yaml
cert-manager:
  prometheus:
    servicemonitor:
      enabled: false
```

> 🚫 **dev has no `kube-prometheus-stack`** — and therefore no Prometheus Operator CRDs at all.
> dev's metrics path is VictoriaMetrics VMAgent/VMPodScrape (§23). The chart's ServiceMonitor is
> gated behind cert-manager.io's own upstream values (nested under
> `cert-manager.prometheus.servicemonitor`), which **defaults to enabled** — leaving it on fails
> the sync with `could not find monitoring.coreos.com/ServiceMonitor CRD`.

The same trap applies to [`nats`](../nats/README.md) on dev.

## Certificate Issuers

After installation, you can create certificate issuers. Here are common examples:

### Let's Encrypt ClusterIssuer

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
```

### Let's Encrypt Staging ClusterIssuer

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
```

## Certificate Examples

### Basic Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: example-com
  namespace: default
spec:
  secretName: example-com-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - example.com
  - www.example.com
```

### Certificate with Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
  - hosts:
    - example.com
    secretName: example-com-tls
  rules:
  - host: example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: example-service
            port:
              number: 80
```

## Troubleshooting

### Common Issues

1. **Certificate Not Issued**: Check issuer status and ACME challenge
2. **Webhook Issues**: Verify webhook configuration and network policies
3. **DNS Issues**: Ensure DNS records point to your cluster
4. **Rate Limiting**: Use staging issuer for testing

### Debugging Commands

```bash
# Check cert-manager pods
kubectl get pods -n cert-manager

# Check certificate status
kubectl get certificates -A

# Check issuer status
kubectl get clusterissuers

# View certificate events
kubectl describe certificate <cert-name> -n <namespace>

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager
```

### Logs

```bash
# Check cert-manager controller logs
kubectl logs -n cert-manager -l app=cert-manager

# Check webhook logs
kubectl logs -n cert-manager -l app=webhook

# Check CA injector logs
kubectl logs -n cert-manager -l app=cainjector
```

## Upgrading

### Via ArgoCD

Update the chart version in `Chart.yaml` and commit the changes. ArgoCD will automatically sync the changes.

### Manual Upgrade

```bash
helm upgrade cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version 1.19.1
```

## Uninstalling

### Via ArgoCD

Delete the ApplicationSet from ArgoCD UI or remove the applicationset manifest from Git.

### Manual Uninstall

```bash
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager
```

## Additional Resources

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [cert-manager GitHub](https://github.com/cert-manager/cert-manager)
- [Let's Encrypt](https://letsencrypt.org/)
- [ACME Protocol](https://tools.ietf.org/html/rfc8555)

## Support

For support and questions:
- Check the [cert-manager Documentation](https://cert-manager.io/docs/)
- Visit the [cert-manager GitHub Issues](https://github.com/cert-manager/cert-manager/issues)
- Join the [cert-manager Slack](https://kubernetes.slack.com/channels/cert-manager)
