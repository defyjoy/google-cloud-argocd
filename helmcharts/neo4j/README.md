# neo4j

Graph database. Wrapper around the Bitnami Neo4j chart.

- Upstream image: `bitnami/neo4j:5.15.0`

---

## Configuration

### Image and service

```yaml
neo4j:
  image:
    repository: bitnami/neo4j:5.15.0
  service:
    type: ClusterIP
    port: 7474
```

### Ingress is disabled — routing is via HTTPRoute

```yaml
neo4j:
  ingress:
    enabled: false
```

External access goes through a Gateway API `HTTPRoute`, consistent with every chart in this
repo since the Envoy Gateway → Istio Gateway migration.

> 🧹 The disabled block still carries nginx annotations, a `letsencrypt-prod` ClusterIssuer
> reference and a `neo4j.workquark.org` TLS entry. All inert — kept only as a record of the
> pre-Gateway-API setup.

### Security contexts

```yaml
neo4j:
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
neo4j:
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
neo4j:
  resources:
    requests: { memory: 1Gi, cpu: 250m }
    limits:   { memory: 2Gi, cpu: 500m }
```
