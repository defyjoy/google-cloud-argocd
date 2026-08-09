# redis

In-memory key-value store. Wrapper around the Bitnami Redis chart.

- Upstream image: `bitnami/redis:7.2.4`

---

## Configuration

### Image and service

```yaml
redis:
  image:
    repository: bitnami/redis:7.2.4
  service:
    type: ClusterIP
    port: 6379
```

### Standalone, not replicated

```yaml
redis:
  architecture: standalone
```

Single instance — no replica set or Sentinel. Matches the minimum-footprint approach used
across this repo; revisit if anything starts depending on Redis for durable state.

### Ingress is disabled — routing is via HTTPRoute

```yaml
redis:
  ingress:
    enabled: false
```

External access goes through a Gateway API `HTTPRoute`, consistent with every chart in this
repo since the Envoy Gateway → Istio Gateway migration.

> 🧹 The disabled block still carries nginx annotations, a `letsencrypt-prod` ClusterIssuer
> reference and a `redis.jrclabs.xyz` TLS entry. All inert — kept only as a record of the
> pre-Gateway-API setup.

### Security contexts

```yaml
redis:
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
redis:
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
redis:
  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 200m }
```
