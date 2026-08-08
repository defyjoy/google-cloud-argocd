# 🪪 alarmify-identity-api

Tenant / user identity service for Alarmify. Fronts **Zitadel** (the only JWT trust anchor since
the `auth-api` removal on 2026-07-07) and owns tenant provisioning against Postgres.

> 📌 **This chart carried its design notes as YAML comments.** They have all been moved here.
> `values.yaml`, `values/dev.yaml` and `templates/*` are now comment-free; this README is the
> source of truth for *why* each value is what it is.

---

## 📍 At a glance

| Fact | Value |
|---|---|
| 🏷️ Chart | `helmcharts/alarmify/alarmify-identity-api` (`version: 0.1.0`, `appVersion: v0.0.5`) |
| 📦 Image | `harbor.workquark.org/alarmify/alarmify-identity-api:v0.0.12` |
| 🌍 Clusters | **`dev` only** — decommissioned from `management` (Phase 5) |
| 📛 Namespace | `alarmify-identity-api` |
| 🚀 ArgoCD App | `dev-alarmify-identity-api` (`automated.prune` + `selfHeal: true`) |
| 🌐 Hostname | `identity.dev.home.arpa` (base default: `identity.home.arpa`) |
| 🔌 Ports | container `8080`, Service `80` |
| 🕸️ Mesh | Istio **ambient** + waypoint; Service marked `istio.io/global: "true"` |
| 🔐 Secrets | Vault → ESO → `alarmify-identity-api-vars` |

---

## 🧩 What the chart renders

| Template | Object |
|---|---|
| `deployment.yaml` | `Deployment/{{ .Release.Name }}` |
| `service.yaml` | `Service/{{ .Release.Name }}` (ClusterIP, `istio.io/global: "true"`) |
| `httproute.yaml` | `HTTPRoute` → `istio-gateway` in `istio-system` |
| `external-secret.yaml` | `ExternalSecret/alarmify-identity-api-vars` |
| `harbor-registry-external-secret.yaml` | → `Secret/alarmify-identity-api-registry` |
| `waypoint.yaml` | `Gateway/waypoint` + `ConfigMap/waypoint-options` |
| `vmpodscrape.yaml` | `VMPodScrape/waypoint` |

---

## ⚙️ Configuration

### 🖼️ Image, scale, ports

```yaml
image:
  repository: harbor.workquark.org/alarmify/alarmify-identity-api
  tag: v0.0.12
  pullPolicy: IfNotPresent

replicas: 1
containerPort: 8080
servicePort: 80
environment: prod
```

> ⚠️ `environment: prod` is the **base** default; `values/dev.yaml` overrides it to `dev`. Since
> the ApplicationSet only targets `dev`, the effective value is always `dev`.

### 📈 Resources

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
```

> 🔓 **The CPU limit was deliberately removed (2026-07-10)** — unbounded CPU burst, with the
> memory limit kept purely as the OOM backstop.

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
    - secretKey: ZITADEL_PROJECT_ID
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_PROJECT_ID }
    - secretKey: ZITADEL_PROJECT_ORG_ID
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_INSTANCE_ORG_ID }
    - secretKey: ZITADEL_ACTION_SIGNING_KEY
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_ACTION_SIGNING_KEY }
    - secretKey: ZITADEL_PROVISIONER_KEY_JSON
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_PROVISIONER_KEY_JSON }
```

Two lists, two different ESO fields:

| Values key | Renders to | Semantics |
|---|---|---|
| `appVarsKeys` | `spec.dataFrom[].extract` | copies **every** field of the object |
| `secretKeyRefs` | `spec.data[]` | copies **one named** property per entry |

👉 Procedures: **[`RUNBOOK.md`](./RUNBOOK.md)**.

#### Why `secretKeyRefs` and not another `appVarsKeys` entry

`alarmify/management/zitadel` is a shared, Terraform-owned object. It also holds
`ZITADEL_PROVISIONER_KEY_JSON` for *this* app plus `ZITADEL_KIALI_CLIENT_SECRET` and
`ZITADEL_UI_CLIENT_ID` for others. An `extract` would copy all of them into every consuming
namespace, so each key is pulled by name instead:

```yaml
appVarsKeys:
  - alarmify/management/zitadel     # ❌ would also copy the Kiali client secret here
```

#### Precedence: `data` beats `dataFrom`

ESO's `GetProviderSecretData` resolves every `dataFrom` entry first, then every `data` entry into
the same map — so `secretKeyRefs` wins on any key collision, regardless of list order. That is
what lets the Terraform-owned values override stale per-app copies still sitting in Vault.

#### The `PROJECT_ORG_ID` / `INSTANCE_ORG_ID` rename

One entry above is deliberately **not** a 1:1 mapping:

```yaml
- secretKey: ZITADEL_PROJECT_ORG_ID              # what the app reads
  remoteRef: { key: alarmify/management/zitadel,
               property: ZITADEL_INSTANCE_ORG_ID }  # what Terraform emits
```

Same value, two names — the org owning the project. Confirmed at
`internal/config/config.go:90` (reads `ZITADEL_PROJECT_ORG_ID`) and
`internal/clients/zitadelclient/client.go:36` (documents it as `terraform output instance_org_id`).

### 🔐 `auth.authMode`

```yaml
auth:
  authMode: zitadel
```

`AUTH_MODE` is **chart config, not Vault** — it describes no Zitadel object, so the Terraform
stack emits no output for it and `alarmify/management/zitadel` has no such key. It renders as a
literal `env` entry. The in-code default is `legacy` (`internal/config/config.go:86`), which is
dead since `auth-api` was removed on 2026-07-07, so leaving this unset silently selects a
non-functional mode.

> 🚫 This is the **only** Zitadel-adjacent literal `env` this chart sets. Never add
> `ZITADEL_*` values here — `env` outranks `envFrom`, so a literal would silently shadow Vault.
> That exact mistake pinned incident-api and ingest-api to a retired project ID until 2026-08-01.

### 🌐 HTTPRoute

```yaml
httproute:
  hostname: identity.home.arpa
  path: /
  gatewayName: gateway
  gatewayNamespace: gateway-system
  gatewayListener: http
```

> 🔀 The `istio-gateway` / `istio-system` wiring is **Phase 2 batch 1 (alarmify)** of the
> Envoy Gateway → Istio Gateway migration — see
> [alarmify-docs / istio](https://github.com/Alarmify/alarmify-docs/blob/main/docs/istio/index.md).

### 🌍 `istio.io/global` on the Service

```yaml
metadata:
  labels:
    istio.io/global: "true"
```

Added during the management → dev migration: `alarmify-ui` on dev calls this Service **by its
in-cluster DNS name, cross-cluster** — one-directional, dev calling management, the same mechanism
Postgres uses via `postgresql-cluster-rw`. Without the label dev's istiod cannot discover the
Service at all. ✅ It is harmless now that this app itself lives on dev too.

---

## 🌱 Environment overlay — `values/dev.yaml`

```yaml
environment: dev

externalSecrets:
  dbHostOverride: postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local

httproute:
  hostname: identity.dev.home.arpa
```

Layered on `../values.yaml` when the chart syncs to a cluster labelled `environment: dev`.

> 🐘 **PostgreSQL remains in `management`** and is reached through Istio's native ambient
> global-service path using the ordinary CNPG Service FQDN. `dbHostOverride` is injected as a
> **literal `env` var**, and Kubernetes ranks `env` above `envFrom` — so it **supersedes**
> whatever Vault's shared `postgres/credentials` object holds.

---

## 🔧 Environment variables reaching the container

| Source | Variables |
|---|---|
| `envFrom` → `Secret/alarmify-identity-api-vars` | `AUTH_MODE`, `ZITADEL_ISSUER`, `ZITADEL_AUDIENCE`, `ZITADEL_PROJECT_ID`, `ZITADEL_PROJECT_ORG_ID`, `ZITADEL_ACTION_SIGNING_KEY`, `ZITADEL_PROVISIONER_KEY_JSON`, `DB_*` |
| Literal `env` | `PORT`, `ENVIRONMENT`, and `DB_HOST` when `dbHostOverride` is set |

> 🔐 Unlike incident/ingest, this chart has **no `auth:` block** — all Zitadel config comes from
> Vault, including the provisioner service-account key.

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
- 📉 **2026-07-11 (again)**: limit halved `200m` → `100m` — 24 h peak **5.2m** per VictoriaMetrics.

`VMPodScrape/waypoint` scrapes the waypoint's Envoy stats (`:15020/stats/prometheus`, 30s). The
waypoint is an **auto-provisioned** Envoy pod covered by no existing `ServiceMonitor`/`PodMonitor`,
and vmagent only reads explicit `VMPodScrape`/`VMServiceScrape` objects — **not**
`prometheus.io/scrape` annotations. 💸 Config-only: no pod, no extra CPU/memory on the node.

---

## 🚀 Deployment (ApplicationSet)

Runs **only on dev** per `alarmify-apps-migration-plan.md` **Phase 5** — fully decommissioned from
`management`, **no stub left behind** (same shape as `alarmify-ui` / `alarmify-ingest-api`). The
former management-only generator branch (`matchLabels: alarmify-identity-api: "true"`) is **removed
entirely**. `hostname` lives in `values/dev.yaml`, **not** injected as an ApplicationSet parameter
— the same `values.yaml` + `values/<environment>.yaml` split as `alarmify-ui`/`alarmify-ingest-api`.

---

## 🩺 Live status (`dev`, checked 2026-07-31)

🔴 **Down.** Two independent blockers:

| # | Symptom | Root cause |
|---|---|---|
| 1️⃣ | `ExternalSecret/alarmify-identity-api-vars` → `SecretSyncedError` | `spec.dataFrom[0].extract, err: Secret does not exist` — **`kv/alarmify/dev/alarmify-identity-api` is missing in Vault**, so `Secret/alarmify-identity-api-vars` was never created |
| 2️⃣ | `ImagePullBackOff` (~4d) | `…/alarmify-identity-api:v0.0.12` → containerd `NotFound`. **The tag does not exist in Harbor.** Note `Chart.yaml` says `appVersion: v0.0.5` |

✅ Healthy: the waypoint pod and `Secret/alarmify-identity-api-registry` (harbor ES syncing fine).

> 🌐 This is **not** an isolated failure — 5 of the 6 `alarmify-*` apps are in `ImagePullBackOff`
> with `NotFound` on their pinned tags. Only `alarmify-ui:v0.0.115` resolves. See
> [`RUNBOOK.md`](./RUNBOOK.md#️-image-pull-second-blocker).

---

## 🧪 Quick triage

```bash
export KUBECONFIG=~/.kube/talos-dev.yaml

kubectl -n alarmify-identity-api get pods,externalsecret,secret,httproute
kubectl -n alarmify-identity-api logs deploy/dev-alarmify-identity-api --tail=100
kubectl -n alarmify-identity-api describe pod -l app.kubernetes.io/name=alarmify-identity-api

# Route reachability from inside the mesh
kubectl -n alarmify-identity-api run curl --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"curl","image":"curlimages/curl:8.10.1","command":["curl","-sv","http://dev-alarmify-identity-api.alarmify-identity-api.svc/healthz"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
```

---

## 📚 Related

- 🔐 [`RUNBOOK.md`](./RUNBOOK.md) — Vault secrets, tactical
- 🗝️ [`../vault.md`](../vault.md) — Vault commands for **all** `alarmify-*` apps
- 🔑 `helmcharts/external-secrets` — `ClusterSecretStore/vault-secretstore`
- 🚪 `helmcharts/istio/istio-gateway` — the parent `Gateway`
- 📖 `defyjoy/alarmify-docs` — ADRs, migration plans, runbooks
