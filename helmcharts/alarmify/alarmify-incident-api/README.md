# 🚨 alarmify-incident-api

Incident CRUD/query service for Alarmify. Reads and writes incidents in Postgres, and validates
**Zitadel** JWTs on every request.

> 📌 **This chart carried its design notes as YAML comments.** They have all been moved here.
> `values.yaml`, `values/dev.yaml` and `templates/*` are now comment-free; this README is the
> source of truth for *why* each value is what it is.

---

## 📍 At a glance

| Fact | Value |
|---|---|
| 🏷️ Chart | `helmcharts/alarmify/alarmify-incident-api` (`version: 0.1.0`, `appVersion: v0.0.15`) |
| 📦 Image | `harbor.jrclabs.xyz/alarmify/alarmify-incident-api:v0.0.20` |
| 🌍 Clusters | **`dev` only** — decommissioned from `management` (Phase 5) |
| 📛 Namespace | `alarmify-incident-api` |
| 🚀 ArgoCD App | `dev-alarmify-incident-api` (`automated.prune` + `selfHeal: true`) |
| 🌐 Hostname | `incident.dev.home.arpa` (base default: `incident.home.arpa`) |
| 🔌 Ports | container `8080`, Service `80` |
| 🕸️ Mesh | Istio **ambient** + waypoint; Service marked `istio.io/global: "true"` |
| 🔐 Secrets | Vault → ESO → `alarmify-incident-api-vars` |

---

## 🧩 What the chart renders

| Template | Object |
|---|---|
| `deployment.yaml` | `Deployment/{{ .Release.Name }}` |
| `service.yaml` | `Service/{{ .Release.Name }}` (ClusterIP, `istio.io/global: "true"`) |
| `httproute.yaml` | `HTTPRoute` → `istio-gateway` in `istio-system` |
| `external-secret.yaml` | `ExternalSecret/alarmify-incident-api-vars` |
| `harbor-registry-external-secret.yaml` | → `Secret/alarmify-incident-api-registry` |
| `waypoint.yaml` | `Gateway/waypoint` + `ConfigMap/waypoint-options` |
| `vmpodscrape.yaml` | `VMPodScrape/waypoint` |

---

## ⚙️ Configuration

### 🖼️ Image, scale, ports

```yaml
image:
  repository: harbor.jrclabs.xyz/alarmify/alarmify-incident-api
  tag: v0.0.20
  pullPolicy: IfNotPresent

replicas: 1
containerPort: 8080
servicePort: 80
environment: prod
debug: "true"
```

> ⚠️ `environment: prod` is the **base** default; `values/dev.yaml` overrides it to `dev`.

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

🎯 The audience is the **API app's `client_id`**, which Terraform emits as `ZITADEL_AUDIENCE`.
Check the live value with
`vault kv get -field=ZITADEL_AUDIENCE kv/alarmify/management/zitadel`.

### 🔑 External secrets

```yaml
externalSecrets:
  secretStore: vault-secretstore
  registryCredentialKey: alarmify/dev/harbor
  appVarsKeys:
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

👉 Procedures: **[`RUNBOOK.md`](./RUNBOOK.md)**.

#### Why `secretKeyRefs` and not another `appVarsKeys` entry

`alarmify/management/zitadel` is a shared, Terraform-owned object that also holds the identity-api
provisioner private key and the Kiali client secret. An `extract` would copy all of them into this
namespace, which has no use for any of them:

```yaml
appVarsKeys:
  - alarmify/management/zitadel     # ❌ would also copy the provisioner key + Kiali secret here
```

#### Precedence: `data` beats `dataFrom`

ESO's `GetProviderSecretData` resolves every `dataFrom` entry first, then every `data` entry into
the same map — so `secretKeyRefs` wins on any key collision, regardless of list order.

### 🌐 HTTPRoute

```yaml
httproute:
  hostname: incident.home.arpa
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
  hostname: incident.dev.home.arpa
```

The app runs in **dev** while **PostgreSQL remains in `management`**. Keep `DB_HOST` on the **real
CNPG Kubernetes Service FQDN** — Istio ambient global-service discovery routes its endpoint through
management's **HBONE east-west gateway**.

> 🧷 `dbHostOverride` renders as a literal `env` var and therefore **supersedes** whatever Vault's
> shared `postgres/credentials` object holds. The deployment template says so explicitly:
> *explicit `env` entries override duplicate keys loaded through `envFrom`*.

---

## 🔧 Environment variables reaching the container

| Source | Variables |
|---|---|
| `envFrom` → `Secret/alarmify-incident-api-vars` | `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSLMODE`, `DB_TIMEZONE`, plus any Zitadel keys in Vault |
| Literal `env` | `PORT`, `ENVIRONMENT`, `DEBUG`, `ZITADEL_ISSUER`, `ZITADEL_AUDIENCE`, and `DB_HOST` when `dbHostOverride` is set |

> ⚠️ `ZITADEL_ISSUER`, `ZITADEL_AUDIENCE` and `DB_HOST` are potentially set **twice** — chart
> values win over Vault. Change them in `values.yaml` / `values/dev.yaml`, not in Vault.

---

## 🕸️ Waypoint & 📊 metrics

Ambient mode (`istio.io/dataplane-mode=ambient`) means **ztunnel only produces L4 (TCP) telemetry**
— no HTTP status codes, no request rates, no HTTP-level `AuthorizationPolicy` enforcement. The
waypoint terminates L7 so Kiali can draw this app with real HTTP semantics.

> 🔍 Investigated **2026-07-10**: the ambient TCP-only gap was hiding the
> `alarmify-ui → alarmify-incident-api` edge **and its 403 responses** entirely. **This app was the
> concrete motivating case.**

Waypoint sizing (`ConfigMap/waypoint-options`, a strategic merge patch onto the istiod-generated
Deployment — [Istio docs](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/#configuring-gateways-with-infrastructure-parametersref)):

- 📉 **2026-07-11**: CPU `100m`/`2` (chart default) → `50m`/`200m`; all `alarmify-*` waypoints
  standardized to the same low-traffic sizing. Memory untouched.
- 📉 **2026-07-11 (again)**: limit halved `200m` → `100m` — 24 h peak **6.3m** per VictoriaMetrics.

`VMPodScrape/waypoint` scrapes the waypoint's Envoy stats (`:15020/stats/prometheus`, 30s). The
waypoint is an **auto-provisioned** Envoy pod covered by no existing `ServiceMonitor`/`PodMonitor`,
and vmagent only reads explicit `VMPodScrape`/`VMServiceScrape` objects — **not**
`prometheus.io/scrape` annotations. 💸 Config-only: no pod, no extra node CPU/memory.

---

## 🚀 Deployment (ApplicationSet)

Runs **only on dev** per `alarmify-apps-migration-plan.md` **Phase 5** — fully decommissioned from
`management`, **no stub left behind**. The former management-only generator branch
(`matchLabels: alarmify-incident-api: "true"`) is **removed entirely**. `hostname` lives in
`values/dev.yaml`, **not** injected as an ApplicationSet parameter.

---

## 🩺 Live status (`dev`, checked 2026-07-31)

🔴 **Down.** Two independent blockers:

| # | Symptom | Root cause |
|---|---|---|
| 1️⃣ | `ExternalSecret/alarmify-incident-api-vars` → `SecretSyncedError` | `spec.dataFrom[0].extract, err: Secret does not exist` — **`kv/alarmify/dev/alarmify-incident-api` is missing in Vault** |
| 2️⃣ | `ImagePullBackOff` (~4d) | `…/alarmify-incident-api:v0.0.20` → containerd `NotFound`. **Tag absent from Harbor.** `Chart.yaml` says `appVersion: v0.0.15` |

✅ Healthy: waypoint pod, `Secret/alarmify-incident-api-registry`.

> 🧯 Because `ZITADEL_ISSUER`/`ZITADEL_AUDIENCE` come from chart values, the **only** thing the
> missing Vault object costs this app is `DB_*` — but without those it falls back to
> `localhost:5432` and `GET /api/v1/incidents` returns **500**.

> 🌐 5 of the 6 `alarmify-*` apps are in `ImagePullBackOff` with `NotFound` on their pinned tags.
> Only `alarmify-ui:v0.0.115` resolves. See [`RUNBOOK.md`](./RUNBOOK.md#️-image-pull-second-blocker).

---

## 🧪 Quick triage

```bash
export KUBECONFIG=~/.kube/talos-dev.yaml

kubectl -n alarmify-incident-api get pods,externalsecret,secret,httproute
kubectl -n alarmify-incident-api logs deploy/dev-alarmify-incident-api --tail=100
kubectl -n alarmify-incident-api describe pod -l app.kubernetes.io/name=alarmify-incident-api

# Waypoint L7 metrics (only these expose HTTP status codes in ambient)
kubectl -n alarmify-incident-api exec deploy/waypoint -c istio-proxy -- \
  curl -s localhost:15020/stats/prometheus | grep istio_requests_total | head
```

---

## 📚 Related

- 🔐 [`RUNBOOK.md`](./RUNBOOK.md) — Vault secrets, tactical
- 🗝️ [`../vault.md`](../vault.md) — Vault commands for **all** `alarmify-*` apps
- 🔑 `helmcharts/external-secrets` — `ClusterSecretStore/vault-secretstore`
- 🚪 `helmcharts/istio/istio-gateway` — the parent `Gateway`
- 📖 `defyjoy/alarmify-docs` — ADRs, migration plans, runbooks
