# nats

NATS with JetStream — the event bus behind Alarmify's ingestion pipeline.

> ⚠️ Unrelated to the NATS bundled inside [`argo-events`](../argo-events/README.md), which runs
> its own EventBus.

---

## Authorization model

```yaml
nats:
  authUsers:
    enabled: true
    insecureAllowAnonymous: false
    defaultSubjectPattern: ">"
    existingSecret: ""
    secret:
      create: true
      includeKey: auth-users.inc
```

Application users are rows under `clients` — no extra Helm template or env var per user. The
chart renders **one JSON include** into a Secret, which NATS loads via `50$include`.

> 🔒 **Anonymous clients are rejected by default.** Do not set `enabled: false` unless
> `insecureAllowAnonymous: true` — and that combination deploys NATS with **no authorization at
> all** (any client may connect). Never use it in production.

To supply the include yourself, pre-create a Secret with key `auth-users.inc` holding a JSON
body like `{"authorization":{"users":[...]}}`, set `existingSecret`, and leave
`secret.create: false`.

### Client modes

Subject rules below are **NATS subject namespaces, not IP subnets**.

| Mode | Grants |
|---|---|
| `publish-only` | optional `publishSubjects`, `publishDenySubjects`, `subscribeAllowSubjects`, `subscribeDenySubjects` |
| `consume-only` | `subscribeSubjects`, else `subjectPattern`, else `defaultSubjectPattern` |
| `full` | publish + subscribe on `defaultSubjectPattern` (or `subjectPattern`) — **required for the JetStream CLI** (`nats stream ls`) and for nats-box defaults |

> 📈 At larger scale, prefer JWT/resolver or auth callout over growing this list.

### The three configured clients

```yaml
clients:
  - user: alarmify-ingest-api
    mode: publish-only
    publishSubjects:
      - "alarmify.events.raw"
      - "alarmify.events.raw.*"
    subscribeAllowSubjects:
      - "_INBOX.>"
```

Aligned with the alarmify-ingest-api NATS ACL runbook: the raw event stream subject plus
JetStream publish-ack inboxes.

Per **ADR-001** (tenant-scoped subject hierarchy), the publish subject moved from the flat
`alarmify.events.raw` to `alarmify.events.raw.{tenant_id}`. The single-token wildcard
`alarmify.events.raw.*` is scoped **tighter than the stream's own filter** to match ADR-001's
exact shape — one `tenant_id` segment, not `alarmify.events.raw.>`.

> ⏳ The bare `alarmify.events.raw` entry exists only for the migration's transition window
> (subject-hierarchy-migration-runbook §1.3). **Drop it once the stream is fully cut over.**

```yaml
  - user: alarmify-event-processor
    mode: publish-only
    publishSubjects:
      - "$JS.API.CONSUMER.INFO.ALARMIFY_EVENTS_RAW.>"
      - "$JS.API.CONSUMER.MSG.NEXT.ALARMIFY_EVENTS_RAW.>"
      - "$JS.API.CONSUMER.CREATE.ALARMIFY_EVENTS_RAW.>"
      - "$JS.ACK.ALARMIFY_EVENTS_RAW.>"
    publishDenySubjects: ["$SYS.>"]
    subscribeAllowSubjects: ["_INBOX.>"]
    subscribeDenySubjects: ["$JS.API.>", "$SYS.>"]
```

Counter-intuitively **`publish-only`, not `consume-only`** — JetStream pull consumers publish
control-plane requests (`CONSUMER.INFO`, `MSG.NEXT`) and ACKs, so a consume-only grant would not
work.

The explicit non-JetStream deny (`$SYS.>`) is kept so the helper does not auto-inject a blanket
`$JS.API.>` deny, which would break the four allows above.

```yaml
  - user: ops
    mode: full
```

Wide app + JetStream (`$JS.API.*`, `_INBOX.*`) access, **for operators only**.

> 🔑 All three passwords are `changeme-*` placeholders in `values.yaml`. Rotate them and tighten
> `ops`'s `subjectPattern` before treating this as production.

---

## JetStream bootstrap

```yaml
nats:
  jetstreamBootstrap:
    enabled: false
    natsUser: ops
    natsPassword: changeme-ops
    streams: []
```

GitOps-managed stream/consumer provisioning. Runs as an **ArgoCD PostSync hook Job** using the
`ops` identity — per `docs/operations/nats-access-control.md`, only a bootstrap/admin identity
may create/update/delete streams and consumers, and this is the same identity natsBox's default
context already uses for exactly this purpose.

Disabled by default (base/management); enable and list streams per environment in
`values/<environment>.yaml`. **Idempotent** — each stream/consumer is created only if absent, so
re-running on every sync is safe.

Schema per entry:

```yaml
- name: STREAM_NAME
  subjects: "some.subject.*"
  storage: file          # file|memory, default file
  retention: limits      # limits|interest|work, default limits
  maxAge: 24h            # default 24h
  dupeWindow: 2m         # default 2m
  consumers:
    - name: durable-name
      filterSubject: "some.subject.*"
      ackPolicy: explicit    # default explicit
      deliverPolicy: all     # default all
      pull: true             # default true
```

---

## Configuration

### External exposure — internal L4 LoadBalancer

```yaml
externalExposure:
  enabled: true
```

Renders `templates/nats-internal-lb.yaml`: a `LoadBalancer` Service `<release>-nats-lb` on `4222`,
reachable from the VPC but not the internet (`networking.gke.io/load-balancer-type: Internal`).
Costs one internal LB IP.

It is a **separate** Service rather than a patch of the subchart's `local-nats`, which stays
ClusterIP. In-cluster clients keep their direct path and are unaffected by LB provisioning or by
this toggle.

The selector is copied from the subchart's own Service (verified against nats chart `2.12.6`):

```yaml
app.kubernetes.io/component: nats
app.kubernetes.io/instance: <release>
app.kubernetes.io/name: nats
```

It deliberately omits `app.kubernetes.io/version`, which the subchart *does* set on its labels —
including it would silently orphan this Service on the next chart bump, leaving an LB with no
endpoints.

#### It used to be a TCPRoute

This replaced a `TCPRoute` on the `nats` listener of `gateway-system/gateway`, which could not
work on GKE: the Gateway API **standard channel** has no `TCPRoute` kind (the Application failed
to sync), and every GatewayClass here is an L7 HTTP(S) load balancer, which cannot carry the NATS
client protocol.

**Do not replace this with an HTTPRoute.** NATS speaks a custom line protocol, not HTTP; the route
would attach cleanly and then blackhole every connection. If HTTP-level access is ever genuinely
needed, enable the subchart's **websocket** listener and route *that* — it is real HTTP.

### JetStream storage

```yaml
nats:
  config:
    jetstream:
      enabled: true
      fileStore:
        pvc:
          enabled: true
```

> 📌 The PVC toggle exists to avoid an **immutable StatefulSet `volumeClaimTemplates` change** on
> existing installs. If you need to flip it, expect a one-time StatefulSet recreation.

### Mounting the auth include

The `podTemplate.patch` and `reloader.patch` blocks both mount the auth-users Secret at
`/etc/nats-config/includes`.

> 🧩 **Both mounts are required.** The reloader lists `$include` targets but only inherits the
> NATS mounts present *at render time* — before `podTemplate` patches are applied. Without the
> second mount, `/etc/nats-config/includes/users.inc` does not exist when the reloader starts.

### Metrics

```yaml
nats:
  promExporter:
    enabled: true
    port: 7777
    podMonitor:
      enabled: false
```

Net-new observability from **ADR-001 implementation plan Phase 5** — nothing scraped
NATS/JetStream before this. `config.monitor` (port 8222) is already on by upstream default; this
adds the exporter sidecar.

The upstream `PodMonitor` is deliberately **off on both clusters**, replaced by a `VMPodScrape`
declared directly in `templates/vmpodscrape.yaml`:

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMPodScrape
metadata:
  name: {{ include "wrapper.nats.fullname" . }}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nats
      app.kubernetes.io/instance: {{ .Release.Name }}
      app.kubernetes.io/component: nats
  podMetricsEndpoints:
    - port: prom-metrics
      interval: 30s
```

`victoria-metrics-operator` would mirror a `PodMonitor` into a `VMPodScrape` anyway, but it copies
the parent's annotations verbatim — including Argo's `argocd.argoproj.io/tracking-id`. The mirror
then claims to belong to `local-nats` while carrying a tracking-id that names `PodMonitor`, a kind
it isn't, and appears in no manifest. Argo flags it as an extra resource it can never reconcile, the
operator recreates it, and the Application sits `OutOfSync` forever. Declaring the `VMPodScrape`
ourselves makes the object real, tracked, and reconcilable — the same pattern `istio-eastwest`,
`istio-gateway` and `ztunnel` already use.

This also removes the need for a dev-specific override: a `VMPodScrape` needs no Prometheus Operator
CRDs, so the same manifest works on both clusters.

### nats-box

```yaml
nats:
  natsBox:
    enabled: true
    contexts:
      default:
        merge:
          user: ops
          password: changeme-ops
    homePvc:
      enabled: true
      size: 1Gi
      storageClassName: ""
```

The default context **must** carry credentials, since anonymous is rejected. It uses `ops`
(mode `full`) so JetStream commands like `nats stream ls` work.

`homePvc` gives a durable workspace; `storageClassName: ""` uses the cluster default. nats-box
runs as root (the default image user).

### Resources

```yaml
nats:
  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 200m }
```

### Node scheduling — pinned off spot nodes

**2026-08-12:** `podTemplate.merge.spec.nodeSelector` sets `storage: persistent` on the main NATS
StatefulSet (it owns the JetStream file-store PVC). The cluster's node pool mixes spot nodes
(reclaimed by GCP with little warning) with a stable "system" group; when spot nodes were
terminated, PVC-backed pods cluster-wide went `Pending`. `storage: persistent` is a label applied
directly to the system node group outside this repo (same change made in `vault`, `harbor`,
`tempo`, `cloudnative-pg`, and `victoria-metrics`).

Note the top-level `nats.nodeSelector: {}` field elsewhere in `values.yaml` is dead — this chart's
upstream templates only read `podTemplate.merge`/`.patch` (a generic JSON-merge-patch target), not
a plain `nodeSelector` key, so setting that field silently does nothing.

---

## dev overlay — `values/dev.yaml`

Layered on top of `values.yaml` when synced to a cluster labelled `environment: dev`, selected
by `helmcharts/argocd-apps/templates/applicationsets/nats-as.yaml`.

### PodMonitor must be off on dev

```yaml
nats:
  promExporter:
    podMonitor:
      enabled: false
```

> 🚫 **dev has no `victoria-metrics-operator`** — only `victoria-metrics` itself, a local VMAgent
> remote-writing to management's central VMCluster. The `PodMonitor` **CRD** therefore does not
> exist on dev, and leaving this enabled fails the sync with `SyncFailed: CRD not found`.

### JetStream bootstrap is enabled on dev

```yaml
nats:
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

Both [`alarmify-event-worker`](../alarmify/alarmify-event-worker/README.md) (consumer) and
[`alarmify-ingest-api`](../alarmify/alarmify-ingest-api/README.md) (publisher) **require this
stream and consumer to exist before they can start**.

This was previously a manual, out-of-band step. The stream was created by hand on 2026-07-21;
the `jetstream-bootstrap-job` PostSync hook now provisions the same config declaratively, so it
is fully GitOps-managed on dev.

Note the subject is the ADR-001 tenant-scoped form `alarmify.events.raw.*`, matching the
`alarmify-ingest-api` publish grant above.
