# AWX Operator

Official AWX Operator deployed using Kustomize.

## Overview

This directory contains Kustomize manifests for deploying the official AWX Operator from [ansible/awx-operator](https://github.com/ansible/awx-operator).

The operator is deployed using the official release manifests with customizations applied via Kustomize.

## Version

- **Operator Version**: 2.7.0
- **Deployment Method**: Kustomize
- **Source**: Official AWX Operator GitHub releases

## Structure

```
manifests/awx-operator/
├── kustomization.yaml    # Main Kustomize configuration
└── README.md            # This file
```

## Kustomization

The `kustomization.yaml` file:
- References the official operator manifest from GitHub releases
- Sets the namespace to `awx-operator`
- Adds common labels for tracking
- Configures pod security labels for the namespace

## Installation

### Via ArgoCD ApplicationSet

The operator is deployed using an ArgoCD ApplicationSet. To enable deployment on a cluster:

```bash
# Label your cluster secret in ArgoCD
kubectl label secret -n argocd <cluster-secret-name> awx=true

# For the local cluster
kubectl label secret -n argocd in-cluster awx=true
```

### Manual Kustomize Installation

```bash
# Apply the manifests
kubectl apply -k manifests/awx-operator

# Verify installation
kubectl get pods -n awx-operator
kubectl get crd | grep awx
```

### Using Kustomize CLI

```bash
# Build and preview
kustomize build manifests/awx-operator

# Apply directly
kustomize build manifests/awx-operator | kubectl apply -f -
```

## Customization

To customize the operator deployment, you can add patches to the `kustomization.yaml` file:

### Example: Change Resource Limits

```yaml
patches:
  - target:
      kind: Deployment
      name: awx-operator-controller-manager
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/memory
        value: 1Gi
      - op: replace
        path: /spec/template/spec/containers/0/resources/limits/cpu
        value: 500m
```

### Example: Add Environment Variables

```yaml
patches:
  - target:
      kind: Deployment
      name: awx-operator-controller-manager
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: LOG_LEVEL
          value: debug
```

## Usage

### Creating an AWX Instance

Once the operator is installed, create AWX instances using the `AWX` custom resource:

```yaml
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx-demo
  namespace: awx
spec:
  replicas: 1
  service_type: ClusterIP
  ingress_type: ingress
  ingress_tls_secret: awx-demo-tls
```

### Verify Operator

```bash
# Check operator pod
kubectl get pods -n awx-operator

# Check CRDs
kubectl get crd awx.ansible.com

# Check operator logs
kubectl logs -n awx-operator -l name=awx-operator

# Check operator version
kubectl get deployment -n awx-operator awx-operator-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Create a Test AWX Instance

```bash
# Create a simple AWX instance
kubectl apply -f - <<EOF
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx-test
  namespace: awx
spec:
  replicas: 1
  service_type: ClusterIP
EOF

# Watch the instance creation
kubectl get awx -w

# Get instance details
kubectl describe awx awx-test -n awx

# Get AWX admin credentials
kubectl get secret awx-test-admin-password -n awx -o jsonpath='{.data.password}' | base64 -d
```

## Upgrading

To upgrade to a new version of the operator:

1. Update the version in `kustomization.yaml`:
   ```yaml
   resources:
     - https://github.com/ansible/awx-operator/releases/download/2.8.0/awx-operator.yaml
   
   commonLabels:
     app.kubernetes.io/version: "2.8.0"
   ```

2. Apply the changes:
   ```bash
   kubectl apply -k manifests/awx-operator
   ```

3. Verify the upgrade:
   ```bash
   kubectl get deployment -n awx-operator awx-operator-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```

## Troubleshooting

### Operator Not Starting

```bash
# Check operator logs
kubectl logs -n awx-operator -l name=awx-operator

# Check RBAC permissions
kubectl auth can-i create awx --as=system:serviceaccount:awx-operator:awx-operator-controller-manager

# Verify CRDs are installed
kubectl get crd awx.ansible.com
```

### AWX Instance Not Creating

```bash
# Check instance status
kubectl describe awx <instance-name> -n <namespace>

# Check operator logs
kubectl logs -n awx-operator -l name=awx-operator

# Check events
kubectl get events --sort-by='.lastTimestamp' | grep awx
```

### Kustomize Build Errors

```bash
# Validate kustomization.yaml
kustomize build manifests/awx-operator

# Check for syntax errors
yamllint manifests/awx-operator/kustomization.yaml
```

## Uninstallation

```bash
# Delete all AWX instances first
kubectl delete awx --all --all-namespaces

# Delete the operator
kubectl delete -k manifests/awx-operator

# Verify removal
kubectl get namespace awx-operator
kubectl get crd awx.ansible.com
```

## References

- [Official AWX Operator Documentation](https://ansible.readthedocs.io/projects/awx-operator/)
- [AWX Operator GitHub](https://github.com/ansible/awx-operator)
- [AWX Operator Releases](https://github.com/ansible/awx-operator/releases)
- [Kustomize Documentation](https://kustomize.io/)
- [AWX Documentation](https://docs.ansible.com/automation-controller/)

## Support

For issues and questions:
- AWX Operator: https://github.com/ansible/awx-operator/issues
- AWX Community: https://github.com/ansible/awx/discussions
- Kustomize: https://github.com/kubernetes-sigs/kustomize/issues

