# google-cloud-argocd

GitOps repository for the **Google Cloud** clusters — an Argo CD app-of-apps managing 46 Helm
charts across two clusters (`management` and `dev`).

> **This repo is a fork of [`defyjoy/ArgoCD`](https://github.com/defyjoy/ArgoCD)**, which targets
> Proxmox/Talos bare metal. It was created on 2026-08-09 by copying that repo at commit `5dec2ae`
> and removing everything tied to the self-hosted certificate and service-mesh stack. Read
> [What was removed](#what-was-removed) and [Known gaps](#known-gaps) before deploying anything —
> some of this does not work yet, by construction.

---

## Layout

```
helmcharts/
├── argocd/                  # Argo CD itself (self-managed) + cluster Secrets
├── argocd-apps/             # The app-of-apps root: 117 ApplicationSets / Applications
│   └── templates/
│       ├── applications/    # Single-cluster Applications
│       └── applicationsets/ # Cluster-generator ApplicationSets
├── <chart>/
│   ├── Chart.yaml
│   ├── values.yaml          # shared defaults — pure data, no comments
│   ├── values/<env>.yaml    # per-cluster overrides only
│   ├── templates/
│   └── README.md            # all rationale lives here
manifests/                   # Raw kustomize/manifest bundles (not Helm)
scripts/                     # Bootstrap + Vault + lint shell logic
taskfiles/                   # Task definitions, included by ./Taskfile.yml
docs/runbooks/
```

## Quick start

```bash
task --list          # every available task
task bootstrap       # full Argo CD install → self-management → app-of-apps (management cluster)
task lint            # fail if any values file contains a comment
task hooks:install   # one-time: install the pre-commit hook that runs the lint
```

## Clusters

There are two, and there is no prod:

| Name | Argo CD cluster name | Role |
|---|---|---|
| management | `local` | Runs Argo CD, Vault, Zitadel, the monitoring stack |
| dev | `dev` | Registered as a remote target; see `docs/runbooks/register-dev-cluster.md` |

Both are gated the same way: every `ApplicationSet` uses a `cluster-generator` with a `matchLabels`
selector against the cluster `Secret` in namespace `argocd`. Those labels are GitOps-managed from
`helmcharts/argocd/templates/cluster/local-cluster-secret.yaml` and
`.../dev-cluster-secret.yaml` — **add the label there and commit; never `kubectl label` the live
Secret**, because the self-managed `argocd` Application runs with `selfHeal: true` and will revert it.

---

## What was removed

Relative to the upstream Proxmox repo, these charts and their ApplicationSets are **gone**:

| Removed | Why |
|---|---|
| `istio/` (9 subcharts: base, istiod, istio-cni, ztunnel, istio-gateway, istio-eastwest, istio-eastwest-classic, istio-remote-secrets, istio-cacerts) | Ambient service mesh — dropped for now |
| `stepca` | Self-hosted Step CA (private PKI) |
| `kiali` | Istio observability console; meaningless without Istio |
| `pg-egress-bridge` | Istio `DestinationRule`/`AuthorizationPolicy` egress shim |
| `postgresql-global-service` | Istio multicluster `istio.io/global` Service stub |
| `longhorn` | Bare-metal CSI; GKE provides `standard-rwo` (pd-balanced) |

Alongside them, in the charts that were kept:

- **Ambient-mesh enrollment labels** (`istio.io/dataplane-mode`, `istio.io/use-waypoint`,
  `istio.io/global`, `istio.io/waypoint-for`) stripped from every namespace, Service and
  `managedNamespaceMetadata` block.
- **Waypoint `Gateway` + `waypoint-options` `ConfigMap`** deleted from all six `alarmify-*` charts.
- **`DestinationRule`** deleted from `alarmify-ui` (see that chart's README — the bug it worked
  around is still unfixed).
- **cert-manager's Step CA ACME `ClusterIssuer`**, its CA-bundle patch Job and `ExternalSecret`
  deleted. `helmcharts/cert-manager/templates/` is now empty — the chart installs upstream
  cert-manager and **issues nothing**.
- **`storageClass: longhorn` → `standard-rwo`** in airflow, clickstack, n8n, plane, rancher, tempo,
  vault, vcluster, victoria-metrics and the cloudnative-pg cluster manifest.
- **Gateway `parentRef`s** re-pointed from `istio-gateway`/`istio-system` to
  **`gateway`/`gateway-system`** across all 15 HTTPRoute and 4 TCPRoute charts, plus the
  `cloudflared` tunnel backends.
- **`repoURL`** re-pointed to `git@github.com:defyjoy/google-cloud-argocd.git` (89 occurrences).
- **CoreDNS ConfigMap** (`helmcharts/argocd/templates/kube-system/core-dns-cofigmap.yaml`)
  rewritten: the hardcoded `*.home.arpa` → `192.168.x.x` LAN records are now driven by
  `corednsKubeSystem.hosts`, and it is **disabled by default** (GKE runs kube-dns, not CoreDNS).

---

## Known gaps

These are real and unresolved. Nothing here is a TODO comment hiding in a file — it is listed
because it will bite.

### 1. No chart provisions the `gateway` Gateway

Every `HTTPRoute`/`TCPRoute` in this repo attaches to a `Gateway` named **`gateway`** in namespace
**`gateway-system`**. The chart that used to create it (`istio/istio-gateway`) is gone, and nothing
replaced it. **Until you add one, every route in this repo dangles and no north-south traffic
flows.** The two obvious options:

- a GKE-managed Gateway (`gatewayClassName: gke-l7-regional-external-managed`), or
- re-adding a self-managed ingress chart.

The `sectionName`s the existing routes expect are: `http`, `https`, `postgres`, `nats`,
`vminsert`, `tempo-otlp`.

### 2. cert-manager issues no certificates

There is no `Issuer` or `ClusterIssuer`. `--enable-gateway-api=true` is still set so a
Gateway HTTP-01 solver works the moment one is added; on GCP a Let's Encrypt DNS-01 solver against
Cloud DNS is the more likely fit.

### 3. Cross-cluster service calls have no transport

Two dependencies crossed the management↔dev boundary over the Istio ambient multicluster mesh and
now have nothing carrying them:

- **Alertmanager → `alarmify-ingest-api`** (`helmcharts/kube-prometheus-stack/templates/alertmanager-config.yaml`)
  — the webhook URL still points at `dev-alarmify-ingest-api.alarmify-ingest-api.svc`, which no
  longer resolves. **Alarmify receives no alerts.**
- **Zitadel → `alarmify-identity-api`** (Complement Token action target) — the global-Service stub
  that made this resolve was deleted.

### 4. Chart READMEs still describe the Proxmox/Istio design

The per-chart READMEs were inherited verbatim and only spot-corrected. Roughly 40 of them still
narrate ambient mesh, waypoints, Step CA, `*.home.arpa` LAN hostnames or Longhorn. Highest
mismatch, in order: the six `alarmify/*` READMEs, `zitadel`, `argocd`, `cloudflared`, `harbor`,
`cilium`, `tempo`. Treat their *rationale* as history, not as a description of this repo.

### 5. Still bare-metal-shaped

`cilium` (GKE has Dataplane V2), `cloudflared` and `tailscale` were kept at your request but are
Proxmox-era choices. `helmcharts/cilium/values/local.yaml` and the `cloudflared` tunnel IDs still
carry the Proxmox network identity.

---

## Conventions

Full detail in [`CLAUDE.md`](./CLAUDE.md). The short version:

- **`values.yaml` and `values/<env>.yaml` carry no comments.** Rationale goes in the chart README as
  prose *with the YAML snippet it explains quoted alongside*. `task lint:values` enforces it.
- **Every chart needs a README.** The exceptions are the umbrella dirs `alarmify/`, `staypingo/` and
  `argocd-apps/`.
- **Secrets never live in values files** — Vault + External Secrets. (`harbor` and `plane` still
  carry committed placeholder credentials; do not copy that.)
- **Never shadow a Vault-delivered value with a literal `env`** — Kubernetes ranks `env` above
  `envFrom`, so it silently wins.
- **Per-cluster config goes in `values/<env>.yaml`**, and remember Helm *replaces* lists rather than
  merging them.
- **dev has no Prometheus Operator CRDs** — any chart shipping a `ServiceMonitor`/`PodMonitor` must
  disable it in `values/dev.yaml`.

## Related

- [`defyjoy/ArgoCD`](https://github.com/defyjoy/ArgoCD) — the Proxmox/Talos original
- `defyjoy/alarmify-docs` — planning docs, runbooks and ADRs (written against the Proxmox stack)
