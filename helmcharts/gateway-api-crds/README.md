# gateway-api-crds

Vendored [Gateway API](https://gateway-api.sigs.k8s.io/) CRDs, **experimental channel**, pinned to
`v1.5.1`. Upstream artifact is
`https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml`,
copied byte-for-byte to `templates/experimental-install.yaml`.

Targets **management** (`local`) and **dev** — both clusters, since the CRDs are a cluster-wide API
surface rather than a workload.

This is the largest dependency in the sync graph. Everything below is written against these CRDs,
and none of it renders without them:

- `helmcharts/istio/istio-gateway` (`Gateway`), `istio-eastwest`, `istio-eastwest-classic`
- `helmcharts/cloudnative-pg` and `helmcharts/victoria-metrics` (`TCPRoute`)
- `helmcharts/harbor`, `helmcharts/kube-prometheus-stack`, `helmcharts/argocd`

## Why this chart exists

Until now these CRDs were the only dependency in the graph with **no declarative source** — they
were `kubectl apply`'d out of band during each cluster build, exactly the way
`helmcharts/argocd/bootstrap/dev-cluster-serviceaccount.yaml` still is. Nothing in git recorded
which version was live, and the one comment that tried to
(`helmcharts/argocd/templates/cluster/dev-cluster-secret.yaml`) had drifted: it claimed `v1.4.1`
while management had been running `v1.5.1` since some unrecorded point.

A cluster rebuild therefore silently depended on whoever rebuilt it remembering the right channel
and version. Getting the *channel* wrong is the dangerous half — the standard channel omits
`TCPRoute`/`TLSRoute` entirely, so `cloudnative-pg` and `victoria-metrics` would fail to sync with
`could not find gateway.networking.k8s.io/TCPRoute CRD` and nothing would explain why.

## Configuration

### Sync wave −28

```yaml
argocd.argoproj.io/sync-wave: "-28"
```

Third overall, immediately after `argocd` (−30) and `argocd-apps` (−29), and ahead of every chart
that declares a Gateway API kind — the earliest of which is `istio-gateway` at −10. Nothing this
chart needs is produced by any other wave: CRDs have no runtime dependencies, not even a CNI.

### `ServerSideApply=true` is mandatory, not stylistic

```yaml
syncOptions:
  - ServerSideApply=true
```

These CRDs exceed the 256 KB `kubectl.kubernetes.io/last-applied-configuration` annotation limit.
A client-side apply fails with `metadata.annotations: Too long: must have at most 262144 bytes`.

### Adoption, not installation

On both existing clusters the ten `gateway.networking.k8s.io` CRDs are already live and carry no
`argocd.argoproj.io/instance` label. Argo CD adopts pre-existing resources that Helm refuses to
(see the root `CLAUDE.md`), so the first sync takes ownership of what is already there rather than
recreating it.

The vendored bundle is a **superset** of what management currently runs. It additionally contains:

| Resource | Kind | Live on management? |
|---|---|---|
| `xbackendtrafficpolicies.gateway.networking.x-k8s.io` | CRD | no |
| `xmeshes.gateway.networking.x-k8s.io` | CRD | no |
| `safe-upgrades.gateway.networking.k8s.io` | `ValidatingAdmissionPolicy` (+ `Binding`) | no |

The two `x-k8s.io` CRDs are inert — no controller in either cluster watches them. The
`ValidatingAdmissionPolicy` is the meaningful addition: it rejects CRD updates that would drop a
stored API version, which is precisely the failure mode an unpinned out-of-band `kubectl apply`
used to risk. It is kept because that guard is the reason to put these in git at all.

### Per-cluster gating

The ApplicationSet AND's `environment In [dev, local]` with a `gateway-api-crds: "true"` label, the
same shape the Istio charts use, so adoption can be staged one cluster at a time. Management is
enabled; **dev is deliberately still commented out** in
`helmcharts/argocd/templates/cluster/dev-cluster-secret.yaml` — dev's live CRD inventory has not
been confirmed against this bundle. Confirm with the command below before uncommenting.

```bash
export KUBECONFIG=~/.kube/talos-dev.yaml
kubectl get crd -o json | jq -r '.items[]
  | select(.spec.group | test("gateway.networking"))
  | "\(.metadata.name)\t\(.metadata.annotations["gateway.networking.k8s.io/bundle-version"])\t\(.metadata.annotations["gateway.networking.k8s.io/channel"])"'
```

Every row must read `v1.5.1  experimental`. A row showing `standard`, or a lower bundle version,
means the adopting sync will upgrade that CRD in place — check it against the
`ValidatingAdmissionPolicy` above before pushing.

## Upgrading

Replace the single vendored file, keeping the filename stable so the diff stays readable:

```bash
curl -fsSL -o helmcharts/gateway-api-crds/templates/experimental-install.yaml \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/vX.Y.Z/experimental-install.yaml
```

Then bump `appVersion` in `Chart.yaml` and the version stated at the top of this README. Do not
hand-edit the bundle — it is an upstream artifact, and local edits are invisible at the next
refresh.
