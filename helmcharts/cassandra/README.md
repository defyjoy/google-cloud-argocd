# cassandra

Wide-column NoSQL store. Wrapper around the Bitnami Cassandra chart.

- Upstream image: `bitnami/cassandra:4.1.4`
- Replicas: **3**

---

## Configuration

### Image and service

```yaml
cassandra:
  image:
    repository: bitnami/cassandra:4.1.4
  service:
    type: ClusterIP
    port: 9042
```

### Cluster tuning

```yaml
cassandra:
  replicaCount: 3
  config:
    clusterName: "cassandra-cluster"
    numTokens: 256
    concurrentReads: 32
    concurrentWrites: 32
    concurrentCounterWrites: 32
```

Three replicas with 256 vnodes per node — the Cassandra default token count, kept as-is. The
concurrency settings are also upstream defaults, stated explicitly so they are visible when
tuning.

### Ingress is disabled — routing is via HTTPRoute

```yaml
cassandra:
  ingress:
    enabled: false
```

External access goes through a Gateway API `HTTPRoute`, consistent with every chart in this
repo since the Envoy Gateway → Istio Gateway migration.

> 🧹 The disabled block still carries nginx annotations, a `letsencrypt-prod` ClusterIssuer
> reference and a `cassandra.jrclabs.xyz` TLS entry. All inert — kept only as a record of the
> pre-Gateway-API setup.

### Security contexts

```yaml
cassandra:
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
cassandra:
  persistence:
    enabled: true
    size: 10Gi
    storageClassName: ""
    accessMode: ReadWriteOnce
```

`storageClassName: ""` uses the cluster default rather than pinning to `standard-rwo`, unlike the
observability charts.

### Resources

```yaml
cassandra:
  resources:
    requests: { memory: 1Gi, cpu: 250m }
    limits:   { memory: 2Gi, cpu: 500m }
```
