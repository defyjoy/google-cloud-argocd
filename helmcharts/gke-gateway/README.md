# gke-gateway

Creates **`gateway-system/gateway`** — the single `Gateway` that every `HTTPRoute` in this repo
names as its `parentRef` — backed by a **GKE-managed Application Load Balancer**.

This chart replaces the removed `istio/istio-gateway`. Until it exists, every route in the repo
dangles and no north-south traffic flows (README.md → Known gaps #1).

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

`gke-l7-rilb` is a *regional internal* Application Load Balancer. It needs a proxy-only subnet in
the same region, which `yeti-hub-vpc` does not have:

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
The rest of the repo still says `workquark.org` in ~110 files; that domain has **no zone in this
project** and does not resolve here — treat those references as Proxmox-era, the same as the
`*.home.arpa` names.

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

### `gatewayClassName` has no base default, on purpose

```yaml
gateway:
  gatewayClassName: ""
```

`values.yaml` leaves it empty and `templates/gateway.yaml` calls `fail` when it is still empty at
render time. A cluster that forgot its overlay stops loudly instead of quietly provisioning the
wrong class of load balancer — the same reasoning as `victoria-metrics`' empty `externalLabels`.

### `gke-l7-rilb` — internal, not public

```yaml
# values/local.yaml
gateway:
  gatewayClassName: gke-l7-rilb
```

A **regional internal** Application Load Balancer. Chosen over the external classes because:

- **Argo CD runs with `server.insecure: true`** (`helmcharts/argocd/values.yaml`,
  `argo-cd.configs.params`). It serves the admin UI over plain HTTP. On a public IP with no TLS
  listener that puts admin credentials on the wire in the clear. An internal LB confines it to
  the VPC, reachable over the existing VPN (`yeti-hub-vpn-ip`, `yeti-hub-vpn-allow-clients`).
- **It preserves the Cloudflare-edge design already encoded in every route in this repo.**
  `helmcharts/vault/templates/httproute.yaml` says it outright: *"TLS is terminated at the
  Cloudflare edge, not here"*, and every route attaches only to the `http` listener.
  `cloudflared` is the public entry point; the Gateway is the internal fan-out behind it.

The alternative is `gke-l7-global-external-managed` — a public IP, and the only class here that
needs **no** proxy-only subnet. Do not switch to it until the `https` listener has a real
certificate (see below); otherwise it publishes a plaintext Argo CD admin UI.

`gke-l7-rilb` **requires a proxy-only subnet** in the region, and this project has none:

```bash
gcloud compute networks subnets create yeti-hub-proxy-only-us-central1 \
  --purpose=REGIONAL_MANAGED_PROXY --role=ACTIVE \
  --region=us-central1 --network=yeti-hub-vpc --range=10.42.0.0/23
```

### `allowedRoutesFrom: All`

```yaml
gateway:
  allowedRoutesFrom: All
```

Routes live in their own namespaces (`argocd`, `vault`, `harbor`, …) and attach across the
namespace boundary to this Gateway. That is governed by the **Gateway's**
`listeners[].allowedRoutes.namespaces.from`, not by a `ReferenceGrant` — ReferenceGrant only
covers cross-namespace `backendRefs` and `certificateRefs`, neither of which this repo uses. So
no ReferenceGrant is shipped here; adding one would do nothing.

### `addressName` — static IP, and why cloudflared needs it

```yaml
gateway:
  addressName: ""
```

Empty means GKE assigns an ephemeral address. Reserve one and name it here when you want a
stable target:

```bash
gcloud compute addresses create argocd-gateway-ip \
  --region=us-central1 --subnet=yeti-hub-us-central1 \
  --purpose=GCE_ENDPOINT --project=yeti-504903
```

This matters more than it looks. `helmcharts/cloudflared/values/local.yaml` currently points its
tunnel at an **in-cluster Service DNS name**:

```yaml
service: http://gateway.gateway-system.svc.cluster.local:80
```

A GKE-managed Gateway is a Google Cloud load balancer, **not** an in-cluster proxy Deployment — it
creates no `gateway` Service, so that hostname does not resolve. The removed Istio gateway did
create one, which is where the value came from. Retarget cloudflared at the reserved internal IP
once this chart is deployed. (This is already broken today, since no Gateway exists at all; this
chart does not make it worse, but it does not fix it either.)

### `https` is off until a certificate exists

```yaml
gateway:
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
gateway:
  https:
    enabled: true
    certificateRefs:
      - group: ""
        kind: Secret
        name: workquark-tls
```

`helmcharts/argocd`'s HTTPRoute attaches only to `sectionName: http` for the same reason.

### `healthCheckPolicy` is off by default

```yaml
healthCheckPolicy:
  enabled: false
```

GKE derives the backend health check from the Pod's readiness probe, which is correct for
`argocd-server` (`/healthz` on 8080). Turn this on only for a backend whose readiness probe and
LB-facing health endpoint genuinely differ.

## What this Gateway does not serve

**No GKE GatewayClass implements `TCPRoute`.** GKE ships the Gateway API **standard** channel,
which has no `TCPRoute` type at all. Four charts template one, against `sectionName`s this
Gateway therefore cannot offer (`postgres`, `nats`, `vminsert`, `tempo-otlp`):

| Chart | Route | sectionName |
|---|---|---|
| `helmcharts/cloudnative-pg` | `postgresql-tcproute.yaml` | `postgres` |
| `helmcharts/nats` | `nats-tcproute.yaml` | `nats` |
| `helmcharts/victoria-metrics` | `vminsert-tcproute.yaml` | `vminsert` |
| `helmcharts/tempo` | `tempo-otlp-tcproute.yaml` | `tempo-otlp` |

Those four Applications will fail to sync with `could not find
gateway.networking.k8s.io/TCPRoute` until each chart gates its TCPRoute off per-cluster. **They
are deliberately left in place** rather than deleted — the L4 exposure they describe is a real
requirement that needs a real replacement, not a quiet removal. The options, none of them free:

- an **internal passthrough Network Load Balancer** per service (a plain `Service`
  `type: LoadBalancer` with `networking.gke.io/load-balancer-type: Internal`), which is what
  these four actually need and what an L7 Gateway was never going to give them;
- Cloudflare Tunnel / Tailscale for the ones that only need operator access;
- an in-cluster Gateway implementation that does support `TCPRoute` — but that means giving up
  the GKE-managed Gateway for the L7 traffic too.

## Sync wave −27

```yaml
argocd.argoproj.io/sync-wave: "-27"
```

Behind `argocd` (−30) and `argocd-apps` (−29), ahead of every chart that templates a route, so the
Gateway exists before anything tries to attach to it.
