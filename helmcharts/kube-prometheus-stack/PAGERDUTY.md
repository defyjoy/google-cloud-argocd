# PagerDuty & custom webhook endpoints (Alertmanager)

Two alternatives to the default Alarmify receiver: **PagerDuty**
(configured-but-disabled, needs template changes to activate) and
**`customWebhookEndpoints`** (generic webhooks, already wired and active as
soon as you set a value). This chart's active alert path today is the
Alarmify OAuth2 receiver — see [`OIDC.md`](./OIDC.md).

Both would be added as receivers/routes inside the same `AlertmanagerConfig`
object (`alarmify-alertmanager-config`, `templates/alertmanager-config.yaml`)
that carries the Alarmify receiver — see
[`OIDC.md`](./OIDC.md#config-mechanism-alertmanagerconfig-not-a-secret) for
why this chart uses an `AlertmanagerConfig` object instead of a `Secret`.

## PagerDuty

Rollback-ready PagerDuty integration, disabled by default.

### `values.yaml`: `alertmanager.pagerduty`

The actual current block:

```yaml
alertmanager:
  pagerduty:
    enabled: false
    integrationKey: ""
    vaultPath: "pagerduty/integration-key"
    vaultProperty: "key"
    serviceKey: ""
    severity:
      critical: "critical"
      warning: "warning"
      info: "info"
```

| Field | Meaning |
|---|---|
| `enabled` | Documents intent only — see [Current state](#current-state); does not by itself route anything |
| `integrationKey` | Left empty — populated via the ExternalSecret, not committed to git |
| `vaultPath` | Vault path for the integration key, relative to the `kv` mount point (KV v2): full API path is `/v1/kv/data/pagerduty/integration-key` |
| `vaultProperty` | Field name within that Vault path, e.g. `key` |
| `serviceKey` | For PagerDuty Events API v2, if used instead of the routing-key webhook path |
| `severity.{critical,warning,info}` | Default severity label mapping for routing |

### Current state

- `alertmanager.pagerduty.enabled: false` (above).
- `templates/pagerduty-external-secret.yaml` is **entirely commented out** —
  Helm renders nothing from it until it's restored (full contents below).
- **`alertmanager.pagerduty.*` values are inert.** Unlike the Alarmify
  receiver, no PagerDuty `receiver`/`route` is wired into the
  `AlertmanagerConfig` rendered by `templates/alertmanager-config.yaml`.
  Setting `pagerduty.enabled: true` alone does nothing — you must also add a
  `pagerdutyConfigs` receiver and a route (see
  [Enabling PagerDuty](#enabling-pagerduty) below).

### `templates/pagerduty-external-secret.yaml` (disabled)

The full template, currently commented out line-for-line:

```yaml
# apiVersion: external-secrets.io/v1
# kind: ExternalSecret
# metadata:
#   name: pagerduty-integration-key
#   namespace: kube-prometheus-stack
# spec:
#   refreshInterval: 1h
#   secretStoreRef:
#     name: vault-secretstore
#     kind: ClusterSecretStore
#   target:
#     name: pagerduty-integration-key
#     creationPolicy: Owner
#     deletionPolicy: Retain
#     template:
#       type: Opaque
#       engineVersion: v2
#       mergePolicy: Replace
#       metadata:
#         annotations:
#           external-secrets.io/managed-by: external-secrets
#         labels:
#           app.kubernetes.io/component: pagerduty
#           app.kubernetes.io/instance: alertmanager
#           app.kubernetes.io/managed-by: Helm
#           app.kubernetes.io/name: alertmanager
#           app.kubernetes.io/part-of: kube-prometheus-stack
#   data:
#     - secretKey: integration-key
#       remoteRef:
#         conversionStrategy: Default
#         decodingStrategy: None
#         key: "pagerduty/integration-key"
#         metadataPolicy: None
#         property: "key"
```

Uncommenting this (and removing the `#` prefixes) is step 2 of
[Enabling PagerDuty](#enabling-pagerduty) below — it creates the
`pagerduty-integration-key` k8s Secret from the Vault path above. This part
is unchanged by the `AlertmanagerConfig` migration — the Secret still needs
to exist in the cluster; what changed is how the receiver *references* it
(see below).

### Why file-based secrets, not environment variables

Alertmanager does **not** expand environment variables in its config file —
this is why `AlertmanagerConfig`'s `pagerdutyConfigs[].routingKey` (like
Alarmify's `oauth2.clientSecret`, see [`OIDC.md`](./OIDC.md)) is a native
`{name, key}` Secret reference rather than a literal value:

Wrong — sent to PagerDuty as the **literal string** `$PAGERDUTY_INTEGRATION_KEY`:

```yaml
receivers:
  - name: "pagerduty-critical"
    pagerdutyConfigs:
      - routingKey: $PAGERDUTY_INTEGRATION_KEY   # broken — not expanded
```

Right — a direct Secret reference; the operator resolves it, no manual file
mounting via `alertmanagerSpec.secrets` needed:

```yaml
receivers:
  - name: "pagerduty-critical"
    pagerdutyConfigs:
      - routingKey:
          name: pagerduty-integration-key
          key: integration-key
        severity: critical
```

Reference: [`AlertmanagerConfig` API — `PagerDutyConfig`](https://prometheus-operator.dev/docs/api-reference/api/#monitoring.coreos.com/v1alpha1.PagerDutyConfig).

### Enabling PagerDuty

1. Store the integration key in Vault:
   ```bash
   vault kv put kv/pagerduty/integration-key key="YOUR_KEY"
   ```
2. Uncomment `templates/pagerduty-external-secret.yaml` (shown in full
   [above](#templates-pagerduty-external-secretyaml-disabled)) so the
   `pagerduty-integration-key` Secret gets created.
3. In `values.yaml`, set `alertmanager.pagerduty.enabled: true`. No
   `alertmanagerSpec.secrets` entry needed — the receiver added in the next
   step references the Secret directly.
4. Add a `pagerdutyConfigs` receiver and a matching route to the
   `AlertmanagerConfig` in `templates/alertmanager-config.yaml`. Mirror the
   pattern already used there for the `alarmify` receiver — e.g.:
   ```yaml
   {{- $pd := default (dict) $am.pagerduty }}
   receivers:
     - name: "alarmify"
       webhookConfigs: [...]
   {{- if $pd.enabled }}
     - name: "pagerduty-critical"
       pagerdutyConfigs:
         - routingKey:
             name: pagerduty-integration-key
             key: integration-key
           severity: critical
           sendResolved: true
   {{- end }}
   ```
   (`$am` is already defined near the top of the file; `$pd` is new — add it
   next to the existing `$oauth`/`$hooks` variable declarations.) Also add a
   route (e.g. under `route.routes`) matching `severity = "critical"` to
   `pagerduty-critical` — see the `Watchdog`/`InfoInhibitor` routes already
   in that file for the `matchers` shape.
5. Verify:
   ```bash
   kubectl get externalsecret pagerduty-integration-key -n kube-prometheus-stack
   kubectl get secret pagerduty-integration-key -n kube-prometheus-stack
   kubectl describe alertmanagerconfig alarmify-alertmanager-config -n kube-prometheus-stack
   ```
   When disabled, the first two resources don't exist — that's expected.

### Related docs

- PagerDuty-side setup (service creation, integration key, escalation
  policy): [`https://github.com/Alarmify/alarmify-docs/blob/main/docs/monitoring/PAGERDUTY-ALERTMANAGER-SETUP.md`](https://github.com/Alarmify/alarmify-docs/blob/main/docs/monitoring/PAGERDUTY-ALERTMANAGER-SETUP.md).

## Custom webhook endpoints

`alertmanager.customWebhookEndpoints` is a generic list of plain HTTP(S)
webhook targets — for anything that isn't Alarmify or PagerDuty (a simple
automation hook, a second on-call tool, a test receiver). Unlike PagerDuty,
this mechanism is **already fully wired** into
`templates/alertmanager-config.yaml`: setting a value takes effect on the
next sync with no template edits required.

### `values.yaml`: `alertmanager.customWebhookEndpoints`

Current value (disabled — empty list):

```yaml
alertmanager:
  customWebhookEndpoints: []
```

### How it changes routing

`templates/alertmanager-config.yaml` picks the top-level route's receiver
based on whether `customWebhookEndpoints` is non-empty:

```yaml
route:
{{- if gt (len $hooks) 0 }}
  receiver: custom-webhooks
{{- else }}
  receiver: "alarmify"
{{- end }}
```

| `customWebhookEndpoints` | Default route receiver |
|---|---|
| `[]` (default) | `alarmify` |
| non-empty | `custom-webhooks` |

**This is mutually exclusive with the Alarmify receiver, not additive** —
setting any `customWebhookEndpoints` entries reroutes *all* default-path
alerts to the `custom-webhooks` receiver instead of Alarmify. There is no
fan-out to both from the default route.

### The rendered `custom-webhooks` receiver

Also in `templates/alertmanager-config.yaml`, only rendered when
`customWebhookEndpoints` is non-empty:

```yaml
{{- if gt (len $hooks) 0 }}
- name: custom-webhooks
  webhookConfigs:
  {{- range $hooks }}
    - url: {{ .url | quote }}
      sendResolved: {{ default true .send_resolved }}
    {{- with .httpConfig }}
      httpConfig:
        {{- toYaml . | nindent 12 }}
    {{- end }}
  {{- end }}
{{- end }}
```

`httpConfig` is passed through verbatim (`toYaml`) into the receiver's
`httpConfig`.

### Configuration reference

| Field | Required | Meaning |
|---|---|---|
| `url` | yes | Full webhook URL Alertmanager POSTs the Prometheus-format payload to |
| `send_resolved` | no (default `true`) | Whether resolved alerts also trigger a POST |
| `httpConfig` | no | Passed through as `AlertmanagerConfig`'s native `HTTPConfig` shape — e.g. `authorization: {credentials: {name, key}}`, `basicAuth`, `tlsConfig`. **Not** the raw Prometheus `http_config` format (no `bearer_token_file`-style paths — see below) |

⚠️ `httpConfig`'s shape changed with the move to `AlertmanagerConfig`: secret
references are now `{name, key}` Secret selectors (same pattern as
`oauth2.clientSecret` in [`OIDC.md`](./OIDC.md) and `pagerdutyConfigs.routingKey`
above), not `_file` paths — so any secret it references must already exist as
a Kubernetes Secret, but does **not** need to be listed under
`alertmanagerSpec.secrets` (the operator resolves it directly). See
[Why file-based secrets, not environment variables](#why-file-based-secrets-not-environment-variables)
above for why secrets can't be passed as literals/env vars in either format.

### Example

```yaml
alertmanager:
  customWebhookEndpoints:
    - url: "https://your-automation.example/hooks/kube-alerts"
      send_resolved: true
    - url: "https://second-endpoint.example/alert"
      send_resolved: false
      httpConfig:
        authorization:
          credentials:
            name: myhook-token
            key: token
```

Which renders (given the receiver logic above) to:

```yaml
route:
  receiver: custom-webhooks
receivers:
  - name: custom-webhooks
    webhookConfigs:
      - url: "https://your-automation.example/hooks/kube-alerts"
        sendResolved: true
      - url: "https://second-endpoint.example/alert"
        sendResolved: false
        httpConfig:
          authorization:
            credentials:
              name: myhook-token
              key: token
```
