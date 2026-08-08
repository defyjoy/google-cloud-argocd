# cloudnative-pg

Wrapper around the upstream [CloudNativePG](https://github.com/cloudnative-pg/charts) operator
chart. Installs the operator and CRDs; actual Postgres `Cluster` objects are defined elsewhere.

- Upstream defaults: <https://github.com/cloudnative-pg/charts>

## Wrapper pattern

```yaml
enabled: true

cloudnative-pg:
  config:
    clusterWide: true
```

The top-level `enabled` toggles the upstream dependency via `condition: enabled` in
`Chart.yaml`. **All settings for the dependency must be nested under the `cloudnative-pg:`
key** — anything at the top level is silently ignored by Helm.

`clusterWide: true` means one operator reconciles `Cluster` objects in every namespace.

---

## Configuration

### Security contexts

```yaml
cloudnative-pg:
  podSecurityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
    capabilities:
      drop:
        - ALL
```

Note the container-level key is `containerSecurityContext` here, not `securityContext` as in
most other charts in this repo.

### Resources — cut twice

```yaml
cloudnative-pg:
  resources:
    requests: { memory: 64Mi,  cpu: 13m }
    limits:   { memory: 128Mi, cpu: 26m }
```

This is an operator reconcile loop with roughly **5m of observed actual usage** in
VictoriaMetrics, so it has been trimmed twice:

| Date | Change |
|---|---|
| 2026-07-10 | cpu `100m/500m` → `50m/250m`; memory untouched |
| 2026-07-11 | 75% reduction pass — cpu `50m/250m` → `13m/…`; memory `256Mi/512Mi` → `64Mi/128Mi` |

The 13m request is 25% of the prior value, rounded up from an exact 12.5m because Kubernetes
CPU quantities must be whole millicores.

> 📌 The second cut was originally recorded as targeting a `63m` limit, but the live value is
> `26m` — i.e. 2× requests, matching this repo's usual limit policy. `26m` is what is
> deployed; treat the `63m` figure as superseded.
