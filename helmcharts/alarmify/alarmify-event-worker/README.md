# 🛠️ alarmify-event-worker

JetStream consumer for the Alarmify ingestion pipeline. It pulls raw events off the
`ALARMIFY_EVENTS_RAW` stream via the `alarmify-event-processor` durable and writes them to
Postgres. No HTTP surface, no Service, no Route — it is a **pure worker**.

> 📌 **This chart carried its design notes as YAML comments.** They have all been moved here.
> The `values.yaml` / `values/dev.yaml` / `templates/*` files are now comment-free; this README
> is the source of truth for *why* each value is what it is.

---

## 📍 At a glance

| Fact | Value |
|---|---|
| 🏷️ Chart | `helmcharts/alarmify/alarmify-event-worker` (`version: 0.1.0`, `appVersion: v0.0.9`) |
| 📦 Image | `harbor.workquark.org/alarmify/alarmify-event-worker:v0.0.10` |
| 🌍 Clusters | **`dev` only** — decommissioned from `management` |
| 📛 Namespace | `alarmify-event-worker` (created by the ApplicationSet) |
| 🚀 ArgoCD App | `dev-alarmify-event-worker` (`automated.prune` + `selfHeal: true`) |
| 🔀 ApplicationSet | `helmcharts/argocd-apps/templates/applicationsets/alarmify/alarmify-event-worker-as.yaml` |
| 🕸️ Mesh | Istio **ambient** + per-namespace **waypoint** (L7) |
| 🔐 Secrets | HashiCorp Vault → External Secrets Operator → `alarmify-event-worker-vars` |
| 📊 Metrics | `VMPodScrape/waypoint` → vmagent → VictoriaMetrics |

---

## 🧩 What the chart renders

| Template | Object | Purpose |
|---|---|---|
| `deployment.yaml` | `Deployment/{{ .Release.Name }}` | the worker pod |
| `external-secret.yaml` | `ExternalSecret/alarmify-event-worker-vars` | app env vars from Vault |
| `harbor-registry-external-secret.yaml` | `ExternalSecret/harbor-registry-credentials` | → `Secret/alarmify-event-worker-registry` (imagePullSecret) |
| `waypoint.yaml` | `Gateway/waypoint` + `ConfigMap/waypoint-options` | ambient L7 proxy + its sizing patch |
| `vmpodscrape.yaml` | `VMPodScrape/waypoint` | scrapes the waypoint's Envoy stats |

---

## 🔄 Data flow

```
alarmify-ingest-api  ──publish──▶  NATS JetStream (dev-nats)
                                   stream:   ALARMIFY_EVENTS_RAW
                                   subject:  alarmify.events.raw.{tenant_id}
                                        │
                                        ▼
                       durable pull consumer: alarmify-event-processor
                                   filter:   alarmify.events.raw.*
                                        │
                                        ▼
                            alarmify-event-worker  ──▶  Postgres
                                                       (cloudnative-pg, management)
```

---

## ⚙️ Configuration

### 🖼️ Image & scale

```yaml
image:
  repository: harbor.workquark.org/alarmify/alarmify-event-worker
  tag: v0.0.10
  pullPolicy: IfNotPresent

replicas: 1
environment: prod
debug: "true"
```

> ⚠️ `environment: prod` is the **base** default; `values/dev.yaml` overrides it to `dev`. Since
> the ApplicationSet only targets `dev` clusters, the effective value is always `dev`.

### 📨 NATS

```yaml
nats:
  url: "nats://local-nats.nats.svc.cluster.local:4222"
  stream: "ALARMIFY_EVENTS_RAW"
  consumer: "alarmify-event-processor"
  user: "alarmify-event-processor"
  mode: "jetstream"
  subject: "alarmify.events.raw.*"
```

🚫 **Never point `nats.url` at `nats.home.arpa`.** That hairpins out to the `istio-gateway`
TCPRoute and back; ambient clients get `EOF`. Always use in-cluster Service DNS. Same root cause
as the Postgres TCPRoute incident — see
[alarmify-docs / istio](https://github.com/Alarmify/alarmify-docs/blob/main/docs/istio/index.md).

🧬 **`subject` is a tenant-scoped wildcard** per **ADR-001**
(`alarmify-docs/docs/ingestion/adr-001-tenant-scoped-subject-hierarchy.md`). It used to be the
flat literal `alarmify.events.raw`.

> 🛑 **Migration ordering matters.** ArgoCD runs `automated` + `selfHeal`, so a change to
> `subject` syncs immediately. Do **not** let it sync before completing, in order (per
> `subject-hierarchy-migration-runbook.md`):
>
> 1. Widen the `ALARMIFY_EVENTS_RAW` stream to accept `alarmify.events.raw.*`
> 2. Redeploy `alarmify-ingest-api` publishing to `alarmify.events.raw.{tenant_id}`
> 3. Update the **existing** durable's filter:
>    ```bash
>    nats consumer edit ALARMIFY_EVENTS_RAW alarmify-event-processor \
>      --filter "alarmify.events.raw.*"
>    ```
>
> 💥 `event-worker/src/consumers/raw_event_consumer.go` **fails loudly at startup** if the live
> `FilterSubject` doesn't match this value. **That is by design, not a bug** — it prevents silent
> misconsumption.

### 📈 Resources

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
```

> 🔓 **The CPU limit was deliberately removed (2026-07-10)** to allow unbounded CPU burst. The
> memory limit is kept purely as the OOM backstop. `talos-prod` nodes are CPU-tight, so throttling
> a bursty consumer hurt throughput more than it protected neighbours.

### 🔑 External secrets

```yaml
externalSecrets:
  secretStore: vault-secretstore
  registryCredentialKey: alarmify/dev/harbor
  appVarsKeys:
    - alarmify/dev/alarmify-event-worker
    - alarmify/dev/postgres/credentials
  dbHostOverride: ""
```

> 🧷 `alarmify/dev/postgres/credentials` supplies the shared `DB_*` keys — same pattern as
> incident/identity/schedule. Those keys today *also* live on the worker's own Vault object;
> keeping this second extract makes the merge resilient if they ever exist only on the shared path.
> `mergePolicy: Replace` means the **last** object listed wins on overlapping keys.

👉 Full Vault procedures: **[`RUNBOOK.md`](./RUNBOOK.md)**.

---

## 🌱 Environment overlay — `values/dev.yaml`

```yaml
environment: dev

externalSecrets:
  dbHostOverride: postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local

nats:
  url: "nats://dev-nats.nats.svc.cluster.local:4222"
```

Layered on top of `../values.yaml` when the chart syncs to a cluster whose Secret carries the
label `environment: dev`. Selection is automatic via the ApplicationSet.

### 📜 Migration history

`alarmify-event-worker` migrated to `dev` per `alarmify-apps-migration-plan.md` **Phase 6** — the
**last app migrated**. Management's copy is **fully decommissioned, no stub left behind** (the same
"Option D" shape as `alarmify-ui` / `alarmify-ingest-api`). It depends on both:

- 🐘 **Postgres** in `management`, reached through Istio's native ambient global-service path.
- 📨 **NATS** — dev's own local instance (Phase 2). **Same-cluster now**, not cross-cluster, since
  both this app and its publisher `alarmify-ingest-api` live on `dev`.

`dbHostOverride` is injected as a literal `DB_HOST` env var and **supersedes** whatever Vault's
shared `postgres/credentials` object holds.

### 🏗️ JetStream prerequisites — chart-managed since 2026-07-21

This app **requires** the `ALARMIFY_EVENTS_RAW` stream and the `alarmify-event-processor` durable
consumer to already exist on dev's NATS.

Since **2026-07-21** both are provisioned by `helmcharts/nats` —
`jetstreamBootstrap` in `values/dev.yaml`, rendered by `templates/jetstream-bootstrap-job.yaml`
as an **idempotent ArgoCD PostSync hook Job** on the `nats` Application, using exactly the config
this chart expects:

```yaml
# helmcharts/nats/values/dev.yaml
jetstreamBootstrap:
  enabled: true
  streams:
    - name: ALARMIFY_EVENTS_RAW
      subjects: "alarmify.events.raw.*"
      storage: file
      retention: limits
      maxAge: 24h
      dupeWindow: 2m
      consumers:
        - name: alarmify-event-processor
          filterSubject: "alarmify.events.raw.*"
          ackPolicy: explicit
          deliverPolicy: all
          pull: true
```

Management's original copies were still created **manually** (out of scope for that chart's
base/prod values). ⚡ If this app's Deployment ever races ahead of the nats Application's PostSync
hook, it **fails loudly at startup** rather than silently misconsuming.

---

## 🕸️ Waypoint (Istio ambient L7)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  labels:
    istio.io/waypoint-for: service
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
```

Ambient mode (`istio.io/dataplane-mode=ambient`) means **ztunnel only produces L4 (TCP) telemetry**
— no HTTP status codes, no request rates, no HTTP-level `AuthorizationPolicy` enforcement. A
waypoint terminates L7 for this namespace, which is what lets Kiali draw the app into the service
graph with real HTTP semantics.

> 🔍 Investigated **2026-07-10**: the ambient TCP-only gap was hiding the
> `alarmify-ui → alarmify-incident-api` edge **and its 403 responses** entirely.

### 🎚️ Waypoint sizing

```yaml
# ConfigMap/waypoint-options — strategic merge patch onto the istiod-generated Deployment
deployment: |
  spec:
    template:
      spec:
        containers:
        - name: istio-proxy
          resources:
            requests:
              cpu: 50m
            limits:
              cpu: 100m
```

- 📉 **2026-07-11**: CPU trimmed from the chart default `100m` / `2` → `50m` / `200m`. All
  `alarmify-*` waypoints standardized to the same low-traffic proxy sizing. Memory left untouched.
- 📉 **2026-07-11 (again)**: CPU limit halved `200m` → `100m` — 24 h peak was **5.5m** per
  VictoriaMetrics.
- 📖 Mechanism: [Istio — configuring gateways with `infrastructure.parametersRef`](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/#configuring-gateways-with-infrastructure-parametersref)

---

## 📊 Metrics — `VMPodScrape/waypoint`

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodScrape
metadata:
  name: waypoint
spec:
  selector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: waypoint
  podMetricsEndpoints:
    - port: ""
      targetPort: 15020
      path: /stats/prometheus
      interval: 30s
```

Scrapes this namespace's ambient waypoint proxy so east-west (service-to-service) traffic —
**including HTTP response codes like 403/5xx** — shows up in Kiali/VictoriaMetrics.

Same root cause and fix as `helmcharts/istio/istio-gateway/templates/vmpodscrape.yaml`: the waypoint is
an **auto-provisioned Envoy pod**, not covered by any existing `ServiceMonitor`/`PodMonitor`, and
vmagent only picks up explicit `VMPodScrape`/`VMServiceScrape` objects — **not**
`prometheus.io/scrape` annotations alone.

> 💸 **Zero cost.** This is a config-only change: it adds one scrape target to the already-running
> vmagent (interval matches istio-gateway/ztunnel). It does not run a pod and does not touch the
> waypoint's own requests/limits.

---

## 🚀 Deployment (ApplicationSet)

```yaml
generators:
  - clusters:
      selector:
        matchExpressions:
          - key: environment
            operator: In
            values: [dev]
      values:
        environment: dev
        namespace: alarmify-event-worker
```

- 🎯 **dev-only.** Per `alarmify-apps-migration-plan.md` Phase 6, the app was fully decommissioned
  from `management` with no stub left behind (same shape as `alarmify-ui` / `alarmify-ingest-api`).
  The former management-only generator branch (`matchLabels: alarmify-event-worker: "true"`) is
  **removed entirely**.
- 🧾 `nats.url` lives in `values/dev.yaml`, **not** injected as an ApplicationSet parameter — the
  same `values.yaml` + `values/<environment>.yaml` split used by `alarmify-ui` /
  `alarmify-ingest-api`.
- 🏷️ The namespace is labelled `istio.io/dataplane-mode: ambient` and
  `istio.io/use-waypoint: waypoint` via `managedNamespaceMetadata`.

---

## 🔧 Environment variables reaching the container

| Source | Variables |
|---|---|
| `envFrom` → `Secret/alarmify-event-worker-vars` | `NATS_USER`, `NATS_PASSWORD`, `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSLMODE`, `DB_TIMEZONE` |
| Literal `env` from values | `ENVIRONMENT`, `DEBUG`, `NATS_URL`, `NATS_STREAM`, `NATS_CONSUMER`, `NATS_USER`, `NATS_MODE`, `NATS_SUBJECT` |
| Literal `env`, only if `dbHostOverride` set | `DB_HOST` |

> ⚠️ **`NATS_USER` and `DB_HOST` are set twice** — once from the Secret via `envFrom`, once as a
> literal `env` entry. Kubernetes gives **`env` precedence over `envFrom`**, so the chart values
> win over Vault for both. Change them in `values.yaml` / `values/dev.yaml`, not in Vault.

---

## 🩺 Live status (`dev`, checked 2026-07-31)

🔴 **The workload is currently down.** Two independent blockers:

| # | Symptom | Root cause |
|---|---|---|
| 1️⃣ | `ExternalSecret/alarmify-event-worker-vars` → `SecretSyncedError`, `Ready=False` | ESO: `error processing spec.dataFrom[0].extract, err: Secret does not exist` — the Vault object **`kv/alarmify/dev/alarmify-event-worker` does not exist**. `Secret/alarmify-event-worker-vars` was therefore never created. |
| 2️⃣ | Pod in `ImagePullBackOff` for ~3d21h (24 785 back-offs) | `harbor.workquark.org/alarmify/alarmify-event-worker:v0.0.10` cannot be pulled. Note `Chart.yaml` declares `appVersion: v0.0.9` while `values.yaml` pins `v0.0.10` — verify the tag actually exists in Harbor. |

✅ Healthy in the same namespace: the `waypoint` pod (1/1), `Secret/alarmify-event-worker-registry`
(harbor ES syncing fine), and dev's NATS — `ALARMIFY_EVENTS_RAW` exists with subject
`alarmify.events.raw.*` and the `alarmify-event-processor` durable is present with a matching
filter (`num_pending: 0`, `messages: 0` — nothing has been published yet).

🔨 Fix #1 with [`RUNBOOK.md` → Create the app object](./RUNBOOK.md#1️⃣-create-the-app-object).

---

## 🧪 Quick triage

```bash
export KUBECONFIG=~/.kube/talos-dev.yaml

kubectl -n alarmify-event-worker get pods,externalsecret,secret
kubectl -n alarmify-event-worker logs deploy/dev-alarmify-event-worker --tail=100
kubectl -n alarmify-event-worker describe pod -l app.kubernetes.io/name=alarmify-event-worker

# JetStream state
NATSBOX=$(kubectl -n nats get pod -l app.kubernetes.io/name=nats-box -o name | head -1)
kubectl -n nats exec "$NATSBOX" -- \
  nats --server nats://dev-nats.nats.svc.cluster.local:4222 stream info ALARMIFY_EVENTS_RAW
kubectl -n nats exec "$NATSBOX" -- \
  nats --server nats://dev-nats.nats.svc.cluster.local:4222 \
  consumer info ALARMIFY_EVENTS_RAW alarmify-event-processor
```

---

## 📚 Related

- 🔐 [`RUNBOOK.md`](./RUNBOOK.md) — Vault secrets, tactical
- 🗝️ [`../vault.md`](../vault.md) — Vault commands for **all** `alarmify-*` apps
- 📨 `helmcharts/nats` — stream/consumer bootstrap
- 🔑 `helmcharts/external-secrets` — `ClusterSecretStore/vault-secretstore`
- 📖 `defyjoy/alarmify-docs` — ADRs, migration plans, runbooks
