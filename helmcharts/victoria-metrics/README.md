# victoria-metrics

The cluster's metrics backend — VMCluster (storage/insert/select), VMAgent (scrape), and
VMAlert. **Sole scrape and alerting path since the Prometheus cutover on 2026-07-09**;
`kube-prometheus-stack`'s own Prometheus is disabled and Grafana reads from vmselect.

- Requires [`victoria-metrics-operator`](../victoria-metrics-operator/README.md) (CRDs +
  controller) to already be installed
- ArgoCD: `helmcharts/argocd-apps/templates/applicationsets/victoria-metrics-as.yaml`

Design: `docs/istio/istio-ambient-multicluster-management-dev-plan.md` §12, §23 (Phase 6,
central observability).

## Topology

| Cluster | VMCluster | VMAgent | VMAlert | Role |
|---|---|---|---|---|
| management (`local`) | ✅ | ✅ | ✅ | central store; receives dev's remote-write |
| dev | ❌ | ✅ | ❌ | scrape-and-forward only |

dev has **no local storage/insert/select tier and no VMAlert** — there is no Alertmanager
wiring on dev either. It runs a VMAgent that remote-writes into management's VMCluster.

---

## Configuration

```yaml
retentionPeriod: "30d"

vmcluster:
  enabled: true
  replicationFactor: 2
  vmstorage:
    replicaCount: 2
    storageClassName: standard-rwo
    storage: 20Gi
  vmselect:
    replicaCount: 2
    cacheStorage: 2Gi
    storageClassName: standard-rwo
```

> 📉 **All CPU limits in this chart were halved on 2026-07-11**, measured against 24h peak
> usage per VictoriaMetrics itself: vmstorage 71.0m, vminsert 29.5m, vmselect 60.9m,
> vmagent 70.0m, vmalert 7.4m — each well under half the previous limit.

### `externalLabels` has no default, deliberately

```yaml
vmagent:
  externalLabels: {}       # set per cluster in the overlays
```

`cluster: management` is set in `values/local.yaml` and `cluster: dev` in `values/dev.yaml`,
so dev's remote-written series don't collide with management's own in the shared VMCluster.
The base file deliberately carries **no default**, so a missing per-cluster override fails
loudly (unlabeled series) rather than being silently wrong.

### Cross-cluster remote-write exposure

```yaml
vmcluster:
  vminsert:
    externalExposure:
      enabled: false
```

Off by default; `values/local.yaml` turns it on and supplies the hostname:

```yaml
vmcluster:
  vminsert:
    externalExposure:
      enabled: true
      hostname: vminsert.jrclabs.xyz
```

vminsert is a bare ClusterIP otherwise, which is fine while only same-cluster VMAgents write
to it.

Renders `templates/vminsert-httproute.yaml`, attached to the `http` listener of the **internal**
`gateway` (`gke-l7-rilb`) in `gateway-system`. Internal on purpose: remote-write carries every
series this cluster holds and is authenticated only by a bearer token.

This was a `TCPRoute` until the GKE migration. Prometheus remote-write is an ordinary HTTP POST
and vmauth is an HTTP proxy, so `HTTPRoute` is the protocol it always should have been — and the
TCPRoute could never have been served anyway: GKE ships the Gateway API standard channel, which
has no `TCPRoute` kind, so the Application failed to sync entirely.

Auth is handled by a **separate vmauth proxy**, not vminsert. Confirmed: vminsert and vmselect
have no built-in auth mechanism — operator v0.73.1's `VMCluster.spec.vminsert` CRD has no auth
field, and the official docs state *"External clients must access vminsert and vmselect via
auth proxy such as vmauth or vmgateway"*. The HTTPRoute template enforces `vmauth.enabled` as a
hard prerequisite, so enabling exposure alone is still safe with vmauth off (it renders
nothing).

Dev's VMAgent writes to `http://vminsert.jrclabs.xyz/insert/0/prometheus/api/v1/write`
(`values/dev.yaml`). That URL previously pointed at `192.168.3.10:8480`, a Proxmox LAN address
with no meaning in this VPC.

### vmauth

```yaml
vmauth:
  enabled: false
  port: "8427"
  tokenSecretName: vminsert-remote-write-token
  tokenSecretKey: token
```

The auth proxy in front of vminsert (`templates/vmauth.yaml`) — only meaningful where the
VMCluster runs, i.e. management. Uses the native operator CRD
(`vmauths.operator.victoriametrics.com`), so there is no new component to install.

### Shared remote-write token

```yaml
remoteWriteToken:
  enabled: false
  secretStore: vault-secretstore
  vaultPath: victoria-metrics/remote-write-token
```

One bearer token (`templates/remote-write-token-external-secret.yaml`) read **identically on
both clusters**: management's `VMUser.tokenRef` validates it, dev's `VMAgent.bearerTokenSecret`
presents it.

> 🔐 **Vault population is manual, human-only.** This matches the precedent set by the Istio
> remote-secrets and the Kiali remote-cluster kubeconfig — any cross-cluster-access credential
> in this repo goes through a human, never an agent.

Bearer-token auth uses `VMAgentRemoteWriteSpec.bearerTokenSecret` (confirmed field, operator
v0.73.1 `api/operator/v1beta1/vmagent_types.go`). `secretName`/`secretKey` must match the
Secret that `remoteWriteToken` delivers, and `remoteWriteToken.enabled` must also be true.

### vmalert notifier

```yaml
vmalert:
  notifier:
    url: "http://kube-prometheus-stack-alertmanager.kube-prometheus-stack.svc:9093"
```

The existing `kube-prometheus-stack` Alertmanager is **reused as-is, not replaced**.

---

## Per-cluster overlays

### management — `values/local.yaml`

```yaml
vmagent:
  externalLabels:
    cluster: management
remoteWriteToken:
  enabled: true
vmauth:
  enabled: true
vmcluster:
  vminsert:
    externalExposure:
      enabled: true
```

Cross-cluster remote-write from dev was **enabled 2026-07-19** (Phase 6, §23).

> ⚠️ **Requires `kv/victoria-metrics/remote-write-token` populated in Vault first** (the
> human step above), or the ExternalSecret fails to resolve and vmauth's VMUser has no token
> to validate against.

The vminsert TCP listener on this gateway
([`istio-gateway`](../istio/istio-gateway/README.md)) is already live and `Programmed=True` as
a no-op port claim — this overlay is what actually activates routing to it.

### dev — `values/dev.yaml`

```yaml
vmcluster:
  enabled: false
vmalert:
  enabled: false
remoteWriteToken:
  enabled: true
vmagent:
  externalLabels:
    cluster: dev
  remoteWrite:
    url: "http://192.168.3.10:8480/insert/0/prometheus/api/v1/write"
    auth:
      enabled: true
```

Targets management's vminsert via the north-south gateway's `vminsert` TCP listener (`:8480`)
over **plain LAN, not through the mesh** — so dev's metrics pipeline doesn't depend on Phase 3
(east-west) being healthy.

Requires `vmcluster.vminsert.externalExposure.enabled` **and** the HTTPRoute to actually be live
on management first. If they aren't, writes fail closed (connection refused) rather than being
silently dropped — a safe failure mode.

> 💤 **This overlay is currently inert.** The ApplicationSet still gates dev behind a
> `victoria-metrics=true` per-component label that is not yet set, so the overlay existing
> changes nothing until that label is added.
