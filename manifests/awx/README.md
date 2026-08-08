# AWX Instance

AWX instance deployed using Kustomize.

## Overview

This directory contains Kustomize manifests for deploying an AWX instance managed by the AWX Operator.

The AWX instance is deployed as a Custom Resource (CR) that is managed by the AWX Operator.

## Structure

```
manifests/awx/
├── kustomization.yaml    # Main Kustomize configuration
├── awx-instance.yaml     # AWX Custom Resource definition
└── README.md            # This file
```

## Kustomization

The `kustomization.yaml` file:
- Sets the namespace to `awx`
- References the AWX instance manifest
- Adds common labels for tracking

## Installation

### Via ArgoCD Application

The AWX instance is deployed using an ArgoCD Application. Ensure that:

1. The AWX Operator is installed (via ApplicationSet with label `awx=true`)
2. The cluster secret in ArgoCD has the label `awx=true`:

```bash
# Label your cluster secret in ArgoCD
kubectl label secret -n argocd <cluster-secret-name> awx=true

# For the local cluster
kubectl label secret -n argocd in-cluster awx=true
```

### Manual Kustomize Installation

```bash
# Apply the manifests
kubectl apply -k manifests/awx

# Verify installation
kubectl get awx -n awx
kubectl get pods -n awx
```

### Using Kustomize CLI

```bash
# Build and preview
kustomize build manifests/awx

# Apply directly
kustomize build manifests/awx | kubectl apply -f -
```

## Configuration

### Basic Configuration

Edit `awx-instance.yaml` to customize your AWX instance:

```yaml
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
  namespace: awx
spec:
  replicas: 1
  service_type: ClusterIP
  ingress_type: ingress
  ingress_tls_secret: awx-tls
```

### Advanced Configuration

For more advanced configuration options, refer to the [AWX Operator documentation](https://ansible.readthedocs.io/projects/awx-operator/):

- Resource limits
- Database configuration
- Image pull secrets
- Additional environment variables
- Node selectors and affinity rules

### Example: Ingress Configuration

```yaml
spec:
  ingress_type: ingress
  ingress_tls_secret: awx-tls
  ingress_annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
```

### Example: Resource Limits

```yaml
spec:
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2000m"
      memory: "4Gi"
```

## Usage

### Access AWX UI

```bash
# Port-forward to access AWX UI
kubectl port-forward svc/awx-service -n awx 8080:80

# Open http://localhost:8080 in your browser
```

### Get Admin Credentials

```bash
# Get AWX admin username (default: admin)
kubectl get secret awx-admin-password -n awx -o jsonpath='{.data.username}' | base64 -d

# Get AWX admin password
kubectl get secret awx-admin-password -n awx -o jsonpath='{.data.password}' | base64 -d
```

### Verify AWX Instance

```bash
# Check AWX instance status
kubectl get awx -n awx

# Check AWX pods
kubectl get pods -n awx

# Check AWX services
kubectl get svc -n awx

# Check AWX events
kubectl get events -n awx --sort-by='.lastTimestamp'
```

### Describe AWX Instance

```bash
# Get detailed information about AWX instance
kubectl describe awx awx -n awx
```

## Troubleshooting

### AWX Instance Not Starting

```bash
# Check AWX instance status
kubectl describe awx awx -n awx

# Check operator logs
kubectl logs -n awx-operator -l name=awx-operator

# Check AWX pod logs
kubectl logs -n awx -l app.kubernetes.io/name=awx

# Check events
kubectl get events -n awx --sort-by='.lastTimestamp'
```

### AWX Instance Stuck in Provisioning

```bash
# Check AWX deployment status
kubectl get deployment -n awx

# Check AWX job logs
kubectl logs -n awx -l job-name --tail=100

# Check for PVC issues
kubectl get pvc -n awx

# Check for resource constraints
kubectl top pods -n awx
```

### Database Connection Issues

```bash
# Check database pod status
kubectl get pods -n awx | grep postgres

# Check database logs
kubectl logs -n awx -l app=postgres

# Check database service
kubectl get svc -n awx | grep postgres
```

## Upgrading

To upgrade your AWX instance:

1. Update the AWX version in the AWX Operator
2. The operator will automatically upgrade the AWX instance
3. Monitor the upgrade:

```bash
# Watch AWX instance during upgrade
kubectl get awx awx -n awx -w

# Check upgrade progress
kubectl describe awx awx -n awx
```

## Uninstallation

```bash
# Delete AWX instance
kubectl delete -k manifests/awx

# Verify removal
kubectl get awx -n awx
kubectl get pods -n awx
```

**Note**: Deleting the AWX instance will also delete all AWX data unless you have persistent volumes configured.

## References

- [AWX Operator Documentation](https://ansible.readthedocs.io/projects/awx-operator/)
- [AWX Documentation](https://docs.ansible.com/automation-controller/)
- [AWX Operator GitHub](https://github.com/ansible/awx-operator)
- [Kustomize Documentation](https://kustomize.io/)

## Support

For issues and questions:
- AWX Operator: https://github.com/ansible/awx-operator/issues
- AWX Community: https://github.com/ansible/awx/discussions

