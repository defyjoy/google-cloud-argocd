# N8N Helm Chart

This Helm chart deploys n8n, a powerful workflow automation tool, on Kubernetes using the latest community-maintained Helm chart (v1.15.16).

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- Ingress controller (nginx recommended)
- Cert-manager for TLS certificates

## Installation

1. Add the community charts repository:
```bash
helm repo add community-charts https://community-charts.github.io/helm-charts
helm repo update
```

2. Install the chart:
```bash
helm install n8n community-charts/n8n --version 1.15.16 -f values.yaml
```

## Configuration

The chart supports various configuration options through the `values.yaml` file:

- **Image**: n8n Docker image configuration
- **Service**: Kubernetes service configuration
- **Ingress**: Ingress configuration for external access
- **Persistence**: Storage configuration for n8n data
- **Resources**: CPU and memory limits/requests
- **Security**: Security contexts and policies
- **Database**: PostgreSQL/MySQL support for production
- **Queue Mode**: Redis-based queue for distributed execution

## This deployment's configuration

Everything is nested under the **`n8n:`** dependency key. `values.yaml` otherwise tracks the
upstream chart's defaults closely — the disabled autoscaling blocks, probe definitions and
resource stanzas it contains are upstream's own examples, kept for reference rather than tuned
here.

### Main node

```yaml
n8n:
  main:
    count: 1
    editorBaseUrl: "n8n.workquark.org"
    forceToUseStatefulset: false
    persistence:
      enabled: true
      volumeName: "n8n-data"
      storageClass: standard-rwo
```

### Workers

```yaml
n8n:
  worker:
    mode: regular
    concurrency: 10
    count: 2
    allNodes: false
    autoscaling:
      enabled: false
      minReplicas: 2
      maxReplicas: 10
      metrics:
        - { type: Resource, resource: { name: memory, target: { type: Utilization, averageUtilization: 80 } } }
        - { type: Resource, resource: { name: cpu,    target: { type: Utilization, averageUtilization: 80 } } }
    pdb:
      enabled: true
      minAvailable: 1
```

Two workers at concurrency 10, with a PodDisruptionBudget keeping at least one available.
**Autoscaling is configured but disabled** — the metrics above take effect only if
`autoscaling.enabled` is flipped.

### Security context

```yaml
n8n:
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop: [ALL]
    readOnlyRootFilesystem: false
    runAsNonRoot: true
    privileged: false
    runAsUser: 1000
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
```

> ⚠️ **The `## Values` table below is stale.** It documents top-level keys
> (`image.repository`, `persistence.storageClass`) that do not match the current
> `values.yaml`, where everything nests under `n8n:` and the storage class is `standard-rwo`.
> Treat the snippets above as authoritative and the table as historical.

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `image.repository` | string | `"n8nio/n8n"` | n8n image repository |
| `image.tag` | string | `"latest"` | n8n image tag |
| `image.pullPolicy` | string | `"IfNotPresent"` | Image pull policy |
| `replicaCount` | int | `1` | Number of replicas |
| `service.type` | string | `"ClusterIP"` | Service type |
| `service.port` | int | `5678` | Service port |
| `ingress.enabled` | bool | `true` | Enable ingress |
| `ingress.hosts[0].host` | string | `"n8n.workquark.org"` | Ingress host |
| `persistence.enabled` | bool | `true` | Enable persistence |
| `persistence.storageClass` | string | `"standard-rwo"` | Storage class |
| `persistence.size` | string | `"10Gi"` | Storage size |
| `db.type` | string | `"sqlite"` | Database type (sqlite/postgresdb/mysql) |
| `postgresql.enabled` | bool | `false` | Enable PostgreSQL |
| `redis.enabled` | bool | `false` | Enable Redis for queue mode |

## Production Configuration

For production environments, it's recommended to use:

1. **PostgreSQL Database**:
```yaml
db:
  type: postgresdb
postgresql:
  enabled: true
  auth:
    database: n8n
    username: n8n
    password: your-secure-password
```

2. **Queue Mode with Redis**:
```yaml
redis:
  enabled: true
worker:
  mode: queue
webhook:
  mode: queue
  url: https://webhook.yourdomain.com
```

## Security

This chart includes security best practices:

- Non-root user execution
- Security contexts with seccomp profiles
- Capability restrictions
- Read-only root filesystem where possible
- PodSecurity compliance

## Monitoring

The chart includes basic monitoring configuration:

- Resource limits and requests
- Health checks
- Security contexts
- Prometheus metrics support

## Troubleshooting

### Common Issues

1. **Pod not starting**: Check resource limits and security contexts
2. **Ingress not working**: Verify ingress controller and TLS configuration
3. **Persistence issues**: Check storage class and permissions
4. **Database connection issues**: Verify database credentials and connectivity

### Logs

View n8n logs:
```bash
kubectl logs -f deployment/n8n -n n8n
```

## Support

For issues and questions:
- n8n Documentation: https://docs.n8n.io/
- n8n Community: https://community.n8n.io/
- GitHub Issues: https://github.com/n8n-io/n8n/issues
- Helm Chart Repository: https://github.com/8gears/n8n-helm-chart
