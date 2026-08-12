# harbor

Container registry. Wrapper around the upstream
[Harbor chart](https://artifacthub.io/packages/helm/harbor/harbor).

All dependency values nest under the `harbor:` key.

## 🔐 Credentials in this file are placeholders

```yaml
harbor:
  harborAdminPassword: "admin123"
  secretKey: "harborkey"
  database:
    internal:
      password: "change-me"
```

> 🚨 **These are committed to git and must not be the live values.** Verify what the cluster is
> actually running; if any of these are in effect, rotate them and move the real values into
> Vault + External Secrets, as every `alarmify-*` chart already does. `secretKey` in particular
> encrypts stored registry credentials — rotating it after data exists has consequences, so plan
> it rather than flipping it blind.

The `database.external` and `redis.external` blocks carry similar placeholders but are **inert**
while `type: internal`.

---

## Ingress and TLS

```yaml
harbor:
  expose:
    type: route
    tls:
      enabled: true
      certSource: none
    route:
      parentRefs:
        - name: gateway
          namespace: gateway-system
          group: gateway.networking.k8s.io
          kind: Gateway
          sectionName: http
      hosts:
        - harbor.jrclabs.xyz
        - harbor.home.arpa
  externalURL: https://harbor.jrclabs.xyz
```

The public URL is `https://`, but **TLS terminates at Cloudflare** — this HTTPRoute attaches to
the Gateway's plaintext `http` listener only.

| Setting | Why |
|---|---|
| `tls.enabled: true` | the *public* URL is https, so Harbor must generate https links |
| `certSource: none` | required for `route` type when not terminating TLS on the gateway |
| `sectionName: http` | Cloudflare Tunnel → cloudflared → Istio, plain HTTP inside the cluster |

> 🚫 **Do not attach to the `https` listener.** Edge TLS is at Cloudflare; the Step CA cert on
> listener `https` is for LAN / `*.home.arpa` only.

`harbor.home.arpa` is reachable over **http://** from the LAN unless you add a separate HTTPRoute
on the `https` listener.

Moved to `istio-gateway` together with the cloudflared repoint — Phase 4 of the Envoy Gateway →
Istio Gateway migration.

### external-dns

```yaml
annotations:
  external-dns.alpha.kubernetes.io/hostname: harbor.jrclabs.xyz
  external-dns.alpha.kubernetes.io/class: cloudflare
```

[`external-dns`](../external-dns/README.md) uses `annotationFilter class=cloudflare`.

> 📌 **There is deliberately no `target` annotation here.** external-dns's `gateway-httproute`
> source reads `target` only from **Gateway** resources
> ([`istio-gateway`](../istio/istio-gateway/README.md)'s `templates/gateway.yaml`). One placed on
> an HTTPRoute is silently ignored — it was removed to avoid implying it does something.

### `relativeurls` is required

```yaml
harbor:
  registry:
    relativeurls: true
    replicas: 1
```

Makes the registry return **relative `Location` URLs** on blob uploads, so `docker push`/`pull`
keep using the client's scheme (https) instead of being redirected to `http://` by the
plain-HTTP backend path.

---

## Configuration

### Update strategy must be `Recreate`

```yaml
harbor:
  updateStrategy:
    type: Recreate
```

> ⚠️ **Required for RWO GCE Persistent Disk PVCs** (`standard-rwo`; registry, jobservice).
> `RollingUpdate` leaves old and new pods both mounting the same volume, producing a
> **Multi-Attach deadlock**.

### Trivy

```yaml
harbor:
  trivy:
    enabled: true
    ignoreUnfixed: false
    skipUpdate: false
    offlineScan: false
    securityCheck: "vuln"
    resources:
      requests: { cpu: 50m,  memory: 512Mi }
      limits:   { cpu: 100m, memory: 1Gi }
```

The CPU **request** was trimmed from the chart default `200m` → `50m` on 2026-07-10: Trivy sits
idle between scans (~0m observed over 10m in VictoriaMetrics). This was done to unblock
`alarmify-ui` / `alarmify-incident-api` waypoint scheduling when the cluster's three schedulable
nodes were at 97–99% CPU-request saturation.

The **limit** was halved separately on 2026-07-11 (`1000m` → `500m`, 24h peak 0.8m). The live
value is now `100m`, so it has been reduced further since.

### Persistence

```yaml
harbor:
  persistence:
    enabled: true
    imageChartStorage:
      type: filesystem
      filesystem:
        rootdirectory: /storage
```

Filesystem-backed. Per-component PVCs: registry `4Gi`, chartmuseum / jobservice / database /
redis / trivy `2Gi` each, all `ReadWriteOnce` with no explicit storage class (cluster default).

An S3 `imageChartStorage` variant is supported upstream if this ever needs to move off local
volumes.

### Resources

```yaml
harbor:
  resources:
    core:       { requests: { cpu: 200m, memory: 512Mi }, limits: { cpu: 400m, memory: 1024Mi } }
    jobservice: { requests: { cpu: 200m, memory: 512Mi }, limits: { cpu: 400m, memory: 1024Mi } }
    registry:   { requests: { cpu: 100m, memory: 256Mi }, limits: { cpu: 200m, memory: 512Mi } }
```

### Metrics

```yaml
harbor:
  metrics:
    enabled: true
    core:     { path: /metrics, port: 8001 }
    registry: { path: /metrics, port: 8001 }
    exporter: { path: /metrics, port: 8001 }
  logLevel: info
```

### Node scheduling — PVC-backed components pinned off spot nodes

**2026-08-12:** `jobservice`, `registry`, `trivy`, `database.internal`, and `redis.internal` — the
five components with a PVC — all got `nodeSelector: { storage: persistent }`. The cluster's node
pool mixes spot nodes (reclaimed by GCP with little warning) with a stable "system" group; when
spot nodes were terminated, every PVC-backed pod cluster-wide went `Pending` waiting for its volume
to reattach somewhere. `storage: persistent` is a label applied directly to the system node group
outside this repo (see the same change in `vault`, `nats`, `tempo`, `cloudnative-pg`, and
`victoria-metrics`). `core` (Harbor's stateless API/UI component) wasn't touched since it carries no PVC and can
tolerate landing on spot.
