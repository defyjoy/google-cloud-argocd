# glitchtip

Self-hosted error tracking (Sentry-compatible API).

- Upstream image: `bitnami/glitchtip`

---

## Configuration

### Image and service

```yaml
glitchtip:
  image:
    registry: docker.io
    repository: bitnami/glitchtip
    tag: "1.0.0"
    pullPolicy: IfNotPresent
  service:
    type: ClusterIP
    port: 8080
```

### Ingress is disabled — routing is via HTTPRoute

```yaml
glitchtip:
  ingress:
    enabled: false
```

The chart's own `Ingress` is off. External access goes through a Gateway API `HTTPRoute`
instead, consistent with every other chart in this repo since the Envoy Gateway → Istio Gateway
migration.

> 🧹 The disabled `ingress` block still carries nginx annotations, a `letsencrypt-prod`
> ClusterIssuer reference and a `glitchtip.workquark.org` TLS entry. All of it is inert — kept
> only as a record of the pre-Gateway-API setup.

### Security contexts

```yaml
glitchtip:
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

Both levels are set, as `restricted` PodSecurity requires.

### Resources

```yaml
glitchtip:
  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 200m }
```
