# yugabyte

Distributed SQL database (Postgres wire-compatible), served on the Postgres port `5433`.

- Upstream image: `quay.io/yugabytedb/yugabyte:2.21.0.0-b175`

---

## Configuration

### Image and service

```yaml
yugabyte:
  image:
    repository: quay.io/yugabytedb/yugabyte:2.21.0.0-b175
  service:
    type: ClusterIP
    port: 5433
```

### Security contexts

```yaml
yugabyte:
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
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
yugabyte:
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
yugabyte:
  resources:
    requests: { memory: 1Gi, cpu: 250m }
    limits:   { memory: 2Gi, cpu: 500m }
```
