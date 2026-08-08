# keda

KEDA — event-driven autoscaling. Installs the operator, the metrics API server, and the
admission webhooks.

> ⚠️ **Not the same chart as [`keda-operator`](../keda-operator/README.md).** Both exist in this
> repo. This one configures the full upstream KEDA chart under the `keda:` key; `keda-operator`
> is a thinner wrapper. Check which one the ApplicationSet actually deploys before editing.

---

## Configuration

### Components

```yaml
keda:
  enabled: true
  crds:
    install: true
  watchNamespace: ""
  operator:
    name: keda-operator
    replicaCount: 1
  metricsServer:
    replicaCount: 1
  webhooks:
    enabled: true
    name: keda-admission-webhooks
    replicaCount: 1
    failurePolicy: Ignore
```

`watchNamespace: ""` means all namespaces.

> 🔓 **`failurePolicy: Ignore`** means a webhook outage lets invalid `ScaledObject`s through
> rather than blocking all writes. That is the safer default for a homelab — the alternative
> (`Fail`) makes KEDA's availability a hard dependency for applying any scaled resource.

### Host networking is off

```yaml
keda:
  metricsServer:
    useHostNetwork: false
    dnsPolicy: ClusterFirst
  webhooks:
    useHostNetwork: false
```

Host networking is only required under some CNI configurations; it is not needed here and stays
off so the components sit behind normal cluster networking.

### Security contexts — set per component

```yaml
keda:
  securityContext:
    operator:      &sec
      allowPrivilegeEscalation: false
      capabilities: { drop: [ALL] }
      readOnlyRootFilesystem: true
      seccompProfile: { type: RuntimeDefault }
    metricServer: *sec
    webhooks:     *sec
  podSecurityContext:
    operator:     { runAsNonRoot: true }
    metricServer: { runAsNonRoot: true }
    webhooks:     { runAsNonRoot: true }
```

Unlike most charts, KEDA takes **one context block per component** rather than a single shared
one — all three are set identically, with `readOnlyRootFilesystem: true`.

*(Shown with a YAML anchor for brevity; `values.yaml` spells each block out in full.)*

### Resources

All three components are sized identically:

```yaml
keda:
  operator:      { resources: { requests: { cpu: 100m, memory: 100Mi }, limits: { cpu: 200m, memory: 200Mi } } }
  metricsServer: { resources: { … same … } }
  webhooks:      { resources: { … same … } }
```

### Metrics are exposed but not scraped

```yaml
keda:
  prometheus:
    operator:
      enabled: true
      port: 8080
      serviceMonitor:
        enabled: false
        additionalLabels:
          prometheus-scrape: "enabled"
    metricServer: { enabled: true, port: 9022, serviceMonitor: { enabled: false } }
    webhooks:     { enabled: true, port: 8080, serviceMonitor: { enabled: false } }
```

Each component publishes `/metrics`, but **every `serviceMonitor.enabled` is `false`** — nothing
scrapes KEDA today. The `prometheus-scrape: "enabled"` labels are inert, the same as elsewhere
in this repo (see
[`kube-prometheus-stack`](../kube-prometheus-stack/PROMETHEUSSPEC.md)).

### RBAC

```yaml
keda:
  rbac:
    create: true
    aggregateToDefaultRoles: false
```

`aggregateToDefaultRoles: false` keeps KEDA's permissions out of the built-in `view`/`edit`/
`admin` ClusterRoles.

### Logging

```yaml
keda:
  logging:
    operator:     { level: info, format: console }
    metricServer: { level: "0" }
    webhooks:     { level: info, format: console }
```

The metrics server uses klog-style numeric verbosity (`"0"`), not the named levels the other two
take.
