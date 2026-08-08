# RabbitMQ Cluster Operator

Official RabbitMQ Cluster Operator deployed using Kustomize.

## Overview

This directory contains Kustomize manifests for deploying the official RabbitMQ Cluster Operator from [rabbitmq/cluster-operator](https://github.com/rabbitmq/cluster-operator).

The operator is deployed using the official release manifests with customizations applied via Kustomize.

## Version

- **Operator Version**: 2.17.0
- **Deployment Method**: Kustomize
- **Source**: Official RabbitMQ Cluster Operator GitHub releases

## Structure

```
manifests/rabbitmq-operator/
├── kustomization.yaml    # Main Kustomize configuration
└── README.md            # This file
```

## Kustomization

The `kustomization.yaml` file:
- References the official operator manifest from GitHub releases
- Sets the namespace to `rabbitmq-system`
- Adds common labels for tracking
- Configures pod security labels for the namespace

## Installation

### Via ArgoCD ApplicationSet

The operator is deployed using an ArgoCD ApplicationSet. To enable deployment on a cluster:

```bash
# Label your cluster secret in ArgoCD
kubectl label secret -n argocd <cluster-secret-name> rabbitmq-cluster-operator=true

# For the local cluster
kubectl label secret -n argocd in-cluster rabbitmq-cluster-operator=true
```

### Manual Kustomize Installation

```bash
# Apply the manifests
kubectl apply -k manifests/rabbitmq-operator

# Verify installation
kubectl get pods -n rabbitmq-system
kubectl get crd | grep rabbitmq
```

### Using Kustomize CLI

```bash
# Build and preview
kustomize build manifests/rabbitmq-operator

# Apply directly
kustomize build manifests/rabbitmq-operator | kubectl apply -f -
```

## Customization

To customize the operator deployment, you can add patches to the `kustomization.yaml` file:

### Example: Change Resource Limits

```yaml
patches:
  - target:
      kind: Deployment
      name: rabbitmq-cluster-operator
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
      name: rabbitmq-cluster-operator
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: LOG_LEVEL
          value: debug
```

### Example: Watch Specific Namespaces

```yaml
patches:
  - target:
      kind: Deployment
      name: rabbitmq-cluster-operator
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: WATCH_NAMESPACE
          value: "namespace1,namespace2"
```

## Usage

### Creating a RabbitMQ Cluster

Once the operator is installed, create RabbitMQ clusters using the `RabbitmqCluster` custom resource:

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: my-rabbitmq
  namespace: default
spec:
  replicas: 3
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: 1000m
      memory: 2Gi
  persistence:
    storageClassName: standard
    storage: 10Gi
  rabbitmq:
    additionalConfig: |
      cluster_formation.peer_discovery_backend = rabbit_peer_discovery_k8s
      cluster_formation.k8s.host = kubernetes.default.svc.cluster.local
      cluster_formation.k8s.address_type = hostname
```

### Verify Operator

```bash
# Check operator pod
kubectl get pods -n rabbitmq-system

# Check CRDs
kubectl get crd rabbitmqclusters.rabbitmq.com

# Check operator logs
kubectl logs -n rabbitmq-system -l app.kubernetes.io/name=rabbitmq-cluster-operator

# Check operator version
kubectl get deployment -n rabbitmq-system rabbitmq-cluster-operator -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Create a Test Cluster

```bash
# Create a simple RabbitMQ cluster
kubectl apply -f - <<EOF
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: test-rabbitmq
  namespace: default
spec:
  replicas: 1
EOF

# Watch the cluster creation
kubectl get rabbitmqcluster -w

# Get cluster details
kubectl describe rabbitmqcluster test-rabbitmq

# Access RabbitMQ management UI
kubectl port-forward svc/test-rabbitmq 15672:15672
# Open http://localhost:15672

# Get default credentials
kubectl get secret test-rabbitmq-default-user -o jsonpath='{.data.username}' | base64 -d
kubectl get secret test-rabbitmq-default-user -o jsonpath='{.data.password}' | base64 -d
```

## Upgrading

To upgrade to a new version of the operator:

1. Update the version in `kustomization.yaml`:
   ```yaml
   resources:
     - https://github.com/rabbitmq/cluster-operator/releases/download/v2.18.0/cluster-operator.yml
   
   images:
     - name: quay.io/rabbitmq/cluster-operator
       newTag: 2.18.0
   ```

2. Apply the changes:
   ```bash
   kubectl apply -k manifests/rabbitmq-operator
   ```

3. Verify the upgrade:
   ```bash
   kubectl get deployment -n rabbitmq-system rabbitmq-cluster-operator -o jsonpath='{.spec.template.spec.containers[0].image}'
   ```

## Troubleshooting

### Operator Not Starting

```bash
# Check operator logs
kubectl logs -n rabbitmq-system -l app.kubernetes.io/name=rabbitmq-cluster-operator

# Check RBAC permissions
kubectl auth can-i create rabbitmqclusters --as=system:serviceaccount:rabbitmq-system:rabbitmq-cluster-operator

# Verify CRDs are installed
kubectl get crd rabbitmqclusters.rabbitmq.com
```

### RabbitMQ Cluster Not Creating

```bash
# Check cluster status
kubectl describe rabbitmqcluster <cluster-name>

# Check operator logs
kubectl logs -n rabbitmq-system -l app.kubernetes.io/name=rabbitmq-cluster-operator

# Check events
kubectl get events --sort-by='.lastTimestamp' | grep rabbitmq
```

### Kustomize Build Errors

```bash
# Validate kustomization.yaml
kustomize build manifests/rabbitmq-operator --enable-alpha-plugins

# Check for syntax errors
yamllint manifests/rabbitmq-operator/kustomization.yaml
```

## Uninstallation

```bash
# Delete all RabbitMQ clusters first
kubectl delete rabbitmqclusters --all --all-namespaces

# Delete the operator
kubectl delete -k manifests/rabbitmq-operator

# Verify removal
kubectl get namespace rabbitmq-system
kubectl get crd rabbitmqclusters.rabbitmq.com
```

## References

- [Official RabbitMQ Cluster Operator Documentation](https://www.rabbitmq.com/kubernetes/operator/operator-overview.html)
- [RabbitMQ Cluster Operator GitHub](https://github.com/rabbitmq/cluster-operator)
- [RabbitMQ Cluster Operator Releases](https://github.com/rabbitmq/cluster-operator/releases)
- [Kustomize Documentation](https://kustomize.io/)
- [RabbitMQ on Kubernetes](https://www.rabbitmq.com/kubernetes/operator/quickstart-operator.html)

## Support

For issues and questions:
- RabbitMQ Cluster Operator: https://github.com/rabbitmq/cluster-operator/issues
- RabbitMQ Community: https://groups.google.com/forum/#!forum/rabbitmq-users
- Kustomize: https://github.com/kubernetes-sigs/kustomize/issues

