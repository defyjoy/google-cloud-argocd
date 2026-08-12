# tempo

Distributed tracing backend for the mesh. Receives OTLP spans from Istio's `Telemetry` CRs on
**both** clusters, and is queried by Kiali.

- Upstream chart: `tempo` (**single-binary mode**)
- **management-only** — deployed via the `tempo: "true"` cluster label, same as the Kiali server

Design: `docs/istio/istio-ambient-multicluster-management-dev-plan.md` §24 (Phase 6c).

## Why single-binary, not `tempo-distributed`

`tempo-distributed` is the microservices variant and is deliberately **not** used. This is a
homelab; one process is plenty, matching the minimum-footprint philosophy applied across this
repo.

---

## Configuration

### External OTLP exposure

```yaml
externalExposure:
  enabled: true
  hostname: tempo-otlp.jrclabs.xyz
```

Exposes **OTLP/HTTP** via `templates/tempo-otlp-httproute.yaml`, attached to the `http` listener
of the internal `gateway` (`gke-l7-rilb`) in `gateway-system`, so dev can export traces here.

Internal, not `gateway-external`, on purpose: Tempo's OTLP receiver has no authentication
whatsoever. Publishing it would let anyone write traces into the backend.

Safe to leave on unconditionally: this chart only ever deploys on management.

#### It used to be a TCPRoute on 4317, and both halves of that changed

This was a `TCPRoute` to OTLP **gRPC** on `4317`. Two independent problems:

- GKE ships the Gateway API **standard channel**, which has no `TCPRoute` kind — the Application
  failed to sync outright with `could not find gateway.networking.k8s.io/TCPRoute CRD`.
- gRPC is HTTP/2, which an `HTTPRoute` *can* carry, but only if the backend Service is marked
  `appProtocol: kubernetes.io/h2c`. The upstream chart's service template does not expose that
  field, so a route to 4317 would attach cleanly and then fail to negotiate.

Hence the backend moved to **`4318`** (`tempo-otlp-http`, verified against tempo chart 1.23.3),
which is ordinary HTTP and needs no special handling.

> ⚠️ **Senders must use an OTLP HTTP exporter**, not the gRPC one. An OTLP/gRPC client pointed at
> this hostname fails at the transport layer, not with a clear protocol error.

### OTLP receivers need no override

The chart's own defaults already enable both OTLP receivers — gRPC `:4317` and HTTP `:4318`.
The gRPC one stays reachable in-cluster; only the externally routed path is HTTP.

> 🚫 **No OTel Collector is needed in front of Tempo**, unlike ClickHouse, which doesn't
> natively speak OTLP. See §24 for why ClickStack/HyperDX could not serve this role at all.

### Container securityContext is set explicitly

```yaml
tempo:
  tempo:
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
```

**Missing from the chart's own defaults** — container-level `securityContext` defaults to `{}`.
Confirmed live 2026-07-19 that this is the same gap already hit by victoria-metrics' vmauth:
the pod-level defaults (`runAsNonRoot`/`runAsUser`/`fsGroup`, below) are **not sufficient on
their own** for `restricted` PodSecurity. `allowPrivilegeEscalation`, `capabilities.drop` and
`seccompProfile` are also required and were never set by the chart.

Set explicitly upfront here rather than discovering it the way vmauth did.

```yaml
tempo:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
```

### `tempoQuery` stays disabled

```yaml
tempo:
  tempoQuery:
    enabled: false
```

`tempo-query` is the Jaeger-API-compatible sidecar shim. Kiali's
`external_services.tracing.provider: tempo` mode talks to Tempo's **own native query-frontend
API** directly (port 3200), so no Jaeger-compat shim is needed — fewer moving parts than
running a second container purely for API translation.

### Persistence

```yaml
tempo:
  persistence:
    enabled: true
    storageClassName: standard-rwo
    accessModes:
      - ReadWriteOnce
    size: 10Gi
```

Homelab trace volume is small, and retention is left at the chart default of **24h**, so this
only ever holds about a day's worth of spans.

### Node scheduling — pinned off spot nodes

**2026-08-12:**

```yaml
tempo:
  nodeSelector:
    storage: persistent
```

The cluster's node pool mixes spot nodes (reclaimed by GCP with little warning) with a stable
"system" group; when spot nodes were terminated, `storage-local-tempo-0`'s PVC-backed pod went
`Pending`. `storage: persistent` is a label applied directly to the system node group outside this
repo (same change made in `vault`, `harbor`, `nats`, `cloudnative-pg`, and `victoria-metrics`).
