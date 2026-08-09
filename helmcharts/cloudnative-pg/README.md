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

### External exposure — internal L4 LoadBalancer

```yaml
externalExposure:
  enabled: true
```

Adds an internal `LoadBalancer` Service `postgresql-cluster-rw-lb` on `5432`, reachable from the
VPC but not the internet (`networking.gke.io/load-balancer-type: Internal`). Costs one internal
LB IP.

**In-cluster clients must not use it.** zitadel and everything else resolve
`postgresql-cluster-rw.cloudnative-pg-system.svc` directly; hairpinning through a load balancer
adds a hop and a failure mode for nothing. This exists for low-churn clients outside the cluster.

#### Why it is declared inside the Cluster, not as a plain Service template

It is rendered through CNPG's own `.spec.managed.services.additional[]` (see
`templates/pgsql-cluster.yaml`), with `selectorType: rw`, so **the operator owns the selector**.

That matters after a failover. The `-rw` selector tracks whichever instance is currently primary;
a hand-written Service with a copied selector would keep pointing at the old pod once it is
demoted to a replica, and writes would fail with `cannot execute INSERT in a read-only
transaction` while every pod stayed Running and every dashboard stayed green.

#### It used to be a TCPRoute

This replaced a `TCPRoute` on the `postgres` listener of `gateway-system/gateway`. That route was
unservable on GKE twice over: the Gateway API **standard channel** GKE ships has no `TCPRoute`
kind at all (so the Application could not sync), and every GatewayClass in use here is an L7
HTTP(S) load balancer, which cannot carry the PostgreSQL wire protocol under any configuration.

**Do not "fix" this by writing an HTTPRoute.** It would be Accepted by the API server and then
blackhole every connection — the failure would look like a network problem, not a config error.

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
