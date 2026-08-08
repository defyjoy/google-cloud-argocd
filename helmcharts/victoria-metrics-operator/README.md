# victoria-metrics-operator

Wrapper around the upstream `victoria-metrics-operator` chart. Installs the operator and its
CRDs — the prerequisite for [`victoria-metrics`](../victoria-metrics/README.md), which is where
the actual VMCluster/VMAgent/VMAlert objects live.

- Upstream defaults: <https://github.com/VictoriaMetrics/helm-charts/tree/master/charts/victoria-metrics-operator>
- Install order: **before** `victoria-metrics`

## Wrapper pattern

```yaml
enabled: true

victoria-metrics-operator:
  replicaCount: 1
```

The top-level `enabled` toggles the upstream dependency via `condition: enabled` in
`Chart.yaml`. **All settings for the dependency must be nested under the
`victoria-metrics-operator:` key** — anything placed at the top level is silently ignored by
Helm.

---

## Configuration

### Security contexts

```yaml
victoria-metrics-operator:
  podSecurityContext:
    enabled: true
    fsGroup: 2000
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  securityContext:
    enabled: true
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    seccompProfile:
      type: RuntimeDefault
    capabilities:
      drop:
        - ALL
```

Both pod- and container-level contexts are set, which is what `restricted` PodSecurity
requires — see [`tempo`](../tempo/README.md#container-securitycontext-is-set-explicitly) for
what happens when only the pod-level one is set.

### Resources

```yaml
victoria-metrics-operator:
  resources:
    requests: { memory: 128Mi, cpu: 50m }
    limits:   { memory: 256Mi, cpu: 100m }
```

> 📉 **CPU limit halved on 2026-07-11**: 24h peak usage of 6.7m sits well under half the
> previous limit, per VictoriaMetrics.

### Watch scope

```yaml
victoria-metrics-operator:
  watchNamespaces: []
```

Empty means the operator watches **all** namespaces — the upstream default, kept as-is.

### CRDs and webhooks

```yaml
victoria-metrics-operator:
  crds:
    enabled: true
    plain: false
  admissionWebhooks:
    enabled: true
    policy: Ignore
    certManager:
      enabled: true
```

Admission webhook certificates are issued by cert-manager, so
[`cert-manager`](../cert-manager/README.md) must be healthy for the operator to accept objects.

**`policy: Ignore` overrides the upstream default of `Fail`, and must stay that way.**

This chart registers 24 `ValidatingWebhookConfiguration` entries — one per VictoriaMetrics CRD —
each with `timeoutSeconds: 10`. Upstream defaults them to `failurePolicy: Fail`, meaning any write
to a `VMPodScrape`/`VMRule`/`VMServiceScrape` is rejected outright whenever the operator is not
reachable to validate it.

The problem is that the *same* Argo CD Application registers those webhooks and creates the
Deployment backing them, so on every install, upgrade, or pod reschedule there is a window where the
webhook exists and its backend does not. Observed live on management, 2026-08-06:

```
Apply failed ... failed calling webhook "vmpodscrapes.operator.victoriametrics.com":
Post "https://local-victoria-metrics-operator...svc:9443/...?timeout=10s":
dial tcp 10.96.204.74:9443: connect: no route to host
```

Every chart shipping a `VMPodScrape` — `istio/ztunnel`, `istio/istio-gateway`, `istio/istio-eastwest`,
`nats`, and all six `alarmify-*` charts — stalled the full 10 seconds per resource, hard-failed, then
re-entered Argo CD's 5s→3m retry backoff. `istio-gateway` and `ztunnel` were still burning retry
attempts minutes into the bootstrap.

`Ignore` makes the webhook fail *open* during that window: the object is admitted unvalidated, and the
operator reconciles it normally once it is up. The validation lost is schema-level sanity checking on
VictoriaMetrics CRs, which Argo CD's own dry-run already covers for anything committed to this repo.
A rejected-and-retried sync is strictly worse than an unvalidated CR here.

Note this is independent of sync-wave ordering. Placing `victoria-metrics-operator` ahead of its
consumers (it sits at wave `-16`, ahead of `ztunnel` at `-11`) fixes *CRD* availability, but does
nothing about the webhook backend being unready — that race is inside a single Application's own sync.
