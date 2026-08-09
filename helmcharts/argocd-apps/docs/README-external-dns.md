# External DNS ApplicationSets

This directory contains ApplicationSets for deploying External DNS across multiple clusters with different configurations.

## ApplicationSets Overview

### 1. `external-dns-as.yaml` - Basic ApplicationSet
- **Purpose**: Simple deployment for clusters with `external-dns: "true"` label
- **Configuration**: Uses default values from the Helm chart
- **Use Case**: Standard production deployments

### 2. `external-dns-enhanced-as.yaml` - Enhanced ApplicationSet
- **Purpose**: Advanced deployment with environment-specific configurations
- **Configuration**: Parameterized values for different environments
- **Use Case**: Multi-environment deployments with custom settings

### 3. `external-dns-dev-as.yaml` - Development ApplicationSet
- **Purpose**: Development/testing environment configuration
- **Configuration**: Optimized for development with dry-run mode
- **Use Case**: Development and testing clusters

## Cluster Labeling

To deploy External DNS to a cluster, add the appropriate labels:

### Production Clusters
```yaml
metadata:
  labels:
    external-dns: "true"
    environment: production
```

### Development Clusters
```yaml
metadata:
  labels:
    external-dns: "true"
    environment: development
```

## Configuration Parameters

### Production Configuration (Enhanced ApplicationSet)
- **Domain**: `jrclabs.xyz`
- **Cloudflare Proxy**: Enabled
- **TTL**: 300 seconds
- **Dry Run**: Disabled
- **Log Level**: Info
- **Interval**: 1 minute
- **Policy**: upsert-only
- **Sources**: ingress, service, crd
- **Metrics**: Enabled
- **ServiceMonitor**: Enabled
- **Resources**: 100m CPU, 128Mi memory
- **Replicas**: 1
- **Pod Disruption Budget**: Enabled

### Development Configuration (Dev ApplicationSet)
- **Domain**: `dev.jrclabs.xyz`
- **Cloudflare Proxy**: Disabled
- **TTL**: 60 seconds
- **Dry Run**: Enabled
- **Log Level**: Debug
- **Interval**: 30 seconds
- **Policy**: upsert-only
- **Sources**: ingress, service
- **Metrics**: Enabled
- **ServiceMonitor**: Disabled
- **Resources**: 50m CPU, 64Mi memory
- **Replicas**: 1
- **Pod Disruption Budget**: Disabled

## Prerequisites

### 1. Vault Configuration
Store Cloudflare API token in Vault:
```bash
vault kv put secret/cloudflare/api-token \
  token="your-cloudflare-api-token-here"
```

### 2. Cluster Registration
Register clusters with appropriate labels:
```bash
# Production cluster
argocd cluster add <production-cluster-context> \
  --label external-dns=true \
  --label environment=production

# Development cluster
argocd cluster add <development-cluster-context> \
  --label external-dns=true \
  --label environment=development
```

### 3. External Secrets Operator
Ensure External Secrets Operator is deployed and configured with Vault access.

## Deployment

### Automatic Deployment
ApplicationSets will automatically deploy External DNS to clusters with matching labels.

### Manual Deployment
```bash
# Apply ApplicationSets
kubectl apply -f helmcharts/argocd-apps/templates/applicationsets/external-dns-as.yaml
kubectl apply -f helmcharts/argocd-apps/templates/applicationsets/external-dns-enhanced-as.yaml
kubectl apply -f helmcharts/argocd-apps/templates/applicationsets/external-dns-dev-as.yaml
```

## Usage Examples

### 1. Ingress with External DNS
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-ingress
  namespace: default
  annotations:
    external-dns.alpha.kubernetes.io/hostname: example.jrclabs.xyz
    external-dns.alpha.kubernetes.io/class: cloudflare
spec:
  ingressClassName: nginx
  rules:
  - host: example.jrclabs.xyz
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

### 2. Service with External DNS
```yaml
apiVersion: v1
kind: Service
metadata:
  name: example-service
  namespace: default
  annotations:
    external-dns.alpha.kubernetes.io/hostname: service.jrclabs.xyz
    external-dns.alpha.kubernetes.io/class: cloudflare
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: example
```

### 3. DNSEndpoint CRD
```yaml
apiVersion: external-dns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: example-dnsendpoint
  namespace: default
spec:
  endpoints:
  - dnsName: "api.jrclabs.xyz"
    recordTTL: 300
    recordType: "A"
    targets:
    - "192.168.1.100"
```

## Monitoring

### Prometheus Metrics
External DNS exposes metrics on port 7979:
- `external_dns_controller_errors_total`
- `external_dns_controller_processed_records_total`
- `external_dns_controller_sync_duration_seconds`
- `external_dns_controller_instances`

### Grafana Dashboard
Use the External DNS Grafana dashboard for monitoring DNS record management.

## Troubleshooting

### Common Issues

#### 1. Application Not Created
- Check cluster labels
- Verify ApplicationSet is applied
- Check ArgoCD logs

#### 2. DNS Records Not Created
- Verify Cloudflare API token in Vault
- Check External DNS logs
- Verify annotation filters
- Check domain filters

#### 3. Permission Issues
- Verify RBAC permissions
- Check ServiceAccount configuration
- Verify External Secrets access

### Debug Commands
```bash
# Check ApplicationSet status
kubectl get applicationsets -n argocd

# Check Application status
kubectl get applications -n argocd | grep external-dns

# Check External DNS pods
kubectl get pods -n external-dns

# Check External DNS logs
kubectl logs -n external-dns deployment/external-dns

# Check DNS records
kubectl get ingress -A --show-labels
```

## Security Considerations

### API Token Security
- Store in Vault with proper access controls
- Use least-privilege API token
- Rotate tokens regularly

### Network Security
- Use network policies
- Enable TLS for metrics
- Consider service mesh integration

### Pod Security
- Non-root execution
- Read-only root filesystem
- Restricted capabilities
- Seccomp profile enabled

## Customization

### Adding New Environments
1. Create new ApplicationSet with environment-specific values
2. Add cluster labels for the new environment
3. Configure environment-specific parameters

### Modifying Configuration
1. Update ApplicationSet parameters
2. Apply changes to ArgoCD
3. Monitor deployment status

### Adding New Clusters
1. Register cluster with ArgoCD
2. Add appropriate labels
3. ApplicationSet will automatically deploy External DNS
