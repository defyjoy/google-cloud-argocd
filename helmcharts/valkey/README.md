# valkey

Redis-compatible in-memory store (the BSD-licensed fork). Wrapper around the Bitnami Valkey chart.

Runs alongside [`redis`](../redis/README.md) on the same port with the same shape — they are interchangeable, not clustered together.

- Upstream image: `bitnami/valkey:7.2.5`

---

## Configuration

### Image and service

```yaml
valkey:
  image:
    repository: bitnami/valkey:7.2.5
  service:
    type: ClusterIP
    port: 6379
```

### Standalone, not replicated

```yaml
valkey:
  architecture: standalone
```

Single instance — no replica set or Sentinel.

### Ingress is disabled — routing is via HTTPRoute

```yaml
valkey:
  ingress:
    enabled: false
```

External access goes through a Gateway API `HTTPRoute`, consistent with every chart in this
repo since the Envoy Gateway → Istio Gateway migration.

> 🧹 The disabled block still carries nginx annotations, a `letsencrypt-prod` ClusterIssuer
> reference and a `valkey.jrclabs.xyz` TLS entry. All inert — kept only as a record of the
> pre-Gateway-API setup.

### Security contexts

```yaml
valkey:
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 1001
    runAsGroup: 1001
    fsGroup: 1001
    seccompProfile:
      type: RuntimeDefault
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    readOnlyRootFilesystem: false
    runAsNonRoot: true
    privileged: false
    seccompProfile:
      type: RuntimeDefault
```

Both pod- and container-level contexts are set, which is what `restricted` PodSecurity
requires — the pod-level block alone is not sufficient.

### Persistence

```yaml
valkey:
  persistence:
    enabled: true
    size: 8Gi
    storageClassName: ""
    accessMode: ReadWriteOnce
```

`storageClassName: ""` uses the cluster default rather than pinning to `standard-rwo`, unlike the
observability charts.

### Resources

```yaml
valkey:
  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 200m }
```
