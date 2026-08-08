# keda-operator

KEDA — event-driven autoscaling. Installs the operator and the metrics API server that backs
`ScaledObject` resources.

---

## Configuration

### Operator and metrics server

```yaml
keda:
  operator:
    replicas: 1
    image:
      repository: ghcr.io/kedacore/keda
      tag: "2.12.2"
  metricsServer:
    replicas: 1
    image:
      repository: ghcr.io/kedacore/keda-metrics-apiserver
      tag: "2.12.2"
```

Both images are pinned to the **same tag** — the operator and metrics API server are released
together and are not expected to run at mismatched versions.

> ⚠️ Settings nest under `keda:`, not `keda-operator:`, despite the chart directory name.

### Security contexts

```yaml
keda:
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
keda:
  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 200m }
```
