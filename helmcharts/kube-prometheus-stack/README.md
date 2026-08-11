# Kube Prometheus Stack Helm Chart

This Helm chart wraps the official [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) chart for a GitOps-friendly Prometheus stack.

## Overview

The upstream stack includes Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics, and Prometheus Operator CRDs. This wrapper adds:

- **Argo CD Grafana dashboards** — optional ConfigMaps from `argocdDashboards` (see `values.yaml` and `templates/argocd-dashboards.yaml`).
- **Extra Grafana dashboards** — URL-based dashboards under `kube-prometheus-stack.grafana.dashboards` in `values.yaml`.

**Scraping model:** in-stack Prometheus is disabled (`prometheus.enabled: false`) — VictoriaMetrics is the sole scrape/alerting path and mirrors every `ServiceMonitor`/`PodMonitor` unconditionally, so `prometheusSpec` selector config below is currently inert. Full detail, including the currently-configured selector option and a label that looks load-bearing but isn't: [`PROMETHEUSSPEC.md`](./PROMETHEUSSPEC.md).

## Deployment (Argo CD)

This repo deploys the chart with a plain **Argo CD Application**, not an ApplicationSet:

- Application manifest: [`helmcharts/argocd-apps/templates/applications/kube-prometheus-stack.yaml`](../argocd-apps/templates/applications/kube-prometheus-stack.yaml)
- Source path: `helmcharts/kube-prometheus-stack`, `values.yaml` only.

Relevant **sync and namespace** settings from that Application include `CreateNamespace=true`, `ServerSideApply=true`, `RespectIgnoreDifferences=true`, and **privileged** pod security labels on the managed namespace (`kube-prometheus-stack`). Adjust the Application if your cluster policy differs.

## Configuration

All upstream settings live under the **`kube-prometheus-stack:`** key in `values.yaml` (Helm dependency nesting). Do not put upstream keys at the top level unless they belong to this wrapper (e.g. `argocdDashboards`).

Upstream chart version is pinned in `Chart.yaml` / `Chart.lock` (for example `78.x`); the wrapper `appVersion` may lag the operator version shipped inside that release—trust the dependency version for upgrade notes.

### Prometheus is disabled

```yaml
kube-prometheus-stack:
  prometheus:
    enabled: false
```

Disabled at the **VictoriaMetrics cutover on 2026-07-09** — VictoriaMetrics is the sole
scrape/alerting path now. `prometheusOperator` stays enabled regardless, since the CRDs and
controller are still what `ServiceMonitor`/`PodMonitor` objects are reconciled by.

The `prometheusSpec` selector config that remains in `values.yaml` is therefore **inert**. So
is the `prometheus-scrape: "enabled"` label applied to several ServiceMonitors — it looks
load-bearing but controls nothing today. Both are explained in
[`PROMETHEUSSPEC.md`](./PROMETHEUSSPEC.md).

### Disabled default rules

```yaml
kube-prometheus-stack:
  defaultRules:
    disabled:
      InfoInhibitor: true
      KubePodNotReady: true
      KubePodCrashLooping: true
      KubeContainerWaiting: true
      KubeDeploymentReplicasMismatch: true
      KubeDeploymentRolloutStuck: true
      KubeStatefulSetReplicasMismatch: true
```

`InfoInhibitor` is a meta-alert that fires whenever *any* `severity=info` alert is active (for
example a `CPUThrottlingHigh` on any sidecar). It exists for Alertmanager **inhibition
only, not notifications** — so the rule is disabled and any residual instances are routed to
null in `templates/alertmanager-config.yaml`, which overrides the upstream defaults.

The six `Kube*` rules are disabled because `templates/alert-rules.yaml` ships custom
equivalents: upstream logic plus a dynamic `service` label.

### Grafana datasource points at vmselect

```yaml
kube-prometheus-stack:
  grafana:
    sidecar:
      datasources:
        url: "http://vmselect-local-victoria-metrics.victoria-metrics.svc:8481/select/0/prometheus"
```

Repointed at the VictoriaMetrics cutover. vmselect speaks the Prometheus HTTP API, so the
datasource **name and uid stay `Prometheus`/`prometheus`** and every existing dashboard — which
references the datasource by uid — keeps working unchanged. Only the URL moved.

### Grafana dashboard folder layout

```yaml
kube-prometheus-stack:
  grafana:
    sidecar:
      dashboards:
        folder: /tmp/dashboards
        defaultFolderName: "kube-prometheus-stack"
        folderAnnotation: grafana_folder
        annotations:
          grafana_folder: "kube-prometheus-stack"
        provider:
          foldersFromFilesStructure: true
          path: /tmp/dashboards
```

The sidecar discovers dashboards from ConfigMaps labelled `grafana_dashboard: "1"` and files
them by their `grafana_folder` annotation.

The **key detail**: `provider.path` must be the *parent* directory (`/tmp/dashboards`), not the
subdirectory, for `foldersFromFilesStructure` to build folders correctly. Applying
`grafana_folder: "kube-prometheus-stack"` as a default annotation is what keeps upstream
dashboards — which ship without that annotation — out of the root folder. Custom dashboards
such as the ArgoCD set override it with their own value.

Because of this, **no `default` provider is needed** in `dashboardProviders`. That list only
serves dashboards loaded from URLs, not sidecar-discovered ConfigMaps.

### Grafana routing

```yaml
kube-prometheus-stack:
  grafana:
    ingress:
      enabled: false
    route:
      main:
        enabled: true
        annotations:
          external-dns.alpha.kubernetes.io/hostname: grafana.jrclabs.xyz
          external-dns.alpha.kubernetes.io/class: cloudflare
        hostnames:
          - grafana.jrclabs.xyz
        parentRefs:
          - group: gateway.networking.k8s.io
            kind: Gateway
            name: gateway
            namespace: gateway-system
            sectionName: http
```

Gateway API `HTTPRoute` (still **BETA** in the Grafana subchart) replaces the Ingress, parented to
the internal `gateway` (`gke-l7-rilb`) like every other route in this repo — see
`helmcharts/gke-gateway`'s README for why. Only an `http` `sectionName` is used: both Gateways'
`https` listener is `enabled: false` with no `certificateRefs` (no `ClusterIssuer` exists yet), so
a route parented to `sectionName: https` would attach and then dangle. The route previously
carried both `http` and `https` parentRefs and pointed at the stale Proxmox-era `grafana.home.arpa`
hostname — neither the Istio mesh nor the `*.home.arpa` DNS/cert setup they depended on exist in
this fork.

### Grafana SSO (Zitadel OIDC)

```yaml
kube-prometheus-stack:
  grafana:
    alarmifyOidc:
      enabled: false
      externalSecret:
        vaultPath: alarmify/management/zitadel
        clientIdProperty: ZITADEL_GRAFANA_CLIENT_ID
        clientSecretProperty: ZITADEL_GRAFANA_CLIENT_SECRET
    grafana.ini:
      server:
        root_url: http://grafana.jrclabs.xyz
      auth.generic_oauth:
        enabled: false
```

Browser logins go through Zitadel's `grafana` OIDC app (platform project, defined in
`alarmify-common-infra/terraform/zitadel`). `templates/grafana-oidc-external-secret.yaml` syncs
the client id and secret from the Terraform-owned Vault object into the `grafana-oidc` Secret,
which Grafana reads as `GF_AUTH_GENERIC_OAUTH_*` env vars — the secret never touches the
`grafana.ini` ConfigMap.

⚠️ **`alarmifyOidc.enabled` is `false` since 2026-08-06 — one missing Vault object wedged the
entire chart.** Vault on management was re-initialized that morning and came back holding only
`kv/alarmify/local/cloudflared/`, so `alarmify/management/zitadel` no longer resolved. The
resulting failure chain is worth understanding, because nothing about it was obvious from the
Argo CD UI:

1. The `grafana-oidc` ExternalSecret carries `argocd.argoproj.io/sync-wave: "-1"`, so Argo CD
   applies it *before* everything else and waits for it to report Healthy.
2. External Secrets left it at `SecretSyncedError` (`Secret does not exist`), so wave −1 never
   completed. Argo retried 5× and gave up.
3. **Nothing in wave 0 was ever applied** — no Grafana, no Alertmanager, no exporters, and none
   of the `PrometheusRule` objects. All ~130 resources sat `OutOfSync` with an empty namespace.

Step 3 is the damaging one: `victoria-metrics-operator` mirrors this chart's `PrometheusRule`
objects into `VMRule`s, so while the app is wedged there are **no alerting rules in the cluster
at all** — the same silent-alerting failure mode described in the repo `CLAUDE.md`. Gating the
integration keeps a missing credential scoped to the feature that needs it instead of taking
monitoring down with it.

To restore once `alarmify/management/zitadel` is back in Vault, three edits in `values.yaml`:
set `alarmifyOidc.enabled: true`, set `auth.generic_oauth.enabled: true`, and re-add the
`envValueFrom` block that maps the Secret into Grafana's environment:

```yaml
    envValueFrom:
      GF_AUTH_GENERIC_OAUTH_CLIENT_ID:
        secretKeyRef:
          name: grafana-oidc
          key: client-id
      GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:
        secretKeyRef:
          name: grafana-oidc
          key: client-secret
```

`envValueFrom` has to come out while the Secret is absent: env references are resolved when the
pod starts, whether or not `auth.generic_oauth` is on, so leaving it in place would hold Grafana
in `CreateContainerConfigError` even with SSO disabled.

⚠️ **Logins are blocked upstream.** The `platform` Zitadel project has `has_project_check = true`
and its operator grant is commented out, so no user can authorize *any* app in it — Kiali has
been in this state since 2026-07-28 and Grafana now joins it. The chart config below is complete;
it starts working once that grant exists.

Two other things that are easy to break: `root_url` must match the redirect URI registered in
Terraform, and every SSO user is pinned to Grafana's **Viewer** role (admin stays on the local
account) because no Zitadel role is asserted into the token. All three, plus rotation and
troubleshooting: [`GRAFANA-OIDC.md`](./GRAFANA-OIDC.md).

### Alertmanager root config

```yaml
kube-prometheus-stack:
  alertmanager:
    alertmanagerSpec:
      useExistingSecret: true
      alertmanagerConfiguration:
        name: alarmify-alertmanager-config
      alertmanagerConfigSelector: {}
      alertmanagerConfigNamespaceSelector: {}
```

Two easily-confused mechanisms:

| Field | Mechanism | Status here |
|---|---|---|
| `alertmanagerConfiguration.name` | **full replacement** root config | in use — `templates/alertmanager-config.yaml` renders it |
| `alertmanagerConfigSelector` | additive **merge-by-label** child routes | unused — nothing creates a labeled AlertmanagerConfig |

`templates/alertmanager-config.yaml` renders an `AlertmanagerConfig` **object** (not a Secret)
with that name, which takes precedence over `configSecret`, so none is set. `useExistingSecret:
true` still matters: it stops the upstream chart's own `secret.yaml` from rendering an unused
default. No manual `secrets:` mounting is needed — the operator resolves `clientSecret` and
`routingKey` references inside the AlertmanagerConfig itself. Full design:
[`OIDC.md`](./OIDC.md).

### Webhook target

The `alarmify` receiver posts to the **in-cluster Service on HTTP port 80**, so Alertmanager
does not depend on gateway TLS for `ingest.home.arpa`. If the gateway cert expires,
cluster-internal delivery still works. To use the public hostname again, renew the gateway cert
first or add `http_config.tls_config` (e.g. a CA file).

### Alarmify OAuth2 receiver

```yaml
kube-prometheus-stack:
  alertmanager:
    alarmifyOauth:
      enabled: false
      clientId: "workquark-alertmanager"
      projectId: "383904466425938149"
      externalSecret:
        vaultPath: alarmify/management/alertmanager-oauth
```

The `alarmify` receiver authenticates to `alarmify-ingest-api` with a Zitadel client-credentials
grant. `enabled` gates both `templates/alarmify-oauth-external-secret.yaml` and the `httpConfig.
oauth2` block in `templates/alertmanager-config.yaml`, and the two must move together — the
operator resolves `clientSecret` out of the AlertmanagerConfig, so a config referencing a Secret
that External Secrets never created is rejected.

**A rejected AlertmanagerConfig means no Alertmanager StatefulSet is created at all** — not a
degraded Alertmanager, none. That is exactly how `alarmify/prod/alertmanager-oauth` dropped every
alert in the cluster for seven days (see the repo `CLAUDE.md`), and it recurred on 2026-08-06 when
the Vault re-initialization removed `alarmify/management/alertmanager-oauth`. Unlike the Grafana
ExternalSecret this one has no sync-wave, so it does not block the rest of the chart — it fails
quietly and takes only Alertmanager with it.

⚠️ **Disabled since 2026-08-06.** With `enabled: false` the receiver still posts to
`alarmify-ingest-api`, but **unauthenticated** — the ingest API will reject those calls. Alerts
fire and are visible in the Alertmanager UI, and rule evaluation is unaffected, but delivery into
Alarmify stays broken until the Vault object is restored and this is flipped back to `true`.

### Kubelet metrics

```yaml
kube-prometheus-stack:
  kubelet:
    enabled: true
```

Kubelet metrics require privileged access, which conflicts with `restricted` PodSecurity. They
are enabled here because they're essential for cluster monitoring; the namespace carries
privileged pod-security labels (set by the ArgoCD Application, see
[Deployment](#deployment-argo-cd)).

## Dependencies

- **Kubernetes:** `>= 1.25` (required by current upstream kube-prometheus-stack chart; older README “1.19+” is obsolete).
- **Helm 3**
- **Prometheus Community** Helm repo: `https://prometheus-community.github.io/helm-charts`

## Local installation

From the repo root, install dependencies then install (release name is arbitrary):

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
cd helmcharts/kube-prometheus-stack
helm dependency update
helm install kube-prometheus-stack . -n kube-prometheus-stack --create-namespace
```

For parity with Argo CD, prefer the same `values.yaml` and the same namespace the Application uses.

---

## Two separate Zitadel integrations

This chart talks to Zitadel twice, for unrelated reasons. Don't cross the wires:

| | Alertmanager | Grafana |
|---|---|---|
| Flow | client credentials (machine-to-machine) | authorization code (browser login) |
| Values | `alertmanager.alarmifyOauth` | `grafana.alarmifyOidc` + `grafana.ini` |
| Secret | `alarmify-oauth` | `grafana-oidc` |
| Vault source | `alarmify/management/alertmanager-oauth`, hand-seeded | `alarmify/management/zitadel`, Terraform-owned |
| Doc | [`OIDC.md`](./OIDC.md) | [`GRAFANA-OIDC.md`](./GRAFANA-OIDC.md) |

The `alarmify` receiver authenticates to the ingest-api webhook via Zitadel
OAuth2 client credentials; Grafana authenticates human logins via
`auth.generic_oauth`. They share only the issuer.

---

## PagerDuty and Alertmanager

Disabled by default — the active alert path is the Alarmify OAuth2 receiver
above. PagerDuty is kept configured-but-off (`alertmanager.pagerduty.enabled: false`,
`templates/pagerduty-external-secret.yaml` fully commented out) as a
rollback-ready path. Current state, config reference, and the enable
checklist: [`PAGERDUTY.md`](./PAGERDUTY.md).
