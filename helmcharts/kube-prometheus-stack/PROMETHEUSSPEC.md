# Prometheus / ServiceMonitor discovery (`prometheusSpec`)

How this chart's in-stack Prometheus decides which `ServiceMonitor`/`PodMonitor`
resources to scrape, and why most of that is currently moot.

## Current state

`prometheus.enabled: false` — disabled since the VictoriaMetrics cutover
(2026-07-09). Scraping and alert evaluation now happen exclusively via
VictoriaMetrics (`helmcharts/victoria-metrics`, `helmcharts/victoria-metrics-operator`):
`victoria-metrics-operator` mirrors every `ServiceMonitor`/`PodMonitor`/`PrometheusRule`
into `VMServiceScrape`/`VMPodScrape`/`VMRule` **unconditionally**
(`selectAllByDefault: true`, no label filter), so declaring a `ServiceMonitor`
anywhere is already sufficient for VictoriaMetrics to scrape it — none of the
selector config below affects that path.

**With `prometheus.enabled: false`, the Prometheus custom resource isn't
rendered at all** — everything under `prometheusSpec` in `values.yaml` is
inert. It's documented here for whoever re-enables it (or as ground truth for
why the values look the way they do). `prometheusOperator` itself stays
enabled regardless — it still reconciles the live Alertmanager CR and owns
the CRDs VictoriaMetrics' operator mirrors from.

Full cutover details: `defyjoy/alarmify-docs` `docs/victoria-metrics/migration-runbook.md`.

## ServiceMonitor selector options

`prometheusSpec.serviceMonitorSelector` + `serviceMonitorSelectorNilUsesHelmValues`
control which `ServiceMonitor`s an *enabled* in-stack Prometheus would pick up.
These are the four shapes this config can take, each with the exact YAML and
what it matches.

### Option 1 — Helm release label (**currently active**)

When `serviceMonitorSelectorNilUsesHelmValues: true`, an empty
`serviceMonitorSelector: {}` doesn't mean "match nothing" or "match
everything" — the chart substitutes an implicit `release: <helm-release-name>`
label match.

```yaml
prometheusSpec:
  serviceMonitorSelector: {}
  serviceMonitorSelectorNilUsesHelmValues: true
```

Prometheus matches `ServiceMonitor`s carrying:

```yaml
labels:
  release: local-kube-prometheus-stack
```

⚠️ **Limitation:** tightly coupled to the Helm release name. Renaming the
release means every `ServiceMonitor` needs its label updated to match.

### Option 2 — Custom label selector (recommended for flexibility)

Define your own label, independent of the Helm release name:

```yaml
prometheusSpec:
  serviceMonitorSelector:
    matchLabels:
      prometheus-scrape: "enabled"   # any label name you want
  serviceMonitorSelectorNilUsesHelmValues: false
```

Every `ServiceMonitor` that should be scraped then needs the matching label:

```yaml
serviceMonitor:
  enabled: true
  additionalLabels:
    prometheus-scrape: "enabled"
```

**Benefits over Option 1:** decoupled from the Helm release name, explicit
opt-in per `ServiceMonitor`, and the label name/value are whatever you choose
— easy to keep consistent across components.

### Option 3 — Discover all ServiceMonitors (least secure)

No label filtering at all:

```yaml
prometheusSpec:
  serviceMonitorSelector: {}
  serviceMonitorSelectorNilUsesHelmValues: false
```

⚠️ **Warning:** Prometheus scrapes *any* `ServiceMonitor` in *any* namespace.
Least secure option — trusted environments or local testing only.

### Option 4 — Advanced label selectors (`matchExpressions`)

For selection logic beyond a single label — `In`/`NotIn`/`Exists` across
multiple keys:

```yaml
prometheusSpec:
  serviceMonitorSelector:
    matchExpressions:
      - key: monitoring
        operator: In
        values: ["prometheus", "enabled"]
      - key: environment
        operator: NotIn
        values: ["test"]
  serviceMonitorSelectorNilUsesHelmValues: false
```

### Namespace selector (applies regardless of option chosen)

```yaml
prometheusSpec:
  # {} = all namespaces (recommended for cluster-wide monitoring)
  serviceMonitorNamespaceSelector: {}
```

To restrict discovery to specific namespaces instead:

```yaml
prometheusSpec:
  serviceMonitorNamespaceSelector:
    matchLabels:
      monitoring: "enabled"
```

## What's actually configured today

```yaml
prometheusSpec:
  serviceMonitorSelector: {}
  serviceMonitorSelectorNilUsesHelmValues: true
  serviceMonitorNamespaceSelector: {}
```

That's **Option 1** (Helm release label) + all-namespaces discovery — chosen
for zero extra per-`ServiceMonitor` labeling, at the cost of the release-name
coupling noted above. Since `prometheus.enabled: false`, this is inert either
way; it reflects what would activate if Prometheus were re-enabled.

### History: the label that never matched

An earlier revision used Option 2's shape instead:

```yaml
# Previously blocked every chart ServiceMonitor (no SM used this label):
prometheusSpec:
  serviceMonitorSelector:
    matchLabels:
      kube-prometheus-stack-internal-scrape: "true"
  serviceMonitorSelectorNilUsesHelmValues: false
```

No `ServiceMonitor` in this repo ever carried the
`kube-prometheus-stack-internal-scrape: "true"` label, so this silently
blocked every chart `ServiceMonitor` from being selected — a real,
easy-to-miss footgun of Option 2 (the selector *looks* configured, but
nothing satisfies it). Current config uses Option 1 instead, specifically to
avoid this class of bug.

## The `prometheus-scrape: "enabled"` label doesn't do anything today

Several components still apply Option 2's label:

```yaml
# grafana.serviceMonitor.labels, kube-state-metrics.prometheus.monitor.additionalLabels,
# prometheus-node-exporter.prometheus.monitor.additionalLabels (commented)
prometheus-scrape: "enabled"
```

but the **active** selector is Option 1 (release label), which doesn't look
at `prometheus-scrape` at all. The label is applied for labeling consistency
only; it doesn't cause anything to be scraped by the in-stack Prometheus
(moot anyway while `prometheus.enabled: false`), and has no effect on the
VictoriaMetrics scrape path either (that mirrors *all* `ServiceMonitor`s
regardless of labels).

## Other related toggles

| Value | Effect |
|---|---|
| `kubernetesServiceMonitors.enabled` | Whether the upstream chart's built-in Kubernetes-component ServiceMonitors (apiserver, coredns, kube-scheduler, etc.) are created. Currently `true`. |
| `prometheusOperator.serviceMonitor.selfMonitor` | Whether the operator scrapes itself. Currently `true`. |
| `prometheus.serviceMonitor.selfMonitor` | Whether Prometheus scrapes itself. Currently `true`, moot while `prometheus.enabled: false`. |
