# gke-gateway

Creates the cluster's `Gateway` resources in **`gateway-system`**, each backed by a
**GKE-managed Application Load Balancer**.

This chart replaces the removed `istio/istio-gateway`. Until it exists, every route in the repo
dangles and no north-south traffic flows (README.md → Known gaps #1).

| values key | Gateway name | GatewayClass | Reach |
|---|---|---|---|
| `gateways.internal` | **`gateway`** | `gke-l7-rilb` | VPC-internal, via the `yeti-hub-vpn` OpenVPN server |
| `gateways.external` | **`gateway-external`** | `gke-l7-regional-external-managed` | Public internet |

**`internal` deliberately holds the bare name `gateway`.** Nearly every `HTTPRoute` in this repo
hard-codes `parentRefs[].name: gateway`, so keeping that name on the internal Gateway means most
routes never had to change, and the default posture for anything in this repo is *not*
internet-facing. A route opts in to the public path explicitly:

```yaml
parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: gateway-external
    namespace: gateway-system
    sectionName: http
```

**Nothing attaches to `gateway-external` today.** It provisions a public load balancer with no
routes behind it, which serves 404 to the internet and exposes nothing. Read
[`https` is off until a certificate exists](#https-is-off-until-a-certificate-exists) before you
attach the first route — until a certificate is wired, that path is **plaintext HTTP**.

- Upstream: no subchart. Plain manifests against `gateway.networking.k8s.io/v1`, implemented by
  GKE's built-in Gateway controller.
- Targets **management** (`local`) and **dev** — both are GKE clusters.
- Label-gated on `gke-gateway: "true"` in the cluster Secret.

## Prerequisite: GKE Gateway API must be enabled by hand

This chart installs **no CRDs**. On GKE the Gateway API CRDs are GKE-owned and arrive with a
control-plane update:

```bash
gcloud container clusters update yeti-hub-gke \
  --location us-central1-a --project yeti-504903 \
  --gateway-api=standard
```

`task check-gateway-api` (part of `task bootstrap`) verifies this and fails with the command
above when it is missing. It is deliberately a check and not an install: enabling Gateway API
mutates the control plane.

### Why `helmcharts/gateway-api-crds` must stay off on GKE

That chart applies the **upstream** `v1.5.1` *experimental* manifest. GKE refuses to install its
own CRDs over pre-existing ones, so applying upstream CRDs leaves the managed Gateway controller
holding CRDs it does not recognise — no Gateway is ever programmed, and nothing in the failure
points at the cause. The two are mutually exclusive. The `gateway-api-crds` label is commented
out in `helmcharts/argocd/templates/cluster/local-cluster-secret.yaml` for exactly this reason;
the chart itself is kept for any non-GKE cluster registered later.

## Prerequisite: proxy-only subnet, and the firewall rule people forget

Both Gateways are **regional Envoy-based** load balancers — `gke-l7-rilb` and
`gke-l7-regional-external-managed` — so both draw from a proxy-only subnet in `us-central1`.
`REGIONAL_MANAGED_PROXY` is *"Reserved for Regional Envoy-based Load Balancing"*, not
internal-specific, and GCP allows only one `ACTIVE` per region per network, so **one subnet
serves both**. `yeti-hub-vpc` has none:

```bash
gcloud compute networks subnets create yeti-hub-proxy-only-us-central1 \
  --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE \
  --region=us-central1 --network=yeti-hub-vpc --range=10.42.0.0/23
```

`10.42.0.0/23` was chosen because it overlaps nothing already allocated: nodes `10.40.0.0/20`,
mgmt `10.41.0.0/28`, pods `10.50.0.0/16`, control plane `172.16.1.0/28`.

**Then the part that silently breaks everything.** The Envoy proxies send data-plane traffic to
the backends *from the proxy-only subnet*, not from Google's health-check ranges. `yeti-hub-vpc`
allows `10.50.0.0/16`, `10.41.0.0/28`, `10.40.0.0/20`, `10.60.0.0/20` and `10.11.0.0/28` inbound
(`yeti-hub-allow-internal`), and the health-check ranges separately
(`yeti-hub-allow-health-checks`) — but **not** `10.42.0.0/23`:

```bash
gcloud compute firewall-rules create yeti-hub-allow-proxy-only \
  --network=yeti-hub-vpc --direction=INGRESS --action=ALLOW \
  --source-ranges=10.42.0.0/23 --rules=tcp
```

Without it the Gateway provisions, health checks pass, and every request is dropped — a failure
mode that looks like a broken backend rather than a missing firewall rule.

## Prerequisite: a DNS record, because the route is host-matched

`helmcharts/argocd/values.yaml` pins `hostnames: [argocd.jrclabs.xyz]`. An HTTPRoute with
`hostnames` set does **not** match a request to the load balancer's raw IP — browsing to the VIP
returns 404, not the Argo CD UI. DNS is load-bearing here, not cosmetic.

`jrclabs.xyz` is the only zone that exists in this project, and its private view is already
attached to `yeti-hub-vpc` and `yeti-dev-vpc`, so VPN clients resolve it with no extra wiring.

The repo previously used `workquark.org` throughout — a Proxmox-era domain with no zone in this
project, which therefore resolved nowhere. All 286 references across 113 files were migrated to
`jrclabs.xyz` on 2026-08-09. Two deliberate exceptions remain and are **not** domains: the
Zitadel machine-user clientId `workquark-alertmanager` (renaming it breaks OIDC against a live
identity provider) and the `github.com/workquark/ArgoCD` `runbook_url`s in
`helmcharts/kube-prometheus-stack` (a GitHub org, and those links point at the pre-fork repo).

Once the Gateway reports an address:

```bash
kubectl -n gateway-system get gateway gateway -o jsonpath='{.status.addresses[0].value}'

gcloud dns record-sets create argocd.jrclabs.xyz. \
  --zone=jrclabs-xyz-private --type=A --ttl=300 --rrdatas=<VIP>
```

Reachability is over the `yeti-hub-vpn` OpenVPN server (`10.41.0.2`, udp/1194). It sits in
`10.41.0.0/28`, which `yeti-hub-allow-internal` already permits, so the VPN→Gateway leg needs no
further firewall work.

## Configuration

### `gateways` is a map, not a list

```yaml
gateways:
  internal:
    name: gateway
    gatewayClassName: ""
  external:
    name: gateway-external
    gatewayClassName: ""
```

Helm **replaces lists wholesale but deep-merges maps** (CLAUDE.md → *"Helm replaces lists
wholesale"*). Because `gateways` is a map, `values/<cluster>.yaml` sets nothing but the class
name per entry and inherits every listener from the base:

```yaml
# values/local.yaml
gateways:
  internal:
    gatewayClassName: gke-l7-rilb
  external:
    gatewayClassName: gke-l7-regional-external-managed
```

Had this been a list, each cluster would have to restate both Gateways in full, and a
half-updated overlay would silently drop one.

Add a third Gateway by adding a key. Drop one for a given cluster with `enabled: false` rather
than deleting the key, so the base keeps documenting what exists.

### `gatewayClassName` has no base default, on purpose

`values.yaml` leaves every `gatewayClassName` empty and `templates/gateway.yaml` calls `fail`
when one is still empty at render time — naming the offending key:

```
gateways.external.gatewayClassName is required — set it in
helmcharts/gke-gateway/values/<cluster>.yaml (see README.md)
```

A cluster that forgot its overlay stops loudly instead of quietly provisioning the wrong class of
load balancer — the same reasoning as `victoria-metrics`' empty `externalLabels`. The stakes are
higher on the `external` entry than the internal one: a wrong default there is a public IP in
front of something that was meant to be private.

Consequence: `helm template helmcharts/gke-gateway` on its own **errors**. That is intended —
pass the overlay, exactly as `cilium` requires.

### Why `internal` is `gke-l7-rilb`

A **regional internal** Application Load Balancer, and the default parent for everything in this
repo, because:

- **Argo CD runs with `server.insecure: true`** (`helmcharts/argocd/values.yaml`,
  `argo-cd.configs.params`). It serves the admin UI over plain HTTP. On a public IP with no TLS
  listener that puts admin credentials on the wire in the clear. An internal LB confines it to
  the VPC, reachable over the existing VPN (`yeti-hub-vpn-ip`, `yeti-hub-vpn-allow-clients`).
- **Every route in this repo attaches only to an `http` listener.** There is no `https` listener
  on either Gateway yet (see "`https` is off until a certificate exists"), so anything published
  is plaintext at the load balancer and depends on Cloudflare's proxy for edge TLS. Keeping the
  default internal means that exposure is opt-in per route rather than the fallback.

### Why `external` is `gke-l7-regional-external-managed`

Regional rather than global (`gke-l7-global-external-managed`) so both Gateways are Envoy-based
regional load balancers in `us-central1` and **share one proxy-only subnet** — see below. The
global class needs no proxy-only subnet at all, so it is the cheaper choice if you ever want
exactly one public Gateway and no internal one; with both, regional keeps the footprint to a
single shared subnet and a single firewall rule.

### Both Gateways share one proxy-only subnet

`REGIONAL_MANAGED_PROXY` is documented as *"Reserved for Regional Envoy-based Load Balancing"* —
it is **not** internal-specific, and GCP permits only one `ACTIVE` such subnet per region per
network. So `gke-l7-rilb` and `gke-l7-regional-external-managed` both draw from the same one, and
this project has none:

```bash
gcloud compute networks subnets create yeti-hub-proxy-only-us-central1 \
  --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE \
  --region=us-central1 --network=yeti-hub-vpc --range=10.42.0.0/23
```

One subnet means **one** firewall rule covers both Gateways' data plane — the
`yeti-hub-allow-proxy-only` rule above is not per-Gateway.

### `allowedRoutesFrom: All`

```yaml
gateways:
  internal:
    allowedRoutesFrom: All
  external:
    allowedRoutesFrom: All
```

Set per Gateway. Routes live in their own namespaces (`argocd`, `vault`, `harbor`, …) and attach
across the namespace boundary. That is governed by the **Gateway's**
`listeners[].allowedRoutes.namespaces.from`, not by a `ReferenceGrant` — ReferenceGrant only
covers cross-namespace `backendRefs` and `certificateRefs`, neither of which this repo uses. So
no ReferenceGrant is shipped here; adding one would do nothing.

### `addressName` — static IP for a stable DNS target

```yaml
gateways:
  internal:
    addressName: ""
  external:
    addressName: ""
```

Per Gateway, and they need **different** addresses — an internal one from the VPC for
`gateway`, an external one for `gateway-external`. Empty means GKE assigns an ephemeral address.
Reserve and name one when you want a stable target:

```bash
gcloud compute addresses create argocd-gateway-ip \
  --region=us-central1 --subnet=yeti-hub-us-central1 \
  --purpose=GCE_ENDPOINT --project=yeti-504903
```

Public DNS does not depend on this being set: `helmcharts/external-dns` (source
`gateway-httproute`) reads each Gateway's address directly and publishes it for every hostname
routed there — `zitadel`, `harbor`, `plane`, `vault` on `gateway-external`. Pinning `addressName`
only matters if you need that address to survive a Gateway being deleted and recreated; the
Cloudflare Tunnel that used to need a fixed target for its own config was removed 2026-08-09.

### `https` is off until a certificate exists

```yaml
gateways:
  internal:
    https:
      enabled: false
      certificateRefs: []
  external:
    https:
      enabled: false
      certificateRefs: []
```

There is no certificate infrastructure in this repo: `helmcharts/cert-manager` renders **no**
`Issuer`/`ClusterIssuer` (its `templates/` directory is empty — README.md → Known gaps #2). An
HTTPS listener with no `certificateRefs` is rejected, so the listener stays off rather than
shipping a Gateway that never programs. Enable it by supplying either a cert-manager-issued
Secret or a Certificate Manager map:

```yaml
gateways:
  external:
    https:
      enabled: true
      certificateRefs:
        - group: ""
          kind: Secret
          name: jrclabs-tls
```

`helmcharts/argocd`'s HTTPRoute attaches only to `sectionName: http` for the same reason.

**This is the gate on using `gateway-external` for anything real.** Attaching a route to it while
`https.enabled: false` publishes that service to the internet over plaintext HTTP. The internal
Gateway tolerates HTTP because the VPC and the VPN are the boundary; the external one has no such
boundary.

### `healthCheckPolicies` is an empty list

```yaml
healthCheckPolicies: []
```

GKE derives the backend health check from the Pod's readiness probe, which is correct for
`argocd-server` (`/healthz` on 8080). Add an entry only for a backend whose readiness probe and
LB-facing health endpoint genuinely differ:

```yaml
healthCheckPolicies:
  - name: argocd-server
    targetService: argocd-server
    namespace: argocd
    port: 8080
    requestPath: /healthz
```

A `HealthCheckPolicy` targets a **Service**, not a Gateway, so these are deliberately not nested
under `gateways` — a backend reached through both Gateways needs one policy, not two. `namespace`
defaults to `gateway-system`, but a policy must live in the *target Service's* namespace, so set
it explicitly.

## What neither Gateway serves

**No GKE GatewayClass implements `TCPRoute`** — not `gke-l7-rilb`, not
`gke-l7-regional-external-managed`, not any other. GKE ships the Gateway API **standard** channel,
which has no `TCPRoute` type at all. Neither Gateway offers a `postgres`, `nats`, `vminsert` or
`tempo-otlp` listener, and neither ever will.

Four charts used to template a `TCPRoute` against exactly those `sectionName`s, and each failed to
sync with `could not find gateway.networking.k8s.io/TCPRoute`. All four were resolved on
2026-08-09, along the only two lines available:

| Chart | Was | Now | Why that split |
|---|---|---|---|
| `helmcharts/victoria-metrics` | TCPRoute `vminsert` | `HTTPRoute` → vmauth, internal | remote-write is an HTTP POST |
| `helmcharts/tempo` | TCPRoute `tempo-otlp` → 4317 | `HTTPRoute` → **4318**, internal | OTLP/HTTP; gRPC would need h2c |
| `helmcharts/cloudnative-pg` | TCPRoute `postgres` | internal L4 `LoadBalancer` | PostgreSQL wire protocol is not HTTP |
| `helmcharts/nats` | TCPRoute `nats` | internal L4 `LoadBalancer` | NATS line protocol is not HTTP |

The rule that split them is worth keeping: **if the protocol is already HTTP, it becomes an
`HTTPRoute`; if it is not, it gets an internal passthrough load balancer.** An `HTTPRoute` in
front of Postgres or NATS is Accepted by the API server and then blackholes every connection —
the worst of both worlds, because it looks configured.

Both L4 services are gated behind `externalExposure.enabled` in their own charts and each costs
one internal LB IP. Tempo's move from 4317 to 4318 means **senders must use an OTLP HTTP
exporter**; see `helmcharts/tempo/README.md`.

## Sync wave −27

```yaml
argocd.argoproj.io/sync-wave: "-27"
```

Behind `argocd` (−30) and `argocd-apps` (−29), ahead of every chart that templates a route, so the
Gateways exist before anything tries to attach to them.
