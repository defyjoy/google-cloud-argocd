# argo-events

Event-driven workflow automation — EventSources ingest external events, Sensors evaluate them
and trigger actions (typically Argo Workflows).

---

## Configuration

### Components

```yaml
argo-events:
  controller:
    enabled: true
    replicas: 1
    metrics:
      enabled: true
      service:
        enabled: true
        port: 7777
  eventSource:
    enabled: true
  sensor:
    enabled: true
```

All three components are on. Controller metrics are exposed on `:7777` for scraping by
[`victoria-metrics`](../victoria-metrics/README.md).

### Native NATS EventBus

```yaml
argo-events:
  eventBus:
    enabled: true
    nats:
      native:
        enabled: true
        replicas: 3
        auth: none
        persistence:
          enabled: true
          size: 10Gi
          storageClassName: ""
          accessMode: ReadWriteOnce
```

Uses Argo Events' **own bundled NATS**, not the separate [`nats`](../nats/README.md) chart in
this repo — they are unrelated deployments serving different purposes.

> 🔓 `auth: none` is acceptable only because this bus is cluster-internal and carries no
> credentials. Do not expose it.

Three replicas for quorum, with persistence so events survive pod restarts.

### Security contexts

```yaml
argo-events:
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

### Resources

```yaml
argo-events:
  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 200m }
```
