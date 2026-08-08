# Alertmanager OIDC (OAuth2 client-credentials) integration

How Alertmanager authenticates to the Alarmify ingest-api webhook using
short-lived Zitadel-issued tokens. For the Vault layout shared by all five
Zitadel consumers, see
[`ZITADEL-AUTH-SECRETS.md`](https://github.com/Alarmify/alarmify-docs/blob/main/docs/auth/zitadel-auth-secrets.md); for
the domain/issuer layout, see
[`ZITADEL-PUBLIC-EXPOSURE.md`](https://github.com/Alarmify/alarmify-docs/blob/main/docs/auth/zitadel-public-exposure.md).

## Overview

The `alarmify` Alertmanager receiver (this chart) posts webhook
notifications to the in-cluster ingest-api, authenticated via
`alertmanager.alarmifyOauth` — OAuth2 client credentials against a Zitadel
machine user. This is the **only** ingestion auth mechanism; it is not
gated behind a toggle. No long-lived secret exists anywhere in this flow:
only the OAuth2 client secret, which is used solely to mint short-lived
tokens that Alertmanager fetches and refreshes itself.

The whole base config (this receiver plus routing/inhibition) is rendered as
an **`AlertmanagerConfig` object**, not a `Secret` — see
[Config mechanism: AlertmanagerConfig, not a Secret](#config-mechanism-alertmanagerconfig-not-a-secret)
below for why and how that works.

## Token flow

1. Before delivering a webhook, Alertmanager's `httpConfig.oauth2` transport
   requests (or reuses a cached) token from Zitadel's token endpoint using
   the `client_credentials` grant — client id + client secret.
2. Zitadel issues a JWT with `iss` derived from the **request host** (so the
   configured `tokenUrl` determines the issuer the token carries) and `aud`
   set from the requested scope.
3. Alertmanager attaches `Authorization: Bearer <token>` to the webhook POST.
4. ingest-api verifies the token against Zitadel's JWKS
   (`https://zitadel.workquark.org/.well-known/openid-configuration`),
   checks `iss`/`aud`, and derives tenant identity from the token claims.

## Config mechanism: AlertmanagerConfig, not a Secret

The base Alertmanager config used to be a hand-built `alertmanager.yaml`
string inside a `Secret`, referenced via `alertmanagerSpec.configSecret`.
It's now a native **`AlertmanagerConfig`** custom resource
(`monitoring.coreos.com/v1alpha1` — the only version this chart's bundled
prometheus-operator, v0.86.1, serves for this CRD), referenced as the
**global root config** via `alertmanagerSpec.alertmanagerConfiguration.name`:

```yaml
alertmanager:
  alertmanagerSpec:
    useExistingSecret: true   # stop the upstream chart from rendering its own default Secret
    alertmanagerConfiguration:
      name: alarmify-alertmanager-config
      global:
        resolveTimeout: 5m
```

Per the `Alertmanager` CRD: *"If defined, [`alertmanagerConfiguration`] takes
precedence over the `configSecret` field"* — so no `configSecret` is set at
all. This is a **different mechanism** from
`alertmanagerSpec.alertmanagerConfigSelector` (also present in `values.yaml`,
currently unused): that one *merges* labeled `AlertmanagerConfig` objects as
**child routes** under an existing root config, and by default restricts
each to alerts from its own namespace. The global mechanism above instead
makes **one** `AlertmanagerConfig` *be* the entire root config — no separate
Secret needed, and per the CRD, *"the operator will not enforce a `namespace`
label for routes and inhibition rules"* on it. That's the one this repo's
default (cluster-wide, not namespace-scoped) routing needs.

⚠️ This is marked **experimental** upstream — the CRD says it *"may change in
any upcoming release in a breaking way."*

### Why no more `alertmanagerSpec.secrets` mount

Previously, `client_secret_file` pointed at a path from a Secret manually
listed in `alertmanagerSpec.secrets`, because the raw Alertmanager config
format has no other way to reference a Kubernetes Secret. `AlertmanagerConfig`
objects don't have that limitation — `oauth2.clientSecret` is a native
`{name, key}` Secret reference, and the operator resolves and mounts it
itself. Nothing needs to be listed under `alertmanagerSpec.secrets` for this
receiver anymore.

## `values.yaml`: `alertmanager.alarmifyOauth`

The actual current block:

```yaml
alertmanager:
  alarmifyOauth:
    # workquark tenant integration account (machine user workquark-alertmanager)
    clientId: "workquark-alertmanager"
    # terraform output -raw project_id — also the aud claim from project:aud scope
    projectId: "383904466425938149"
    tokenUrl: "https://zitadel.workquark.org/oauth/v2/token"
    externalSecret:
      secretStore: vault-secretstore
      vaultPath: alarmify/management/alertmanager-oauth   # field: client-secret only
```

| Field | Meaning | Source |
|---|---|---|
| `clientId` | Zitadel machine-user client id — **not** a secret | UI → Settings → API tokens → integration account (shown at creation) |
| `projectId` | Alarmify Zitadel project id → becomes the `aud` claim via `urn:zitadel:iam:org:project:id:<id>:aud` — **not** a secret | `alarmify-common-infra` `terraform output -raw project_id` |
| `tokenUrl` | Token endpoint | Must be the **public** issuer domain — see [Issuer host requirement](#issuer-host-requirement) below |
| `externalSecret.vaultPath` | Vault path holding `client-secret` | `alarmify/management/alertmanager-oauth` |

Only the client secret itself (Vault → `alarmify-oauth` Secret →
`client-secret` key) is sensitive; nothing above is.

### Both of these were wrong until 2026-08-01, and it took the whole cluster's alerting down

`projectId` was `380619948738806915` and `vaultPath` was
`alarmify/prod/alertmanager-oauth`. Neither survived the Zitadel/Vault rebuild:
the current project generation is `383904466425938149`, and Vault has no `prod`
environment at all — only `dev`, `local`, and `management` (this chart runs on
management). The failure chain, worth understanding because none of it is
obvious from the symptom:

1. The Vault path didn't exist → the `alarmify-oauth` ExternalSecret failed
   every reconcile for six days (`Secret does not exist`).
2. → the `alarmify-oauth` Secret was never created.
3. → prometheus-operator could not resolve `oauth2.clientSecret` in the global
   `AlertmanagerConfig` and **failed the entire Alertmanager reconcile**:
   `provision alertmanager configuration: failed to initialize from global
   AlertmanagerConfig`.
4. → **no StatefulSet and no Alertmanager pod were ever created.**
5. → `vmalert` — the only alert evaluator since the VictoriaMetrics cutover —
   had nowhere to deliver, and every alert in the cluster was dropped with
   `connection refused` for ~7 days.

Two lessons encoded here. First, a missing Vault key under the
`AlertmanagerConfig` mechanism is **fatal to the whole Alertmanager**, not just
to one receiver — the old `configSecret` mechanism would have left Alertmanager
running and failing deliveries, which is far more visible. Second, this chart's
own `AlarmifyWebhookDeliveryFailing` rules cannot catch it: they route *through*
the Alertmanager that is missing. Check `kubectl -n kube-prometheus-stack get
alertmanager` for `Reconciled`, not just pod health.

### `clientId` needs a ConfigMap — it can't be inlined

`AlertmanagerConfig`'s `oauth2.clientId` only accepts a Secret/ConfigMap key
reference, unlike the old raw-config format where it was a plain string.
Since `clientId` isn't sensitive, `templates/alertmanager-config.yaml` also
renders a small `ConfigMap` for it:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: alarmify-oauth-client-id
  namespace: {{ .Release.Namespace }}
data:
  client-id: {{ $oauth.clientId | quote }}
```

## `templates/alertmanager-config.yaml` — the rendered receiver

The relevant part of the `alarmify` receiver, as an `AlertmanagerConfig`
receiver entry:

```yaml
receivers:
  - name: "alarmify"
    webhookConfigs:
      - url: "http://local-alarmify-ingest-api-prod.alarmify-ingest-api.svc/api/v1/alerts/prometheus"
        sendResolved: true
        httpConfig:
          oauth2:
            clientId:
              configMap:
                name: alarmify-oauth-client-id
                key: client-id
            clientSecret:
              name: alarmify-oauth
              key: client-secret
            tokenUrl: {{ $oauth.tokenUrl | quote }}
            scopes:
              - openid
              - "urn:zitadel:iam:org:project:id:{{ $oauth.projectId }}:aud"
```

Which, with the current values, renders to:

```yaml
httpConfig:
  oauth2:
    clientId:
      configMap:
        name: alarmify-oauth-client-id
        key: client-id
    clientSecret:
      name: alarmify-oauth
      key: client-secret
    tokenUrl: "https://zitadel.workquark.org/oauth/v2/token"
    scopes:
      - openid
      - "urn:zitadel:iam:org:project:id:383904466425938149:aud"
```

`clientSecret: {name: alarmify-oauth, key: client-secret}` is a direct
reference to the `alarmify-oauth` Secret — the operator reads it via the
Kubernetes API and injects the resolved value into the generated Alertmanager
config it manages internally; no file path bookkeeping needed on our side.

## `templates/alarmify-oauth-external-secret.yaml` — syncing the secret from Vault

Unchanged by the `AlertmanagerConfig` migration — still an `ExternalSecret`
syncing `alarmify-oauth` (namespace `kube-prometheus-stack`) from Vault, one
field (`client-secret`) only:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: alarmify-oauth
  namespace: {{ .Release.Namespace }}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: {{ $oauth.externalSecret.secretStore | default "vault-secretstore" }}
    kind: ClusterSecretStore
  target:
    name: alarmify-oauth
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: client-secret
      remoteRef:
        key: {{ $oauth.externalSecret.vaultPath | quote }}
        property: client-secret
```

`ca.crt` is intentionally **not** synced here — see
[Issuer host requirement](#issuer-host-requirement): the token endpoint has a
publicly trusted certificate, so no `tlsConfig.ca` is needed.

### Issuer host requirement

Zitadel derives a token's `iss` claim from the host the request was made to,
not from static config. `tokenUrl` must therefore be
`https://zitadel.workquark.org/oauth/v2/token` (the public domain) — pointing
it at `zitadel.home.arpa` would mint tokens with the wrong issuer and
ingest-api's JWKS check would reject them. See
[`ZITADEL-PUBLIC-EXPOSURE.md`](https://github.com/Alarmify/alarmify-docs/blob/main/docs/auth/zitadel-public-exposure.md)
for why the two domains exist.

Because `tokenUrl` is the public domain, its certificate is publicly trusted
(Cloudflare edge) — no `oauth2.tlsConfig.ca` is needed or set. Adding one
would *replace* the system trust pool rather than extend it; only add it if
this ever points back at the stepca-certed LAN hostname.

## Setup / rotating the client secret

1. Store the client secret in Vault:
   ```bash
   vault kv put kv/alarmify/management/alertmanager-oauth \
     client-secret='<integration-account client secret (shown once in UI)>'
   ```
2. Confirm the ExternalSecret has synced:
   ```bash
   kubectl -n kube-prometheus-stack get secret alarmify-oauth
   ```

That's it — no `alertmanagerSpec.secrets` entry to add or verify; the
`AlertmanagerConfig`'s `clientSecret` reference is enough.

Rotating the secret is the same procedure — `vault kv put` overwrites the
Vault value, and the ExternalSecret's `refreshInterval: 1h` picks it up on
its own within an hour (or force it sooner: `kubectl -n kube-prometheus-stack
annotate externalsecret alarmify-oauth force-sync=$(date +%s) --overwrite`).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Alertmanager pod running but using an empty/fallback config | `alarmify-alertmanager-config` `AlertmanagerConfig` failed validation or wasn't found — check `kubectl -n kube-prometheus-stack describe alertmanagerconfig alarmify-alertmanager-config` and the prometheus-operator logs |
| Token request fails (visible in Alertmanager logs as delivery errors) | Wrong `clientId` (check the `alarmify-oauth-client-id` ConfigMap), or `client-secret` in Vault/the `alarmify-oauth` Secret doesn't match the integration account |
| ingest-api returns 401/403 on the webhook call | `tokenUrl` isn't the public issuer domain (issuer mismatch), or `projectId` is wrong (aud mismatch) |
| Alerts stop arriving in Alarmify with no obvious error | Check the `AlarmifyWebhookDeliveryFailing` / `AlarmifyWebhookDeliveryStalled` PrometheusRules (`templates/alarmify-ingestion-prometheusrule.yaml`) — they exist specifically to catch a broken ingestion credential, which otherwise fails silently |

## Why file-based, not env vars

Alertmanager does **not** expand environment variables in its config file —
this is why `AlertmanagerConfig` (and, before it, the raw config format)
reference secrets by Secret/key rather than accepting a literal `$VAR`:

```yaml
httpConfig:
  oauth2:
    clientSecret: $CLIENT_SECRET   # not how this works — no env var expansion
```

vs. the actual (correct) reference:

```yaml
httpConfig:
  oauth2:
    clientSecret:
      name: alarmify-oauth
      key: client-secret
```

The operator resolves the reference and passes Alertmanager the value via a
file it manages — same underlying mechanism as before, just no longer
something we have to wire up by hand via `alertmanagerSpec.secrets`.
