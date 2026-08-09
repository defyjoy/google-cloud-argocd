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
  **`gateway`/`gateway-system`** across all 15 HTTPRoute charts. The 4 TCPRoute charts were
  later converted (see "TCPRoutes are gone" below), and `cloudflared` was removed entirely.
- **`repoURL`** re-pointed to `git@github.com:defyjoy/google-cloud-argocd.git` (89 occurrences).
- **CoreDNS ConfigMap** (`helmcharts/argocd/templates/kube-system/core-dns-cofigmap.yaml`)
  rewritten: the hardcoded `*.home.arpa` → `192.168.x.x` LAN records are now driven by
  `corednsKubeSystem.hosts`, and it is **disabled by default** (GKE runs kube-dns, not CoreDNS).

---

## Known gaps

These are real and unresolved. Nothing here is a TODO comment hiding in a file — it is listed
because it will bite.

### 1. No HTTPS anywhere — the `https` listener does not exist

`helmcharts/gke-gateway` provisions both Gateways in `gateway-system`: `gateway`
(`gke-l7-rilb`, internal, the default parent) and `gateway-external`
(`gke-l7-regional-external-managed`, public, carrying `zitadel`, `harbor`, `plane`, `vault`).

Both define **only an `http` listener.** `https.enabled` is `false` with empty
`certificateRefs`, blocked on gap 2. So four charts still carry a `sectionName: https`
`parentRef` that can never be Accepted: `kube-prometheus-stack`, `clickstack`, `airflow`,
`argo-workflows`. Of those only `kube-prometheus-stack` is enabled on any cluster today.

Everything reaching `gateway-external` is therefore **plaintext at the load balancer** and
relies on Cloudflare's proxy (`--cloudflare-proxied` in external-dns) for edge TLS.

Fix the listener, not the routes: add a ClusterIssuer (gap 2), then set
`gateways.<entry>.https.enabled: true` with a `certificateRefs` entry.

### 2. cert-manager issues no certificates

There is no `Issuer` or `ClusterIssuer`. `--enable-gateway-api=true` is still set so a
Gateway HTTP-01 solver works against either Gateway; on GCP a Let's Encrypt DNS-01 solver against
Cloud DNS is the more likely fit. This is what blocks gap 1.

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
mismatch, in order: the six `alarmify/*` READMEs, `zitadel`, `argocd`, `harbor`, `cilium`,
`tempo`. Treat their *rationale* as history, not as a description of this repo.

`zitadel` still serves `zitadel.home.arpa` from a dedicated LAN route
(`templates/httproute-zitadel-lan.yaml`) on the internal Gateway. That hostname does not resolve
on GCP — the route is kept because the Terraform provider path depends on it, but it is inert
until the name resolves.

### 5. Still bare-metal-shaped

`cilium` (GKE has Dataplane V2) and `tailscale` were kept at your request but are Proxmox-era
choices. `helmcharts/cilium/values/local.yaml` still carries the Proxmox network identity.

---

## TCPRoutes are gone

GKE ships the Gateway API **standard channel**, which has no `TCPRoute` kind, and both
GatewayClasses in use are L7 HTTP(S) load balancers. The four charts that templated a `TCPRoute`
could not sync at all. They were converted along the only two lines that work:

| Chart | Was | Now |
|---|---|---|
| `victoria-metrics` | TCPRoute `vminsert` | HTTPRoute → `vmauth`, internal Gateway |
| `tempo` | TCPRoute `tempo-otlp` → 4317 | HTTPRoute → **4318**, internal Gateway |
| `cloudnative-pg` | TCPRoute `postgres` | internal L4 `LoadBalancer` via CNPG `managed.services` |
| `nats` | TCPRoute `nats` | internal L4 `LoadBalancer` Service |

Two consequences worth knowing:

- **Tempo moved from OTLP/gRPC to OTLP/HTTP.** gRPC over an HTTPRoute needs
  `appProtocol: kubernetes.io/h2c` on the backend Service, which the upstream chart does not
  expose. **Senders must use an OTLP HTTP exporter**, not the gRPC one.
- **PostgreSQL and NATS were not converted to HTTPRoutes, deliberately.** Neither wire protocol
  is HTTP; a route would be Accepted and then blackhole every connection. Both are gated behind
  `externalExposure.enabled` and each costs one internal LB IP. In-cluster clients are unaffected
  — they resolve the ClusterIP Services directly and never traversed the Gateway.

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
