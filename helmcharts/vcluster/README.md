# vCluster Helm Chart

This Helm chart deploys vCluster (Virtual Kubernetes Clusters) using the official Loft vCluster Helm chart.

## Features

- **Virtual Kubernetes Clusters**: Create lightweight, isolated Kubernetes clusters within your existing cluster
- **Resource Syncing**: Sync nodes, storage classes, persistent volumes, and more from host cluster
- **Multi-Tenancy**: Enable namespace isolation and multi-tenancy
- **Security**: Pod security contexts and RBAC configuration
- **Persistence**: Persistent storage for etcd data

## Prerequisites

- Kubernetes cluster (1.19+)
- Helm 3.0+
- ArgoCD (for GitOps deployment)
- Persistent volume provisioner support

## Installation

### Via ArgoCD (Recommended)

This chart is designed to be deployed via ArgoCD using GitOps principles. The ApplicationSet is located at:

```
helmcharts/argocd-apps/templates/applicationsets/vcluster-as.yaml
```

The ApplicationSet will automatically create Applications for clusters with the label `vcluster: "true"`.

### Manual Installation

```bash
# Add the Loft Helm repository
helm repo add loft https://charts.loft.sh
helm repo update

# Install vCluster
helm install vcluster vcluster/vcluster \
  --namespace vcluster \
  --create-namespace \
  -f values.yaml
```

## Configuration

### Key Configuration Options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `vcluster.name` | Name of the vcluster instance | `vcluster` |
| `vcluster.sync.nodes.enabled` | Sync nodes from host cluster | `true` |
| `vcluster.sync.storageClasses.enabled` | Sync storage classes | `true` |
| `vcluster.persistence.enabled` | Enable persistent storage | `true` |
| `vcluster.persistence.size` | Size of persistent volume | `20Gi` |
| `vcluster.persistence.storageClass` | Storage class for persistence | `standard-rwo` |

### Sync Configuration

vCluster can sync various resources from the host cluster:

- **Nodes**: Sync all nodes from the host cluster
- **Storage Classes**: Sync storage classes for dynamic provisioning
- **Persistent Volumes**: Sync persistent volumes
- **Ingress Classes**: Sync ingress classes
- **Network Policies**: Sync network policies
- **Priority Classes**: Sync priority classes

### Security Configuration

The chart includes security contexts:
- Pod security context with non-root user
- Container security context with dropped capabilities
- RBAC integration
- Service account configuration

## Usage

### Accessing vCluster

After deployment, you can access the vCluster using:

```bash
# Get the kubeconfig for the vcluster
vcluster connect vcluster --namespace vcluster
```

### Deploying Applications

Once connected, you can deploy applications to the vcluster as if it were a regular Kubernetes cluster:

```bash
kubectl apply -f my-app.yaml
```

## Troubleshooting

### Common Issues

1. **Pods Not Starting**: Check resource limits and storage class availability
2. **Sync Issues**: Verify sync configuration matches your requirements
3. **Storage Issues**: Ensure storage class exists and has sufficient capacity

### Logs

```bash
# Check vcluster pod logs
kubectl logs -n vcluster -l app=vcluster

# Check sync pod logs
kubectl logs -n vcluster -l app=vcluster-syncer
```

## Upgrading

### Via ArgoCD

Update the chart version in `Chart.yaml` and commit the changes. ArgoCD will automatically sync the changes.

### Manual Upgrade

```bash
helm upgrade vcluster vcluster/vcluster \
  --namespace vcluster \
  -f values.yaml
```

## Uninstalling

### Via ArgoCD

Delete the Application from ArgoCD UI or remove the ApplicationSet.

### Manual Uninstall

```bash
helm uninstall vcluster -n vcluster
```

## References

- [vCluster Documentation](https://www.vcluster.com/docs)
- [Loft Helm Charts](https://charts.loft.sh)
- [ArgoCD ApplicationSet](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)

---

## This deployment's configuration

Wraps the official Loft vcluster chart; all values nest under the dependency key.

### Sync configuration

The `sync` block controls what is mirrored between the host and virtual clusters, in both
directions:

- **virtual → host** — resources the vcluster creates that must materialise on the host
- **host → virtual** — host resources made visible inside the vcluster

### Control-plane persistence

Persistence for the vcluster control plane is configured separately from workload storage.
