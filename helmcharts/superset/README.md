# superset

Apache Superset — BI and data exploration UI.

---

## Configuration

### Split worker / web sizing

```yaml
superset:
  workers:
    replicas: 1
    resources:
      requests: { memory: 1Gi,   cpu: 500m }
      limits:   { memory: 2Gi,   cpu: 1000m }
  web:
    replicas: 1
    resources:
      requests: { memory: 512Mi, cpu: 250m }
      limits:   { memory: 1Gi,   cpu: 500m }
```

Workers are sized roughly **2× the web tier** — async query execution is the CPU- and
memory-hungry half, while the web tier mostly serves the UI.

### Image tag follows the chart

```yaml
superset:
  image:
    repository: apache/superset
    pullPolicy: IfNotPresent
```

No `tag` is pinned here deliberately — the tag is managed by the chart version, so upgrading
the dependency in `Chart.yaml` is what moves the image.

### Secrets

```yaml
superset:
  secretEnv:
    create: true
  extraSecretEnv:
  extraEnv: {}
```

`secretEnv.create: true` lets the chart generate its own `SECRET_KEY`. `extraSecretEnv` is left
**null rather than `{}`** — the upstream chart distinguishes the two, and null means "no
override" while `{}` can render an empty Secret.

### Ingress is disabled — routing is via HTTPRoute

```yaml
superset:
  ingress:
    enabled: false
```

External access goes through a Gateway API `HTTPRoute`. The disabled block retains a
`superset.jrclabs.xyz` host entry as a record of the pre-Gateway-API setup.

### Security contexts

```yaml
superset:
  runAsUser: 1000
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
  podSecurityContext:
    runAsNonRoot: true
    runAsUser: 1000
    fsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
```

Runs as a non-root user, which upstream flags as the production-recommended setting.
