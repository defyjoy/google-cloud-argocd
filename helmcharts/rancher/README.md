# Rancher Helm Chart

This Helm chart deploys Rancher v2.12.3, a complete software stack for teams adopting containers. Rancher addresses the operational and security challenges of managing multiple Kubernetes clusters across any infrastructure.

## Features

- **Multi-Cluster Management**: Manage multiple Kubernetes clusters from a single interface
- **Application Management**: Deploy and manage applications using Helm charts and GitOps
- **Security**: Built-in RBAC, policy management, and security scanning
- **Monitoring**: Integrated monitoring and alerting capabilities
- **CI/CD**: Built-in CI/CD pipelines and GitOps workflows

## Prerequisites

- Kubernetes cluster (1.21+)
- Helm 3.x
- ArgoCD (for GitOps deployment)
- Ingress controller (nginx recommended)
- Cert-manager (for TLS certificates)
- External-DNS (for DNS management)

## Installation

### Via ArgoCD (Recommended)

This chart is designed to be deployed via ArgoCD using GitOps principles. The application manifest is located at:

```
helmcharts/argocd-apps/templates/applications/rancher.yaml
```

### Manual Installation

```bash
# Add the Rancher Helm repository
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update

# Install Rancher
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --create-namespace \
  --set hostname=rancher.example.com \
  --set replicas=3 \
  --version 2.12.3
```

## Configuration

### Key Configuration Options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `rancher.hostname` | Rancher server hostname | `rancher.workquark.org` |
| `rancher.replicas` | Number of Rancher replicas | `3` |
| `rancher.tls` | TLS configuration | `ingress` |
| `rancher.persistence.enabled` | Enable persistent storage | `true` |
| `rancher.monitoring.enabled` | Enable monitoring | `true` |

### Ingress Configuration

The chart is configured to use nginx ingress with the following features:
- Automatic TLS certificate management via cert-manager
- External-DNS integration for automatic DNS record creation
- SSL redirect and backend protocol configuration

### High Availability

Rancher is configured for high availability with:
- 3 replicas by default
- Pod anti-affinity to spread across nodes
- Pod disruption budget for rolling updates
- Persistent storage for data persistence

### Security

Security features include:
- Non-root user execution
- Security contexts with appropriate permissions
- TLS encryption for all communications
- RBAC integration with Kubernetes

## Monitoring

Rancher includes built-in Prometheus metrics that can be scraped by your monitoring stack. The chart includes:
- ServiceMonitor resource for Prometheus Operator
- Prometheus annotations on services
- Metrics endpoint configuration

## Troubleshooting

### Common Issues

1. **Certificate Issues**: Ensure cert-manager is properly configured and the cluster issuer exists
2. **DNS Issues**: Verify external-dns is working and can create DNS records
3. **Storage Issues**: Check that the storage class exists and has sufficient capacity
4. **Resource Issues**: Ensure nodes have sufficient resources for Rancher pods

### Logs

```bash
# Check Rancher pod logs
kubectl logs -n cattle-system -l app=rancher

# Check ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
```

### Health Checks

```bash
# Check Rancher deployment status
kubectl get deployment -n cattle-system rancher

# Check pod status
kubectl get pods -n cattle-system -l app=rancher

# Check service status
kubectl get svc -n cattle-system rancher
```

## Upgrading

### Via ArgoCD

Update the chart version in `Chart.yaml` and commit the changes. ArgoCD will automatically sync the changes.

### Manual Upgrade

```bash
helm upgrade rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=rancher.example.com
```

## Uninstalling

### Via ArgoCD

Delete the application from ArgoCD UI or remove the application manifest from Git.

### Manual Uninstall

```bash
helm uninstall rancher -n cattle-system
kubectl delete namespace cattle-system
```

## Additional Resources

- [Rancher Documentation](https://ranchermanager.docs.rancher.com/)
- [Rancher Helm Chart](https://github.com/rancher/rancher)
- [Rancher Community](https://forums.rancher.com/)

## Support

For support and questions:
- Check the [Rancher Documentation](https://ranchermanager.docs.rancher.com/)
- Visit the [Rancher Forums](https://forums.rancher.com/)
- Join the [Rancher Slack](https://rancher.com/slack/)

---

## This deployment's configuration

### Hostname and TLS

```yaml
hostname: ...          # update to the deployment's domain
tls: ...               # options: rancher | letsEncrypt | secret
```

The chart's Ingress is disabled in favour of a Gateway API `HTTPRoute`. The `tls` source
selects who issues Rancher's certificate — `rancher` (self-signed), `letsEncrypt`, or an
existing `secret`.

### Availability

Replica count is set for HA, with a PodDisruptionBudget. Pod- and container-level security
contexts are both set.
