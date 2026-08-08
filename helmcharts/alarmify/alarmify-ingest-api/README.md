# 📥 alarmify-ingest-api

Public event-ingestion endpoint. Accepts alert/event payloads over HTTP, authenticates them with
**Zitadel**, and publishes them to NATS JetStream for `alarmify-event-worker` to consume.

> 📌 **This chart carried its design notes as YAML comments.** They have all been moved here.
> `values.yaml`, `values/dev.yaml` and `templates/*` are now comment-free; this README is the
> source of truth for *why* each value is what it is.

---

## 📍 At a glance

| Fact | Value |
|---|---|
| 🏷️ Chart | `helmcharts/alarmify/alarmify-ingest-api` (`version: 0.1.0`, `appVersion: v0.0.6`) |
| 📦 Image | `harbor.workquark.org/alarmify/alarmify-ingest-api:v0.0.14` |
| 🌍 Clusters | **`dev` only** — decommissioned from `management` (Phase 3) |
| 📛 Namespace | `alarmify-ingest-api` |
| 🚀 ArgoCD App | `dev-alarmify-ingest-api` (`automated.prune` + `selfHeal: true`) |
| 🌐 Hostname | `ingest.dev.home.arpa` (**no base default** — env-specific) |
| 🔌 Ports | container **`8086`**, Service `80` |
| 📨 Publishes to | `alarmify.events.raw.{tenant_id}` on `dev-nats` |
| 🐘 Postgres | **none** — this app has no DB dependency |
| 🔐 Secrets | Vault → ESO → `alarmify-ingest-api-vars` |

---

## 🔄 Its place in the pipeline

```
   HTTP client ──▶ alarmify-ingest-api ──publish──▶ NATS JetStream (dev-nats)
                                                    subject: alarmify.events.raw.{tenant_id}
                                                            │
                                                            ▼
                                                  alarmify-event-worker ──▶ Postgres
```

---

## 🧩 What the chart renders

| Template | Object |
|---|---|
| `deployment.yaml` | `Deployment/{{ .Release.Name }}` |
| `service.yaml` | `Service/{{ .Release.Name }}` (ClusterIP, `istio.io/global: "true"`) |
| `httproute.yaml` | `HTTPRoute` → `istio-gateway` in `istio-system` |
| `external-secret.yaml` | `ExternalSecret/alarmify-ingest-api-vars` |
| `harbor-registry-external-secret.yaml` | → `Secret/alarmify-ingest-api-registry` |
| `waypoint.yaml` | `Gateway/waypoint` + `ConfigMap/waypoint-options` |
| `vmpodscrape.yaml` | `VMPodScrape/waypoint` |

---

## ⚙️ Configuration

### 🖼️ Image, scale, ports

```yaml
image:
  repository: harbor.workquark.org/alarmify/alarmify-ingest-api
  tag: v0.0.14
  pullPolicy: IfNotPresent

replicas: 1
containerPort: 8086
servicePort: 80
debug: "true"
```

> 🧭 **`environment` and `nats.url` are deliberately absent from `values.yaml`.** Both are
> environment-specific (which cluster's NATS Service DNS to use — see
> `alarmify-apps-migration-plan.md` Phases 2/3; NATS is same-cluster with this app now) and live
> in `values/<environment>.yaml` only.

> ⚠️ Note the **non-standard container port `8086`** — every other alarmify API uses `8080`.

### 📨 NATS

```yaml
nats:
  subject: "alarmify.events.raw"
  mode: "jetstream"
```

🧬 **ADR-001:** `subject` is now the **base prefix, not the full publish subject**. Each event
publishes to `{subject}.{tenant_id}` — see `alarmify-ingest-api/internal/publishers/nats.go` — e.g.
`alarmify.events.raw.<tenant-uuid>`. **The literal value itself is unchanged**; only its meaning is.

> 🔗 The consumer side (`alarmify-event-worker`) filters on `alarmify.events.raw.*` and **fails
> loudly at startup** if the live durable's `FilterSubject` doesn't match. Keep the two in step.

### 🔓 Resources

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
```

> **The CPU limit was deliberately removed (2026-07-10)** — unbounded CPU burst, memory limit kept
> purely as the OOM backstop.

### 🔐 Auth

**Zitadel is the only JWT trust anchor** (`auth-api` removed 2026-07-07). `ZITADEL_ISSUER` and
`ZITADEL_AUDIENCE` are **required at startup**, and both are **Vault-only** — pulled from the
Terraform-owned `alarmify/management/zitadel` via `externalSecrets.secretKeyRefs`:

```yaml
externalSecrets:
  secretKeyRefs:
    - secretKey: ZITADEL_ISSUER
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_ISSUER }
    - secretKey: ZITADEL_AUDIENCE
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_AUDIENCE }
```

> 🚫 **There is deliberately no `auth.zitadel*` values block.** It used to exist and hardcoded
> `zitadelAudience: "380619948738806915"`. Chart values render as literal `env` entries, and
> Kubernetes ranks `env` above `envFrom` — so that literal **silently shadowed Vault** and pinned
> the app to a retired project ID, rejecting every token. Removed 2026-08-01. Do not reintroduce
> it: change the value in Terraform, not here.

🎯 The audience must match the `aud` claim that both the UI OIDC flow and Alertmanager's
client-credentials flow present. Terraform emits it as `ZITADEL_AUDIENCE`; check the live value
with `vault kv get -field=ZITADEL_AUDIENCE kv/alarmify/management/zitadel`.

### 🔑 External secrets

```yaml
externalSecrets:
  secretStore: vault-secretstore
  registryCredentialKey: alarmify/dev/harbor
  appVarsKeys:
    - alarmify/dev/alarmify-ingest-api
    - alarmify/dev/postgres/credentials
  dbHostOverride: ""
  secretKeyRefs:
    - secretKey: ZITADEL_ISSUER
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_ISSUER }
    - secretKey: ZITADEL_AUDIENCE
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_AUDIENCE }
```

Two lists, two different ESO fields:

| Values key | Renders to | Semantics |
|---|---|---|
| `appVarsKeys` | `spec.dataFrom[].extract` | copies **every** field of the object |
| `secretKeyRefs` | `spec.data[]` | copies **one named** property per entry |

> 🐘 **Two `appVarsKeys` objects — the shared `postgres/credentials` is required.** This app *does*
> persist to Postgres (`internal/database/postgres.go`). Without the second entry no
> `DB_USER`/`DB_PASSWORD` reach the container and `internal/config/postgres.go` silently falls back
> to its compiled defaults `postgres`/`postgres`, which fails as
> `SASL auth: password authentication failed for user "postgres" (SQLSTATE 28P01)`.

`dbHostOverride: ""` means "use Vault's `DB_HOST`"; it is set per-environment in `values/dev.yaml`
for the mesh-bridge canary.

#### Why `secretKeyRefs` and not another `appVarsKeys` entry

`alarmify/management/zitadel` is a shared, Terraform-owned object that also holds the identity-api
provisioner private key and the Kiali client secret. An `extract` would copy all of them into this
namespace, which has no use for any of them:

```yaml
appVarsKeys:
  - alarmify/management/zitadel     # ❌ would also copy the provisioner key + Kiali secret here
```

#### Precedence: `data` beats `dataFrom` — and it matters here

ESO's `GetProviderSecretData` resolves every `dataFrom` entry first, then every `data` entry into
the same map, so `secretKeyRefs` wins on collision. `alarmify/dev/alarmify-ingest-api` still
carries its own stale `ZITADEL_ISSUER` / `ZITADEL_AUDIENCE` copies from before the consolidation —
the Terraform-owned values override them, so the stale pair is inert. Pruning it is optional
housekeeping, documented in [`RUNBOOK.md`](./RUNBOOK.md).

### 🧬 This chart's ExternalSecret is the odd one out

Unlike its siblings, `templates/external-secret.yaml` here is **conditional**:

```yaml
mergePolicy: {{ if .Values.externalSecrets.dbHostOverride }}Merge{{ else }}Replace{{ end }}
{{- if .Values.externalSecrets.dbHostOverride }}
data:
  DB_HOST: {{ .Values.externalSecrets.dbHostOverride | quote }}
{{- end }}
```

> 🔀 **Merge when overriding `DB_HOST`, so Vault-extracted keys are preserved.** With
> `mergePolicy: Replace` the template block would wipe everything the `dataFrom` extract produced.
> Since `values/dev.yaml` *does* set `dbHostOverride`, the live dev ES runs in **`Merge`** mode and
> injects `DB_HOST` **into the Secret itself** (not only as a pod env var).

`externalSecrets.secretKeyRefs` renders `spec.data` — per-key `remoteRef` pulls alongside the
`dataFrom` extracts. It carries `ZITADEL_ISSUER` and `ZITADEL_AUDIENCE` from the Terraform-owned
`alarmify/management/zitadel`, pulled key-by-key rather than with `extract` so the provisioner key
and Kiali client secret in that same object stay out of this namespace. ESO applies `dataFrom`
first and `data` second, so these also override the stale `ZITADEL_*` copies still present in
`alarmify/dev/alarmify-ingest-api`.

### 🌐 HTTPRoute

```yaml
httproute:
  path: /
  gatewayName: gateway
  gatewayNamespace: gateway-system
  gatewayListener: http
```

> 🧭 **`hostname` is intentionally not here** — it is environment-specific and set in
> `values/<environment>.yaml`.
> 🔀 The `istio-gateway` wiring is **Phase 2 batch 1 (alarmify)** of the Envoy Gateway → Istio
> Gateway migration — see
> [alarmify-docs / istio](https://github.com/Alarmify/alarmify-docs/blob/main/docs/istio/index.md).

---

## 🌱 Environment overlay — `values/dev.yaml`

```yaml
environment: dev

nats:
  url: "nats://dev-nats.nats.svc.cluster.local:4222"

httproute:
  hostname: ingest.dev.home.arpa

externalSecrets:
  dbHostOverride: "postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local"
```

Selected automatically for clusters labelled `environment: dev` (see
`helmcharts/argocd/templates/cluster/dev-cluster-secret.yaml`).

📜 **Migration:** `alarmify-ingest-api` is **fully decommissioned from `management`**
(`alarmify-apps-migration-plan.md`, **Phase 3**) — dev is the only deployment target today. NATS
moved to dev in **Phase 2**, so this is a **same-cluster** connection now, not the cross-cluster one
originally scoped.

🚫 **Never point `nats.url` at `nats.home.arpa`.** That hairpins out to the `istio-gateway`
TCPRoute and back; ambient clients get `EOF`. Always use in-cluster Service DNS — same reasoning as
management's original value, per the [postgres TCPRoute incident
write-up](https://github.com/Alarmify/alarmify-docs/blob/main/docs/istio/index.md).

🐘 `dbHostOverride` uses the **real CNPG Kubernetes Service FQDN** through Istio's native ambient
global-service path.

> ⚠️ **This app has no Postgres dependency**, so the `DB_HOST` it injects is vestigial — see the
> legacy `DB_*` note in [`RUNBOOK.md`](./RUNBOOK.md).

---

## 🔧 Environment variables reaching the container

| Source | Variables |
|---|---|
| `envFrom` → `Secret/alarmify-ingest-api-vars` | `NATS_USER`, `NATS_PASSWORD`, `DB_HOST` (injected by the ES template), plus any legacy `DB_*` still in Vault |
| Literal `env` | `PORT`, `ENVIRONMENT`, `DEBUG`, `NATS_URL`, `NATS_SUBJECT`, `NATS_MODE`, `ZITADEL_ISSUER`, `ZITADEL_AUDIENCE` |

> 🧷 Unlike its siblings, this chart's deployment does **not** render a literal `DB_HOST` env var —
> `dbHostOverride` is applied inside the **ExternalSecret template** instead.

---

## 🕸️ Waypoint & 📊 metrics

Ambient mode (`istio.io/dataplane-mode=ambient`) means **ztunnel only produces L4 (TCP) telemetry**
— no HTTP status codes, no request rates, no HTTP-level `AuthorizationPolicy` enforcement. The
waypoint terminates L7 so Kiali can draw this app with real HTTP semantics (investigated
**2026-07-10**).

Waypoint sizing (`ConfigMap/waypoint-options`, a strategic merge patch onto the istiod-generated
Deployment — [Istio docs](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/#configuring-gateways-with-infrastructure-parametersref)):

- 📉 **2026-07-11**: CPU `100m`/`2` (chart default) → `50m`/`200m`; all `alarmify-*` waypoints
  standardized. Memory untouched.
- 📉 **2026-07-11 (again)**: limit halved `200m` → `100m` — 24 h peak **20.0m** per VictoriaMetrics.
  ⚡ **The busiest of the six waypoints** — unsurprising for the ingest path. It also sits closest
  to the `100m` ceiling, so re-check this one first if you see waypoint CPU throttling.

`VMPodScrape/waypoint` scrapes the waypoint's Envoy stats (`:15020/stats/prometheus`, 30s) — the
waypoint is an auto-provisioned Envoy pod that no existing `ServiceMonitor`/`PodMonitor` covers, and
vmagent only reads explicit `VMPodScrape`/`VMServiceScrape` objects. 💸 Config-only, no node cost.

---

## 🚀 Deployment (ApplicationSet)

Runs **only on dev** per `alarmify-apps-migration-plan.md` **Phase 3** — fully decommissioned from
`management`. The former management-only generator branch
(`matchLabels: alarmify-ingest-api: "true"`) is **removed entirely**. `hostname` and `nats.url` are
**no longer injected per-branch** — `values/<environment>.yaml` holds the differential overrides
(`environment`, `nats.url`, `httproute.hostname`).

---

## 🩺 Live status (`dev`, checked 2026-07-31)

🟡 **Secrets healthy, workload down.**

| Check | Status |
|---|---|
| `ExternalSecret/alarmify-ingest-api-vars` | ✅ `SecretSynced`, `Ready=True` — **its Vault object exists**, unlike identity/incident/schedule/event-worker |
| `ExternalSecret/harbor-registry-credentials` | ✅ `SecretSynced` |
| Waypoint pod | ✅ Running |
| Worker pod | 🔴 `ImagePullBackOff` (~4d) — `…/alarmify-ingest-api:v0.0.14` → containerd **`NotFound`**; `Chart.yaml` says `appVersion: v0.0.6` |
| `ALARMIFY_EVENTS_RAW` stream | ✅ exists on `dev-nats`, subject `alarmify.events.raw.*`, **0 messages** (nothing published yet — this app has never run) |

> 🌐 5 of the 6 `alarmify-*` apps are in `ImagePullBackOff` with `NotFound` on their pinned tags.
> Only `alarmify-ui:v0.0.115` resolves. See [`RUNBOOK.md`](./RUNBOOK.md#️-image-pull-the-only-blocker-here).

---

## 🧪 Quick triage

```bash
export KUBECONFIG=~/.kube/talos-dev.yaml

kubectl -n alarmify-ingest-api get pods,externalsecret,secret,httproute
kubectl -n alarmify-ingest-api logs deploy/dev-alarmify-ingest-api --tail=100

# Did anything actually get published?
NATSBOX=$(kubectl -n nats get pod -l app.kubernetes.io/name=nats-box -o name | head -1)
kubectl -n nats exec "$NATSBOX" -- \
  nats --server nats://dev-nats.nats.svc.cluster.local:4222 stream info ALARMIFY_EVENTS_RAW

# Watch the subject live while you POST a test event
kubectl -n nats exec -it "$NATSBOX" -- \
  nats --server nats://dev-nats.nats.svc.cluster.local:4222 sub 'alarmify.events.raw.>'
```

---

## 📚 Related

- 🔐 [`RUNBOOK.md`](./RUNBOOK.md) — Vault secrets, tactical
- 🗝️ [`../vault.md`](../vault.md) — Vault commands for **all** `alarmify-*` apps
- 🛠️ [`../alarmify-event-worker/README.md`](../alarmify-event-worker/README.md) — the consumer side
- 📨 `helmcharts/nats` — stream/consumer bootstrap and NATS accounts
- 📖 `defyjoy/alarmify-docs` — ADR-001, migration plans, runbooks
