# clickstack

ClickStack umbrella chart (upstream v2.x) — HyperDX observability UI on ClickHouse + MongoDB.

Upstream docs:
<https://clickhouse.com/docs/use-cases/observability/clickstack/deployment/helm>

A single ArgoCD Application (e.g. `*-clickstack`) installs both halves:

1. **`clickstack-operators`** — MongoDB Community + ClickHouse operators (CRDs, controllers)
2. **`clickstack`** — HyperDX, `MongoDBCommunity`, `ClickHouseCluster`, optional OTel collector

**Prerequisites:** a storage class for PVCs (`standard-rwo` on GKE, already set in
`values.yaml`), and the cluster label `clickhouse=true` for the ApplicationSet to select it.

> 🩺 **If HyperDX hangs on initContainer `wait-for-mongodb`**, confirm `MongoDBCommunity` is
> reconciled in `Release.Namespace` and that the headless Service `*-mongodb-svc` has endpoints.

---

## Configuration

### Gating

```yaml
clickhouse:
  enabled: true
```

Gates **both** subcharts (see `Chart.yaml` `condition`).

### HTTPRoute — wrapper-only

```yaml
httproute:
  enabled: true
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: gateway
      namespace: gateway-system
      sectionName: https
  hostnames:
    - clickhouse.home.arpa
  path: /
  pathType: PathPrefix
  backendServiceName: clickstack
  backendPort: 3000
```

This block belongs to the wrapper and is **not passed to the subcharts**. Phase 2 batch 3 (infra
tools) of the Envoy Gateway → Istio Gateway migration;
`clickhouse.home.arpa` was already in the stepca cert's SAN list, so no reissuance was needed.

`backendServiceName: clickstack` depends on `fullnameOverride` below — change one and the route
breaks.

### `fullnameOverride` is load-bearing

```yaml
clickstack:
  fullnameOverride: clickstack
```

Keeps operator-generated **Pod label values under the Kubernetes 63-character limit**. Without
it, generated names overflow and the operator's objects are rejected.

### `FRONTEND_URL` is set twice, deliberately

```yaml
clickstack:
  hyperdx:
    config:
      USAGE_STATS_ENABLED: "false"
      FRONTEND_URL: "http://clickhouse.home.arpa"
    deployment:
      env:
        - name: FRONTEND_URL
          value: "http://clickhouse.home.arpa"
```

**The duplication is intentional.** `config` becomes an `envFrom` ConfigMap, and ConfigMap
updates do **not** reload into running pods — so `POST /api/login/password` would keep
redirecting to a stale `https` URL until someone manually restarted the Deployment.

The literal `env` entry on the Deployment forces a rollout whenever the value changes. Keep both
in sync.

### HyperDX resources — do not trim

```yaml
clickstack:
  hyperdx:
    deployment:
      replicas: 1
      resources:
        limits:   { cpu: 250m, memory: 1Gi }
        requests: { cpu: 125m, memory: 512Mi }
```

> 🚫 **These are the last known-good values.** A 75% trim attempted on 2026-07-11 (limits
> `63m`/`256Mi`, requests `31m`/`128Mi`) caused the API health endpoint on `:8000` to miss the
> liveness window and CrashLoop before the rollout could become ready. This chart is the
> exception to the repo-wide resource-reduction pass.

### Ingress and tasks off

```yaml
clickstack:
  hyperdx:
    ingress:
      enabled: false
    tasks:
      enabled: false
```

Routing is via the wrapper's HTTPRoute above, not the subchart's Ingress.

### MongoDB storage

```yaml
clickstack:
  mongodb:
    enabled: true
    spec:
      statefulSet:
        spec:
          volumeClaimTemplates:
            - metadata:
                name: data-volume
              spec:
                accessModes: [ReadWriteOnce]
                storageClassName: standard-rwo
                resources:
                  requests:
                    storage: 5Gi
```

Pinned to `standard-rwo` explicitly, unlike the datastore charts which use the cluster default.
