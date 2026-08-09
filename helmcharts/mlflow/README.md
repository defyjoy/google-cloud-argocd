# mlflow

ML experiment tracking and model registry. Wrapper around the Bitnami MLflow chart.

- Upstream image: `bitnami/mlflow:2.8.1`

---

## Configuration

### Image and service

```yaml
mlflow:
  image:
    repository: bitnami/mlflow:2.8.1
  service:
    type: ClusterIP
    port: 5000
```

### Ingress is disabled — routing is via HTTPRoute

```yaml
mlflow:
  ingress:
    enabled: false
```

External access goes through a Gateway API `HTTPRoute`, consistent with every chart in this
repo since the Envoy Gateway → Istio Gateway migration.

> 🧹 The disabled block still carries nginx annotations, a `letsencrypt-prod` ClusterIssuer
> reference and a `mlflow.jrclabs.xyz` TLS entry. All inert — kept only as a record of the
> pre-Gateway-API setup.

### Security contexts

```yaml
mlflow:
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

### Resources

```yaml
mlflow:
  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 200m }
```
