# argocd-google-cloud repo — Claude instructions

> Forked from `defyjoy/ArgoCD` (Proxmox/Talos) on 2026-08-09 with the Istio, Step CA and
> Longhorn charts removed. **Read the "Known gaps" section of README.md before assuming any
> north-south routing, certificate issuance or cross-cluster call works** — several do not.

## Cluster access

**There are only two clusters: `management` and `dev`. There is no prod.** Argo CD
itself runs on management (that is the `local` cluster the ApplicationSets gate on)
and also deploys to dev as a registered remote cluster.

Ask which cluster to debug before running anything. Set `KUBECONFIG` to that cluster's
context; treat both as **read-only** unless explicitly told otherwise.

### `prod` in a path or name is a bug, not an environment

Vault's env segment is the **cluster name** — `vault kv list kv/alarmify` returns
only `dev/`, `local/`, and `management/`. Any `alarmify/prod/...` path resolves to
nothing, and External Secrets fails the whole ExternalSecret when one key is
missing.

This is not cosmetic. `alarmify/prod/alertmanager-oauth` (corrected 2026-08-01)
meant the `alarmify-oauth` Secret was never created, which meant prometheus-operator
could not resolve the global `AlertmanagerConfig`'s `oauth2.clientSecret`, which
meant **no Alertmanager StatefulSet was ever created** — and `vmalert` silently
dropped every alert in the cluster for seven days. Treat a stale Vault path as an
outage waiting to happen, and check `kubectl get externalsecret -A` before trusting
that a component is healthy.

Ephemeral debug pods (`kubectl run ...`) must satisfy the `restricted`
PodSecurity policy enforced cluster-wide, or they are rejected outright.
Minimum required `securityContext`:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
```

## Cloudflare

```
dev tunnel id - 64478596-9fd7-4d58-a792-ae3b95d3ea98
management tunnel id - 9da192fd-9481-44a4-a379-f205b66549b7
```

## Monitoring stack

- `prometheus.enabled: false` in `helmcharts/kube-prometheus-stack` — Prometheus itself was
  decommissioned during the VictoriaMetrics cutover (2026-07-10). Scraping and alert evaluation
  now run exclusively via VictoriaMetrics (`helmcharts/victoria-metrics`, `helmcharts/victoria-metrics-operator`).
- `victoria-metrics-operator` mirrors every `ServiceMonitor`/`PodMonitor`/`PrometheusRule` into
  `VMServiceScrape`/`VMPodScrape`/`VMRule` unconditionally (`selectAllByDefault: true`, no label
  filter) — so declaring a `ServiceMonitor`/`PodMonitor` anywhere in the cluster is sufficient for
  it to be scraped; no separate VictoriaMetrics-specific config needed.
- Grafana (`kube-prometheus-stack` chart) reads from `vmselect`, not Prometheus.
- Full details: `defyjoy/alarmify-docs` repo, `docs/victoria-metrics/migration-runbook.md`.

## ApplicationSet cluster labels

Every `ApplicationSet` here gates on a `cluster-generator` `matchLabels` selector against the
`local` cluster Secret (namespace `argocd`). That Secret is itself GitOps-managed by the
self-managed `argocd` `Application` (`helmcharts/argocd-apps/templates/applications/argocd.yaml`,
`automated.prune`/`selfHeal: true`) from the template
`helmcharts/argocd/templates/cluster/local-cluster-secret.yaml`.

**Never `kubectl label secret -n argocd local <name>=true` directly on the live cluster** to turn
on a new component — `selfHeal: true` means the next reconcile silently reverts any label not
also present in that template, and the change isn't reproducible from git. Instead, add the
label declaratively in `local-cluster-secret.yaml`, commit, and push; the self-managed `argocd`
`Application` picks it up and applies it automatically — no manual `kubectl label` step needed.

## Helm chart conventions

These apply to **every** chart under `helmcharts/`, including new ones. Derived from the
2026-08-01 sweep that moved ~2,400 comment lines out of values files.

### values files carry no comments — rationale lives in the chart README

`values.yaml` and `values/<env>.yaml` are **pure data**. Every explanation goes in that chart's
`README.md`, written as prose **with the YAML snippet it explains quoted alongside**. Do not
transcribe comments; explain the *why*, and show the config it applies to.

```bash
task lint:values        # exit 1 if any values file has comments
task lint:values:fix    # strip them (refuses if parsed YAML would change)
task hooks:install      # one-time: symlink the pre-commit hook that runs the check
```

The pre-commit hook (`scripts/git-hooks/pre-commit`) runs the check whenever a values file is
staged; bypass a single commit with `git commit --no-verify`.

Two rules the script encodes, worth knowing when hand-editing:

- **Comments inside a YAML block scalar (`key: |`) are string DATA, not comments.** The HCL
  comments in `helmcharts/vault`'s raft `config: |` are part of Vault's config file. Never strip
  them — including their trailing whitespace.
- **Never bulk-edit values files without proving the parse is unchanged.** Compare
  `yaml.safe_load` before/after, then `helm template` byte-for-byte.

### Every chart needs a README

Minimum: what the chart is, upstream chart/image, which cluster(s) it targets, and a
`## Configuration` section covering anything non-obvious. If a value exists because something
broke, say what broke — those notes are the highest-value content in this repo.

The only dirs without one are the umbrellas `alarmify/`, `staypingo/` and `argocd-apps/`.

### Three charts are non-deterministic

`harbor` (generated secrets + self-signed CA) and `plane` (`now` timestamps) render differently
every time. To validate a change, render twice from the *unchanged* file first to learn the
noise, then compare with those fields masked.

### Secrets never live in values files

Use Vault + External Secrets. `harbor` and `plane` still carry committed placeholder
credentials — do not copy that pattern.

### Never shadow Vault with a literal `env`

Kubernetes ranks `env` above `envFrom`, so a chart value rendered as a literal `env` entry
**silently overrides** anything External Secrets delivers. This pinned `alarmify-incident-api`
and `alarmify-ingest-api` to a retired Zitadel project ID until 2026-08-01, rejecting every
token, with nothing looking unhealthy.

If a value comes from Vault, it must **not** also exist as a chart value.

### External Secrets: two lists, two meanings

| Values key | Renders to | Semantics |
|---|---|---|
| `appVarsKeys` | `spec.dataFrom[].extract` | copies **every** field of the object |
| `secretKeyRefs` | `spec.data[]` | copies **one named** property per entry |

- ESO resolves `dataFrom` first, then `data` — so **`secretKeyRefs` wins** on key collision.
- Use `secretKeyRefs` for any shared Vault object, so unrelated secrets in it don't land in the
  namespace. `alarmify/management/zitadel` is Terraform-owned and shared; never `extract` it.
- **Do not add a Vault path to `appVarsKeys` just to satisfy `dataFrom`.** ESO fails the *whole*
  ExternalSecret when any entry is missing, so an empty placeholder object is pure downside — it
  took `alarmify-schedule-api` down exactly this way.

### Per-cluster config goes in overlays

`values/<env>.yaml` holds anything genuinely per-cluster (network identity, addresses, hostnames,
tunnel IDs). Keep it out of the base file.

- **Omit the base default when a missing override should be loud.** `victoria-metrics` sets
  `externalLabels: {}` so unlabelled series are obvious rather than silently wrong.
- **Helm replaces lists wholesale — it does not merge them.** Every environment must repeat any
  catch-all entry. A shared `*.workquark.org` rule in `cloudflared` made both clusters' tunnels
  claim every hostname, producing empty-body 404s while both clusters looked healthy.

### ArgoCD is not `helm upgrade`

- **Chart `pre-upgrade` hooks map to `PreSync` on every sync, including first install.** They
  crash before the CRDs they need exist, and nothing behind them syncs — disable them.
- **ArgoCD does not execute Helm's `lookup()`.** Any chart feature that discovers live objects at
  render time silently returns empty. Prefer explicit values.
- ArgoCD **adopts** pre-existing resources that Helm refuses to (`invalid ownership metadata`),
  which is why `helmcharts/argocd/values-bootstrap.yaml` exists for first install only.

### dev lacks Prometheus Operator CRDs

dev's metrics path is VictoriaMetrics VMAgent/VMPodScrape. Any chart shipping a
`ServiceMonitor`/`PodMonitor` must disable it in `values/dev.yaml`, or the sync fails with
`could not find monitoring.coreos.com/ServiceMonitor CRD` — see `cert-manager` and `nats`.

### PodSecurity and resources

- `restricted` requires **both** pod- *and* container-level `securityContext`. Pod-level alone is
  not enough — `tempo` and `victoria-metrics`' vmauth both hit this.
- Limits are conventionally **2× requests**. Sizing is measured against real usage in
  VictoriaMetrics, not guessed. `clickstack` is a deliberate exception and is documented as such
  (a trim caused HyperDX CrashLoop).

## Gateway API — nothing provisions the Gateway

Every `HTTPRoute`/`TCPRoute` here attaches to a `Gateway` named **`gateway`** in namespace
**`gateway-system`**, with `sectionName`s `http`, `https`, `postgres`, `nats`, `vminsert`,
`tempo-otlp`. **No chart in this repo creates that Gateway** — the `istio-gateway` chart that used
to was removed. Until one is added, every route dangles. Do not "fix" a route by changing its
`parentRef`; add the Gateway.

Likewise `helmcharts/cert-manager` renders **no `Issuer`/`ClusterIssuer`** — its `templates/`
directory is empty. `--enable-gateway-api=true` is left on so a Gateway HTTP-01 solver works as
soon as one exists.

## Chart READMEs are inherited and partly stale

The per-chart READMEs came over verbatim from the Proxmox repo and were only spot-corrected.
~40 still narrate ambient mesh, waypoints, Step CA, `*.home.arpa` LAN hostnames or Longhorn.
Treat their rationale as history. Before acting on a chart README, verify the file, value or
label it names still exists.

## Related docs repo

Planning docs, runbooks, and ADRs for this infra live in the sibling repo
`defyjoy/alarmify-docs` (local path: `../alarmify/alarmify-docs/docs/`), not in this repo.
