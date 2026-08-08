# plane

Plane (Community Edition) — project management. **management-cluster deployment.**

- Upstream chart: `plane-ce` 1.6.0 from <https://helm.plane.so>

North-south ingress is a Gateway API `HTTPRoute` attached to the shared `istio-gateway`, exactly
like [`harbor`](../harbor/README.md). Public TLS terminates at Cloudflare, and the
[Cloudflare Tunnel](../cloudflared/README.md) already has a wildcard
`*.workquark.org → istio-gateway-istio.istio-system:80` rule — so **no cloudflared change is
needed**; declaring the HTTPRoute is sufficient for `plane.workquark.org` to route.
[`external-dns`](../external-dns/README.md) (class `cloudflare`) creates the CNAME automatically.

## 🔐 Credentials in this file are placeholders

```yaml
plane-ce:
  rabbitmq:
    default_password: "plane-rabbit-CHANGE-ME"
  minio:
    root_password: "plane-minio-CHANGE-ME"
  env:
    pgdb_password: "plane-pg-CHANGE-ME"
    secret_key: "CHANGE-ME-run-openssl-rand-hex-32-here"
    live_server_secret_key: "CHANGE-ME-run-openssl-rand-hex-32-here"
```

Generate the two keys before first sync:

```bash
openssl rand -hex 32
```

> ⚠️ **Rotating `secret_key` after data exists invalidates all sessions and tokens.** Set it
> before the first sync, not after.

The broker/object-store/database credentials are for in-cluster components that are not
internet-exposed, but they are still committed to git — prefer moving them to Vault + External
Secrets, as the `alarmify-*` charts do.

---

## Wrapper values

Consumed by this chart's own `templates/httproute.yaml`, not passed to the subchart.

```yaml
httproute:
  parentRef:
    name: gateway
    namespace: gateway-system
  hostnames:
    - plane.workquark.org
    - plane.home.arpa
  externalDns:
    hostname: plane.workquark.org
    class: cloudflare

docstoreBucket: uploads
```

Attaches to the plaintext `http` listener (port 80) — edge TLS is at Cloudflare, so no cert on
the route. `plane.home.arpa` allows LAN access over `http://`, since the StepCA cert on the
`https` listener only covers `*.home.arpa`; this mirrors harbor.

> 📌 external-dns reads the tunnel CNAME `target` from the **Gateway**, not the HTTPRoute — this
> block only declares the hostname and class so the record is created in the Cloudflare zone.

`docstoreBucket` **must equal** `plane-ce.env.docstore_bucket` below. Uploaded docs are served
from `https://plane.workquark.org/<docstoreBucket>/…` by the frontend.

---

## Subchart configuration

### Version pinning

```yaml
plane-ce:
  planeVersion: v1.3.1
```

Applied to every Plane image (frontend/backend/space/admin/live). **Pinned deliberately — the
upstream docs explicitly warn against using `stable`.** Keep in step with the chart's
`appVersion`.

### Ingress disabled, but `appHost` still set

```yaml
plane-ce:
  ingress:
    enabled: false
    appHost: plane.workquark.org
    minioHost: ""
    rabbitmqHost: ""
    ingressClass: "nginx"
```

The chart's own nginx/traefik Ingress is off because this wrapper renders a Gateway API
HTTPRoute instead.

> 🧩 **`appHost` must stay set anyway.** The chart derives `WEB_URL` and `CORS_ALLOWED_ORIGINS`
> from it (`config-secrets/app-env.yaml`).

The chart hard-codes `WEB_URL` to `http://<appHost>` with no scheme override. Behind Cloudflare
this is fine: the edge serves https and, with *Always Use HTTPS*, upgrades the origin's http
links — and `CORS_ALLOWED_ORIGINS` already lists both the http:// and https:// variants.

### No cert-manager

```yaml
plane-ce:
  ssl:
    tls_secret_name: ""
    createIssuer: false
    generateCerts: false
```

TLS lives at Cloudflare, same as harbor.

### Backing services run in-cluster

```yaml
plane-ce:
  postgres: { local_setup: true, storageClass: standard-rwo, volumeSize: 5Gi }
  redis:    { local_setup: true, storageClass: standard-rwo, volumeSize: 1Gi }
  rabbitmq: { local_setup: true, storageClass: standard-rwo, volumeSize: 1Gi,  default_user: plane }
  minio:    { local_setup: true, storageClass: standard-rwo, volumeSize: 20Gi, root_user: plane,
              env: { minio_endpoint_ssl: false } }
```

Self-contained, persisted on `standard-rwo` (GKE pd-balanced).

To externalize any of them later (e.g. onto
[`cloudnative-pg`](../cloudnative-pg/README.md)), set that component's `local_setup: false` and
supply the matching remote URL under `env.*`.

### App environment

```yaml
plane-ce:
  env:
    pgdb_username: plane
    pgdb_name: plane
    docstore_bucket: uploads
    doc_upload_size_limit: "5242880"   # 5 MiB
    api_key_rate_limit: "60/minute"
    default_cluster_domain: cluster.local
```

### Replicas

```yaml
plane-ce:
  web:        { replicas: 1 }
  space:      { replicas: 1 }
  admin:      { replicas: 1 }
  live:       { replicas: 1 }
  api:        { replicas: 1 }
  worker:     { replicas: 1 }
  beatworker: { replicas: 1 }
```

Modest across the board — scale the web/api/worker tiers as load grows.
