# 🖥️ alarmify-ui

The Alarmify web front-end — a **Next.js standalone-build BFF**. It runs the Zitadel OIDC login
flow, holds the session cookie, and proxies to the four backend APIs. The only `alarmify-*` app
exposed on the **public internet** (`ui.jrclabs.xyz`).

> 📌 **This chart carried its design notes as YAML comments.** They have all been moved here.
> `values.yaml`, `values/dev.yaml` and `templates/*` are now comment-free; this README is the
> source of truth for *why* each value is what it is.

---

## 📍 At a glance

| Fact | Value |
|---|---|
| 🏷️ Chart | `helmcharts/alarmify/alarmify-ui` (`version: 0.1.0`, `appVersion: v0.0.83`) |
| 📦 Image | `harbor.jrclabs.xyz/alarmify/alarmify-ui:v0.0.115` |
| 🌍 Clusters | **`dev` only** — decommissioned from `management` (Option D) |
| 📛 Namespace | `alarmify-ui` |
| 🚀 ArgoCD App | `dev-alarmify-ui` (`automated.prune` + `selfHeal: true`) |
| 🌐 Hostname | **`ui.jrclabs.xyz`** — public, via the **dedicated dev Cloudflare Tunnel** |
| 🔌 Ports | container **`3000`**, Service `80` |
| 👤 Runs as | UID/GID **`1001`** (every other alarmify app uses `1000`) |
| 🐘 Postgres | **none** |
| 🔐 Secrets | Vault → ESO → `alarmify-ui-vars` |

> ✅ **The only `alarmify-*` app currently Running in dev.**

---

## 🧩 What the chart renders

| Template | Object |
|---|---|
| `deployment.yaml` | `Deployment/{{ .Release.Name }}` |
| `service.yaml` | `Service/{{ .Release.Name }}` (ClusterIP, component `ui`) |
| `httproute.yaml` | `HTTPRoute` → `istio-gateway`, with external-dns annotations |
| `destinationrule.yaml` | `DestinationRule/{{ .Release.Name }}-keepalive` ⭐ **unique to this chart** |
| `external-secret.yaml` | `ExternalSecret/alarmify-ui-vars` (conditional) |
| `harbor-registry-external-secret.yaml` | → `Secret/alarmify-ui-registry` |
| `waypoint.yaml` | `Gateway/waypoint` + `ConfigMap/waypoint-options` |
| `vmpodscrape.yaml` | `VMPodScrape/waypoint` |

> 🧷 Unlike its siblings, this chart's `Service` is **not** labelled `istio.io/global: "true"` — it
> is a leaf caller, nothing calls it cross-cluster.

---

## ⚙️ Configuration

### 🖼️ Image, scale, ports

```yaml
image:
  repository: harbor.jrclabs.xyz/alarmify/alarmify-ui
  tag: v0.0.115
  pullPolicy: IfNotPresent

replicas: 1
containerPort: 3000
servicePort: 80
```

> 🧭 There is **no `environment` key** in this chart at all — the UI takes its environment purely
> from `auth.appBaseUrl` and the hostname.

### 🔗 Backend URLs

```yaml
backendUrls:
  incidentApi:  "http://dev-alarmify-incident-api.alarmify-incident-api.svc"
  ingestApi:    "http://dev-alarmify-ingest-api.alarmify-ingest-api.svc"
  scheduleApi:  "http://dev-alarmify-schedule-api.alarmify-schedule-api.svc"
  identityApi:  "http://dev-alarmify-identity-api.alarmify-identity-api.svc"
```

🎉 **All four backend APIs migrated to dev** (`alarmify-apps-migration-plan.md`, Phases 3/5) — every
call is **same-cluster in-cluster DNS** now, with **no cross-cluster mesh dependency** for these.

> ⚠️ **These hostnames hardcode the `dev-` release prefix.** They match the `alarmify-*-as.yaml`
> template's `{{name}}-alarmify-<app>` naming (e.g. `dev-alarmify-incident-api`). If a second
> environment is ever generated, these **must** move to `values/<environment>.yaml` — they will
> silently point at dev otherwise.

### 🔓 Resources

```yaml
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    memory: 256Mi
```

> **The CPU limit was deliberately removed (2026-07-10)** — unbounded CPU burst, memory limit kept
> purely as the OOM backstop. **~0.1m observed actual usage** in VictoriaMetrics, hence the lower
> `50m` request compared with the APIs' `100m`.

### 🔑 External secrets

```yaml
externalSecrets:
  secretStore: vault-secretstore
  registryCredentialKey: alarmify/dev/harbor
  appVarsKeys:
    - alarmify/dev/alarmify-ui
  secretKeyRefs:
    - secretKey: ZITADEL_ISSUER
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_ISSUER }
    - secretKey: ZITADEL_PROJECT_ID
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_PROJECT_ID }
    - secretKey: ZITADEL_CLIENT_ID
      remoteRef: { key: alarmify/management/zitadel, property: ZITADEL_UI_CLIENT_ID }
```

Both feed `alarmify-ui-vars`, consumed via `envFrom` — but they are different ESO fields:

| Values key | Renders to | Supplies |
|---|---|---|
| `appVarsKeys` | `spec.dataFrom[].extract` | `SESSION_SECRET` — hand-seeded, **not** a Terraform output |
| `secretKeyRefs` | `spec.data[]` | the three `ZITADEL_*` vars, 🏗️ Terraform-owned |

👉 Procedures: **[`RUNBOOK.md`](./RUNBOOK.md)**.

#### Why `secretKeyRefs` and not another `appVarsKeys` entry

`alarmify/management/zitadel` is a shared, Terraform-owned object that also holds the identity-api
provisioner private key and the Kiali client secret. An `extract` would copy all of them into this
namespace, which has no use for any of them:

```yaml
appVarsKeys:
  - alarmify/management/zitadel     # ❌ would also copy the provisioner key + Kiali secret here
```

#### The `CLIENT_ID` / `UI_CLIENT_ID` rename

One entry above is deliberately **not** a 1:1 mapping:

```yaml
- secretKey: ZITADEL_CLIENT_ID                  # what the BFF reads
  remoteRef: { key: alarmify/management/zitadel,
               property: ZITADEL_UI_CLIENT_ID }  # what Terraform emits
```

The BFF reads the unprefixed name (`bff/zitadelOidc.ts:31`); Terraform prefixes it `UI_` so the
shared object can also carry `ZITADEL_KIALI_CLIENT_ID` without a collision.

#### Precedence: `data` beats `dataFrom`

ESO's `GetProviderSecretData` resolves every `dataFrom` entry first, then every `data` entry into
the same map, so `secretKeyRefs` wins on collision. `alarmify/dev/alarmify-ui` still carries its
own stale `ZITADEL_*` copies from before the consolidation — the Terraform-owned values override
them, so the stale set is inert. Pruning it is optional housekeeping, documented in
[`RUNBOOK.md`](./RUNBOOK.md).

> 🧬 Both `templates/external-secret.yaml` and the deployment's `envFrom` are wrapped in
> `{{- if .Values.externalSecrets.appVarsKeys }}` — set it empty and the chart renders **no
> ExternalSecret and no `envFrom`** at all, *including* the `secretKeyRefs` block nested inside it.

### 🔐 Auth

**Zitadel OIDC is the only auth flow** (`auth-api` removed 2026-07-07).

> 🧭 `auth.appBaseUrl` is **deliberately absent from `values.yaml`** — it is environment-specific and
> **must match both the environment's own public hostname and its Zitadel redirect URI**. It lives
> in `values/<environment>.yaml`.

### 🌐 HTTPRoute + external-dns

```yaml
httproute:
  path: /
  gatewayName: gateway
  gatewayNamespace: gateway-system
  gatewayListener: http
  externalDns:
    class: cloudflare
```

> 🧭 `hostname` and `externalDns.hostname`/`target` are environment-specific (which public hostname,
> which Cloudflare Tunnel) and live in `values/<environment>.yaml`. Only the structurally-common
> parts (path, gateway wiring, DNS class) live in `values.yaml`.

The rendered `HTTPRoute` carries `external-dns.alpha.kubernetes.io/hostname` and `…/class`
annotations.

> 🎯 **The `target` annotation is *not* here — it lives on the parent `Gateway`.**
> external-dns's `gateway-httproute` source **only reads `target` from `Gateway` resources, never
> from `HTTPRoute`s**.

---

## ⭐ The keepalive DestinationRule — REMOVED

The Proxmox repo shipped a `DestinationRule/{{ .Release.Name }}-keepalive` capping Envoy's
upstream idle timeout below Node's 5s `keepAliveTimeout` default, to stop intermittent 502/503
on `ui.jrclabs.xyz` from reused-but-already-closed upstream connections.

`DestinationRule` is an Istio CRD, so it went with the mesh. **The underlying bug is not fixed** —
it will resurface behind any proxy that pools upstream connections for longer than 5s. The
durable fix is app-side: `alarmify-ui`'s standalone `server.js` should set
`server.keepAliveTimeout` / `server.headersTimeout` above whatever proxy sits in front of it.

---

## 🌱 Environment overlay — `values/dev.yaml`

```yaml
auth:
  appBaseUrl: "https://ui.jrclabs.xyz"

httproute:
  hostname: ui.jrclabs.xyz
  externalDns:
    hostname: ui.jrclabs.xyz
```

Selected automatically for clusters labelled `environment: dev` (see
`helmcharts/argocd/templates/cluster/dev-cluster-secret.yaml`).

📜 **Migration:** `alarmify-ui` is **fully decommissioned from `management`** (Option D,
`alarmify-apps-migration-plan.md`) — dev is the only deployment target today, served through its
**own dedicated Cloudflare Tunnel** (`helmcharts/cloudflared/values/dev.yaml`), **not** management's
shared `proxmox-rke2` tunnel.

> 🎯 `externalDns.target` (the dedicated dev tunnel ID) is **intentionally not set here** — it lives
> on the parent `istio-gateway` `Gateway` (`helmcharts/istio/istio-gateway/values/dev.yaml`), because
> external-dns only reads `target` from `Gateway` resources.

---

## 🔧 Environment variables reaching the container

| Source | Variables | From |
|---|---|---|
| `envFrom` → `Secret/alarmify-ui-vars` | `SESSION_SECRET` | `alarmify/dev/alarmify-ui` (`dataFrom.extract`) |
| `envFrom` → `Secret/alarmify-ui-vars` | `ZITADEL_ISSUER`, `ZITADEL_PROJECT_ID`, `ZITADEL_CLIENT_ID` | `alarmify/management/zitadel` (`data`, per-key) |
| Literal `env` | `INCIDENT_API_BASE_URL`, `INGEST_API_BASE_URL`, `SCHEDULE_API_BASE_URL`, `IDENTITY_API_BASE_URL`, `APP_BASE_URL` | chart values |

> 🔀 **`ZITADEL_CLIENT_ID` maps from `ZITADEL_UI_CLIENT_ID`** in Vault — Terraform prefixes it
> `UI_` to distinguish it from the Kiali client. The BFF reads the unprefixed name
> (`bff/zitadelOidc.ts:31`), so `secretKeyRefs` renames it on the way in.

> 🔐 **No `auth.zitadel*` values on any chart any more** — all Zitadel config is Vault-only
> platform-wide as of 2026-08-01, so nothing shadows it. (incident/ingest carried such values
> until then, which silently pinned them to a retired project ID.)

---

## 🕸️ Waypoint & 📊 metrics

Ambient mode (`istio.io/dataplane-mode=ambient`) means **ztunnel only produces L4 (TCP) telemetry**
— no HTTP status codes, no request rates, no HTTP-level `AuthorizationPolicy` enforcement. The
waypoint terminates L7 so Kiali can draw this app with real HTTP semantics.

> 🔍 Investigated **2026-07-10**: the ambient TCP-only gap was hiding the
> `alarmify-ui → alarmify-incident-api` edge **and its 403 responses** entirely — **this app was
> the caller in that missing edge.**

Waypoint sizing (`ConfigMap/waypoint-options`, a strategic merge patch onto the istiod-generated
Deployment — [Istio docs](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/#configuring-gateways-with-infrastructure-parametersref)):

- 📉 **2026-07-11**: CPU `100m`/`2` (chart default) → `50m`/`200m`; all `alarmify-*` waypoints
  standardized. Memory untouched.
- 📉 **2026-07-11 (again)**: limit halved `200m` → `100m` — 24 h peak **5.7m** per VictoriaMetrics.

`VMPodScrape/waypoint` scrapes the waypoint's Envoy stats (`:15020/stats/prometheus`, 30s) — the
waypoint is an auto-provisioned Envoy pod that no existing `ServiceMonitor`/`PodMonitor` covers, and
vmagent only reads explicit `VMPodScrape`/`VMServiceScrape` objects. 💸 Config-only, no node cost.

---

## 🚀 Deployment (ApplicationSet)

Runs **only on dev** (Option D, `alarmify-apps-migration-plan.md`) — fully decommissioned from
`management`, **no stub left behind**. The former management-only generator branch
(`matchLabels: alarmify-ui: "true"`) is **removed entirely**. `hostname`/`externalDns` — which
differ per environment, e.g. for a future `prod` generator branch — live in
`values/<environment>.yaml`, **not** injected as ApplicationSet parameters. Same
`values.yaml` + `values/<environment>.yaml` split as `cert-manager`/`cloudflared`.
`ignoreMissingValueFiles` lets a future environment sync fine **before its overlay exists**.

### ⚰️ Dead sibling: `alarmifyui-as.yaml`

A **separate, older** ApplicationSet named `alarmifyui` still exists at
`helmcharts/argocd-apps/templates/applicationsets/alarmify/alarmifyui-as.yaml`. It is **inert**:

- 🚫 Its source path `manifests/alarmifyui/overlays/{dev,prod}` **does not exist** in this repo.
- 🚫 Its gating labels `alarmifyui-dev` / `alarmifyui-prod` are **commented out** in
  `helmcharts/argocd/templates/cluster/local-cluster-secret.yaml`, so it generates **zero**
  Applications.

⚠️ It is a kustomize-based leftover from before this Helm chart. **Not** the chart documented here.
It is a cleanup candidate — left in place pending a decision.

---

## 🩺 Live status (`dev`, checked 2026-07-31)

🟢 **Healthy — the only `alarmify-*` app actually running.**

| Check | Status |
|---|---|
| `dev-alarmify-ui` pod | ✅ `1/1 Running` (since 2026-07-30) |
| Waypoint pod | ✅ `1/1 Running` |
| `ExternalSecret/alarmify-ui-vars` | ✅ `SecretSynced`, `Ready=True` |
| `ExternalSecret/harbor-registry-credentials` | ✅ `SecretSynced` |
| Image `…/alarmify-ui:v0.0.115` | ✅ pulls — **the only alarmify tag that resolves in Harbor** |

> ⚠️ **But the UI has nothing to talk to.** All four `backendUrls` targets are in
> `ImagePullBackOff`, so every proxied call fails. Expect login to work (Zitadel is external) and
> every data view to error.

---

## 🧪 Quick triage

```bash
export KUBECONFIG=~/.kube/talos-dev.yaml

kubectl -n alarmify-ui get pods,externalsecret,secret,httproute,destinationrule
kubectl -n alarmify-ui logs deploy/dev-alarmify-ui --tail=100

# Public route end-to-end
curl -sI https://ui.jrclabs.xyz | head -20

# The 502/503 signature the DestinationRule fixes — check Envoy's own counters
kubectl -n alarmify-ui exec deploy/waypoint -c istio-proxy -- \
  curl -s localhost:15020/stats/prometheus \
  | grep -E 'upstream_cx_connect_fail|upstream_rq_pending_failure_eject|upstream_cx_destroy_remote'

# Is the DestinationRule actually applied?
kubectl -n alarmify-ui get destinationrule dev-alarmify-ui-keepalive \
  -o jsonpath='{.spec.trafficPolicy.connectionPool.http}{"\n"}'
```

---

## 📚 Related

- 🔐 [`RUNBOOK.md`](./RUNBOOK.md) — Vault secrets, tactical
- 🗝️ [`../vault.md`](../vault.md) — Vault commands for **all** `alarmify-*` apps
- 🚪 `helmcharts/istio/istio-gateway` — the parent `Gateway` (holds the external-dns `target`)
- ☁️ `helmcharts/cloudflared` — the dedicated dev tunnel serving `ui.jrclabs.xyz`
- 🏗️ `alarmify-common-infra/terraform/zitadel` — seeds this app's Vault object
- 📖 `defyjoy/alarmify-docs` — migration plans, Istio runbooks
