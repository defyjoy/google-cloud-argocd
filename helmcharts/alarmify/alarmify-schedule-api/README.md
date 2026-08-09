# 📅 alarmify-schedule-api

On-call schedule / rotation service for Alarmify. Pure Postgres-backed CRUD — the **simplest** of
the six charts.

> 📌 **This chart carried its design notes as YAML comments.** They have all been moved here.
> `values.yaml`, `values/dev.yaml` and `templates/*` are now comment-free; this README is the
> source of truth for *why* each value is what it is.

---

## 📍 At a glance

| Fact | Value |
|---|---|
| 🏷️ Chart | `helmcharts/alarmify/alarmify-schedule-api` (`version: 0.1.0`, `appVersion: v0.0.2`) |
| 📦 Image | `harbor.jrclabs.xyz/alarmify/alarmify-schedule-api:v0.0.2` |
| 🌍 Clusters | **`dev` only** — decommissioned from `management` (Phase 5) |
| 📛 Namespace | `alarmify-schedule-api` |
| 🚀 ArgoCD App | `dev-alarmify-schedule-api` (`automated.prune` + `selfHeal: true`) |
| 🌐 Hostname | `schedule.dev.home.arpa` (base default: `schedule.home.arpa`) |
| 🔌 Ports | container `8080`, Service `80` |
| 🕸️ Mesh | Istio **ambient** + waypoint; Service marked `istio.io/global: "true"` |
| 🔐 Secrets | Vault → ESO → `alarmify-schedule-api-vars` |

> 🧩 **No `auth:` block, no NATS, no DestinationRule.** This chart is the plain baseline that
> identity/incident/ingest each extend.

---

## 🧩 What the chart renders

| Template | Object |
|---|---|
| `deployment.yaml` | `Deployment/{{ .Release.Name }}` |
| `service.yaml` | `Service/{{ .Release.Name }}` (ClusterIP, `istio.io/global: "true"`) |
| `httproute.yaml` | `HTTPRoute` → `istio-gateway` in `istio-system` |
| `external-secret.yaml` | `ExternalSecret/alarmify-schedule-api-vars` |
| `harbor-registry-external-secret.yaml` | → `Secret/alarmify-schedule-api-registry` |
| `waypoint.yaml` | `Gateway/waypoint` + `ConfigMap/waypoint-options` |
| `vmpodscrape.yaml` | `VMPodScrape/waypoint` |

---

## ⚙️ Configuration

### 🖼️ Image, scale, ports

```yaml
image:
  repository: harbor.jrclabs.xyz/alarmify/alarmify-schedule-api
  tag: v0.0.2
  pullPolicy: IfNotPresent

replicas: 1
containerPort: 8080
servicePort: 80
environment: prod
debug: "true"
```

> ⚠️ `environment: prod` is the **base** default; `values/dev.yaml` overrides it to `dev`. Since
> the ApplicationSet only targets `dev`, the effective value is always `dev`.

> 🧊 This is the **least-churned** app in the family — `image.tag` (`v0.0.2`) is the only one that
> still matches its `Chart.yaml` `appVersion`.

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

### 🔑 External secrets

```yaml
externalSecrets:
  secretStore: vault-secretstore
  registryCredentialKey: alarmify/dev/harbor
  appVarsKeys:
    - alarmify/dev/postgres/credentials
  dbHostOverride: ""
```

One object, extracted into `alarmify-schedule-api-vars` via `spec.dataFrom`.
👉 Procedures: **[`RUNBOOK.md`](./RUNBOOK.md)**.

#### No per-app Vault object, by design

This chart used to list a second path first:

```yaml
appVarsKeys:
  - alarmify/dev/alarmify-schedule-api   # ❌ removed 2026-08-01
  - alarmify/dev/postgres/credentials
```

That object carried **no keys** — all this app's config is Postgres — and existed purely to satisfy
`dataFrom`. It was pure downside: ESO fails the *entire* ExternalSecret when any `dataFrom` entry is
missing, so an empty object could still strip `DB_*` from the pod and 500 every schedule route,
which is exactly what happened once it was deleted from Vault. Do not re-add it. If a future release
needs app-specific config, add the Vault object and the `appVarsKeys` entry in the same change.

#### No `secretKeyRefs` either

Unlike its siblings this service reads **no `ZITADEL_*` env vars at all** (verified against the
source), so it never references `alarmify/management/zitadel`. Auth is enforced upstream.

### 🌐 HTTPRoute

```yaml
httproute:
  hostname: schedule.home.arpa
  path: /
  gatewayName: gateway
  gatewayNamespace: gateway-system
  gatewayListener: http
```

> 🔀 The `istio-gateway` / `istio-system` wiring is **Phase 2 batch 1 (alarmify)** of the
> Envoy Gateway → Istio Gateway migration — see
> [alarmify-docs / istio](https://github.com/Alarmify/alarmify-docs/blob/main/docs/istio/index.md).

### 🌍 `istio.io/global` on the Service

Added during the management → dev migration so dev's istiod could discover this Service
cross-cluster for `alarmify-ui` (one-directional, dev calling management — same mechanism as
`postgresql-cluster-rw`). ✅ Harmless now that the app itself lives on dev.

---

## 🌱 Environment overlay — `values/dev.yaml`

```yaml
environment: dev

externalSecrets:
  dbHostOverride: postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local

httproute:
  hostname: schedule.dev.home.arpa
```

Layered on `../values.yaml` when the chart syncs to a cluster labelled `environment: dev`.

> 🐘 **PostgreSQL remains in `management`** and is reached through Istio's native ambient
> global-service path using the ordinary CNPG Service FQDN. `dbHostOverride` is injected as a
> **literal `env` var**, and Kubernetes ranks `env` above `envFrom` — so it **supersedes** whatever
> Vault's shared `postgres/credentials` object holds.

---

## 🔧 Environment variables reaching the container

| Source | Variables |
|---|---|
| `envFrom` → `Secret/alarmify-schedule-api-vars` | `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSLMODE`, `DB_TIMEZONE` |
| Literal `env` | `PORT`, `ENVIRONMENT`, and `DB_HOST` when `dbHostOverride` is set |

> ⚠️ `DB_HOST` is set **twice** — chart value wins over Vault.
> ℹ️ Despite `debug: "true"` in `values.yaml`, this chart's `deployment.yaml` renders **no `DEBUG`
> env var** (unlike incident/ingest). The value is currently inert.

---

## 🕸️ Waypoint & 📊 metrics

Ambient mode (`istio.io/dataplane-mode=ambient`) means **ztunnel only produces L4 (TCP) telemetry**
— no HTTP status codes, no request rates, no HTTP-level `AuthorizationPolicy` enforcement. The
waypoint terminates L7 so Kiali can draw this app with real HTTP semantics.

> 🔍 Investigated **2026-07-10**: the ambient TCP-only gap was hiding the
> `alarmify-ui → alarmify-incident-api` edge **and its 403 responses** entirely.

Waypoint sizing (`ConfigMap/waypoint-options`, a strategic merge patch onto the istiod-generated
Deployment — [Istio docs](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/#configuring-gateways-with-infrastructure-parametersref)):

- 📉 **2026-07-11**: CPU `100m`/`2` (chart default) → `50m`/`200m`; all `alarmify-*` waypoints
  standardized to the same low-traffic sizing. Memory untouched.
- 📉 **2026-07-11 (again)**: limit halved `200m` → `100m` — 24 h peak **5.1m** per VictoriaMetrics,
  the **lowest** of the six.

`VMPodScrape/waypoint` scrapes the waypoint's Envoy stats (`:15020/stats/prometheus`, 30s). The
waypoint is an **auto-provisioned** Envoy pod covered by no existing `ServiceMonitor`/`PodMonitor`,
and vmagent only reads explicit `VMPodScrape`/`VMServiceScrape` objects — **not**
`prometheus.io/scrape` annotations. 💸 Config-only: no pod, no extra node CPU/memory.

---

## 🚀 Deployment (ApplicationSet)

Runs **only on dev** per `alarmify-apps-migration-plan.md` **Phase 5** — fully decommissioned from
`management`, **no stub left behind** (same shape as `alarmify-ui`/`alarmify-ingest-api`). The
former management-only generator branch (`matchLabels: alarmify-schedule-api: "true"`) is **removed
entirely**. `hostname` lives in `values/dev.yaml`, **not** injected as an ApplicationSet parameter.

---

## 🩺 Live status (`dev`, checked 2026-07-31)

🔴 **Down.** Two independent blockers:

| # | Symptom | Root cause |
|---|---|---|
| 1️⃣ | `ExternalSecret/alarmify-schedule-api-vars` → `SecretSyncedError` | `spec.dataFrom[0].extract, err: Secret does not exist` — **`kv/alarmify/dev/alarmify-schedule-api` is missing in Vault**. Note this object needs **no keys at all**; it merely has to exist |
| 2️⃣ | `ImagePullBackOff` (~4d) | `…/alarmify-schedule-api:v0.0.2` → containerd `NotFound`. **Tag absent from Harbor** |

✅ Healthy: waypoint pod, `Secret/alarmify-schedule-api-registry`.

> 🧯 Without `DB_HOST`/`DB_PASSWORD` the schedule routes return **500**.

> 🌐 5 of the 6 `alarmify-*` apps are in `ImagePullBackOff` with `NotFound` on their pinned tags.
> Only `alarmify-ui:v0.0.115` resolves. See [`RUNBOOK.md`](./RUNBOOK.md#️-image-pull-second-blocker).

---

## 🧪 Quick triage

```bash
export KUBECONFIG=~/.kube/talos-dev.yaml

kubectl -n alarmify-schedule-api get pods,externalsecret,secret,httproute
kubectl -n alarmify-schedule-api logs deploy/dev-alarmify-schedule-api --tail=100
kubectl -n alarmify-schedule-api describe pod -l app.kubernetes.io/name=alarmify-schedule-api

kubectl -n alarmify-schedule-api get externalsecret alarmify-schedule-api-vars \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

---

## 📚 Related

- 🔐 [`RUNBOOK.md`](./RUNBOOK.md) — Vault secrets, tactical
- 🗝️ [`../vault.md`](../vault.md) — Vault commands for **all** `alarmify-*` apps
- 🔑 `helmcharts/external-secrets` — `ClusterSecretStore/vault-secretstore`
- 🚪 `helmcharts/istio/istio-gateway` — the parent `Gateway`
- 📖 `defyjoy/alarmify-docs` — ADRs, migration plans, runbooks
