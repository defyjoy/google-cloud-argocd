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
```

Exposes OTLP gRPC (`4317`) via the north-south gateway
(`templates/tempo-otlp-tcproute.yaml` → [`istio-gateway`](../istio/istio-gateway/README.md)'s
`tempo-otlp` listener), so dev's waypoint proxies can export traces here directly over the flat
LAN.

Safe to leave on unconditionally: this chart only ever deploys on management.

### OTLP receivers need no override

The chart's own defaults already enable both OTLP receivers — gRPC `:4317` and HTTP `:4318`.
Istio's `Telemetry` CRs point directly at this endpoint.

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
