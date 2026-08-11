# Grafana SSO (Zitadel OIDC via `auth.generic_oauth`)

How Grafana authenticates browser logins against Zitadel, and how the client
credentials get from Terraform to the pod. This is the **second** OIDC
integration in this chart and should not be confused with the first:

| | This document | [`OIDC.md`](./OIDC.md) |
|---|---|---|
| Component | Grafana | Alertmanager |
| Flow | authorization code (interactive browser login) | client credentials (machine-to-machine) |
| Zitadel app | `grafana` (platform project) | `workquark-alertmanager` machine user (alarmify project) |
| Vault source | `alarmify/management/zitadel` (Terraform-owned) | `alarmify/management/alertmanager-oauth` (hand-seeded) |
| Secret | `grafana-oidc` | `alarmify-oauth` |

## ⚠️ Blocked upstream: nobody can log in yet

The Zitadel side is wired, but **logins will be refused** until a pre-existing
blocker in `alarmify-common-infra` is cleared. The `platform` project sets
`has_project_check = true`, meaning only users holding a grant on that project
may authorize its apps — and `zitadel_user_grant.platform_operators` is
**commented out** in `main.tf`, so nobody holds one.

Kiali has been in this state since 2026-07-28 and its SSO is non-functional for
the same reason; Grafana joins it. Zitadel rejects the authorization request on
its own error page, before Grafana is ever redirected to, so **nothing appears
in Grafana's logs** — it looks like the chart config is wrong when it isn't.

Clearing it is a Terraform-side task with an open design decision (which login
identity to standardise on, and how the initial credential is delivered) —
see "Platform operator grants (disabled)" in
`alarmify-common-infra/terraform/zitadel/README.md`. Everything below is
correct and ready the moment a grant exists.

## Overview

Grafana's built-in `generic_oauth` provider points at the public Zitadel
issuer. A user hitting `http://grafana.jrclabs.xyz` gets a "Sign in with
Zitadel" button; the browser completes the code flow against
`zitadel.jrclabs.xyz` and lands back on the LAN hostname. Both hostnames
work in the same flow because the browser is on the LAN while the redirect
target is LAN-only — only Grafana's own server-side token exchange leaves the
cluster, and it goes to the public issuer.

The local Grafana admin account is deliberately **left enabled**. See
[Roles](#roles-every-sso-user-is-a-viewer) for why that matters.

## The Zitadel app lives in Terraform

`zitadel_application_oidc.grafana` in
`alarmify-common-infra/terraform/zitadel/main.tf`, in the **platform** project
next to Kiali (that project holds admin/ops tooling, not tenant-facing apps).
`vault.tf` mirrors both halves of the credential into the Terraform-owned
Vault object:

```hcl
ZITADEL_GRAFANA_CLIENT_ID     = zitadel_application_oidc.grafana.client_id
ZITADEL_GRAFANA_CLIENT_SECRET = zitadel_application_oidc.grafana.client_secret
```

Zitadel returns a client secret exactly once, at creation — that mirror is the
only durable copy outside Terraform state, and it is why the app must not be
created by hand in the UI.

### `redirect_uris` is not free-form

Grafana fixes its own callback path. The Terraform local is:

```hcl
grafana_redirect_uris = ["http://grafana.jrclabs.xyz/login/generic_oauth"]
```

`/login/generic_oauth` is Grafana's, not ours, and the host half must equal
`server.root_url` in `grafana.ini` — Grafana builds the `redirect_uri` it
sends to Zitadel from `root_url`, and Zitadel rejects any value not on the
registered list. Change the hostname in one place and the login breaks with a
Zitadel-side redirect-URI error, which does **not** appear in Grafana's logs.

## `values.yaml`: `grafana.alarmifyOidc`

Only the ExternalSecret wiring is configurable here:

```yaml
grafana:
  alarmifyOidc:
    externalSecret:
      secretStore: vault-secretstore
      refreshInterval: 1h
      vaultPath: alarmify/management/zitadel
      secretName: grafana-oidc
      clientIdProperty: ZITADEL_GRAFANA_CLIENT_ID
      clientSecretProperty: ZITADEL_GRAFANA_CLIENT_SECRET
```

The endpoint URLs are **not** templated from this block — they are literal
values under `grafana.ini` below, because `grafana.ini` is consumed directly by
the upstream subchart and never passes through this wrapper's templates.

There is intentionally **no `enabled` toggle.** `envValueFrom` is subchart
values, so it cannot be made conditional on a wrapper flag; a toggle would
disable the ExternalSecret while leaving Grafana's env pointed at a Secret that
no longer exists, and the pod would sit in `CreateContainerConfigError`. To
actually turn SSO off, remove the `alarmifyOidc`, `envValueFrom`, and
`grafana.ini.auth.generic_oauth` blocks together.

## `templates/grafana-oidc-external-secret.yaml`

Syncs both properties into the `grafana-oidc` Secret, one `data[]` entry each:

```yaml
  data:
    - secretKey: client-id
      remoteRef:
        key: "alarmify/management/zitadel"
        property: ZITADEL_GRAFANA_CLIENT_ID
    - secretKey: client-secret
      remoteRef:
        key: "alarmify/management/zitadel"
        property: ZITADEL_GRAFANA_CLIENT_SECRET
```

`data[]` (named properties), never `dataFrom`/`extract`. That Vault object is
Terraform-owned and shared by every Zitadel consumer — extracting it would drop
the UI client id, the identity-api machine key, the action signing key and
Kiali's secret into this namespace as well.

The client id is not sensitive and could have been inlined as a plain value.
It is delivered through the same Secret anyway so that both halves rotate
together: recreating the Zitadel app changes the id *and* the secret, and a
hardcoded id would then silently disagree with the synced secret.

`sync-wave: "-1"` puts the ExternalSecret ahead of the Grafana Deployment.
Argo CD does not wait for ESO to *materialise* the Secret, so on a first
install the Grafana pod can still start before it exists and sit in
`CreateContainerConfigError` for a reconcile or two. That resolves itself; it
is not a misconfiguration.

## `grafana.ini` and the client secret

The credential reaches Grafana as environment variables, not as ini values:

```yaml
grafana:
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

Grafana's `GF_<SECTION>_<KEY>` env vars override the corresponding ini setting,
so `client_id`/`client_secret` never appear under `auth.generic_oauth` at all.
That is load-bearing: `grafana.ini` is rendered into a **ConfigMap**, and the
upstream chart's `assertNoLeakedSecrets` check fails the render outright if a
secret-shaped value shows up there.

Note this is not the pattern CLAUDE.md warns about ("never shadow Vault with a
literal `env`") — the danger there is a *literal* env value outranking
External Secrets. Here the env value is itself sourced from the ESO-managed
Secret, so there is exactly one source of truth.

The rest of the provider config:

```yaml
grafana.ini:
  server:
    root_url: http://grafana.jrclabs.xyz
  auth.generic_oauth:
    enabled: true
    name: Zitadel
    scopes: openid profile email offline_access
    auth_url: https://zitadel.jrclabs.xyz/oauth/v2/authorize
    token_url: https://zitadel.jrclabs.xyz/oauth/v2/token
    api_url: https://zitadel.jrclabs.xyz/oidc/v1/userinfo
    use_pkce: true
    use_refresh_token: true
```

### Issuer host requirement

Same constraint as [`OIDC.md`](./OIDC.md#issuer-host-requirement): the endpoints
must be `zitadel.jrclabs.xyz`, the **public** domain, not `zitadel.home.arpa`.
Zitadel derives a token's `iss` from the request host, and the public name is
also the only one with a publicly trusted (Cloudflare edge) certificate — so
Grafana needs no custom CA to complete the token exchange.

### `offline_access` and `use_refresh_token` go together

`use_refresh_token: true` is what stops users being bounced back to Zitadel
when the access token expires. It needs both the `offline_access` scope
(requested above) and `OIDC_GRANT_TYPE_REFRESH_TOKEN` in the Terraform app's
`grant_types` — which is the one place this chart's config and the Terraform
must agree beyond the redirect URI.

## Roles: every SSO user is a Viewer

```yaml
role_attribute_path: "'Viewer'"
role_attribute_strict: true
allow_assign_grafana_admin: false
```

`'Viewer'` is a JMESPath **string literal**, not a claim lookup — it evaluates
to `Viewer` for everyone regardless of token contents. That is deliberate:
the platform project sets `project_role_assertion = false` and the Grafana app
sets both `*_role_assertion = false`, so no Zitadel role reaches the token.
A claim-based path would evaluate to null for every user, and with
`role_attribute_strict: true` that means **login refused**.

Admin access therefore stays on the local Grafana admin account, which is why
the login form is not disabled.

To promote SSO users to real roles, all three of these must change together:

1. `project_role_assertion = true` on `zitadel_project.platform`, and
   `id_token_role_assertion = true` on `zitadel_application_oidc.grafana`.
2. Grant the roles to users (the `platform_operators` grant in `main.tf` is
   currently commented out — see that repo's README).
3. Replace `role_attribute_path` with a real lookup against
   `urn:zitadel:iam:org:project:roles`.

Doing 3 without 1 and 2 locks everyone out.

## Setup / rotating the client secret

The credential is Terraform-owned; there is no `vault kv put` step.

```bash
cd alarmify-common-infra/terraform/zitadel
terraform apply                       # creates the app, writes both keys to Vault
kubectl -n kube-prometheus-stack get secret grafana-oidc
```

To rotate, taint and re-apply the app, then force the sync rather than waiting
out `refreshInterval`:

```bash
terraform taint zitadel_application_oidc.grafana && terraform apply
kubectl -n kube-prometheus-stack annotate externalsecret grafana-oidc \
  force-sync=$(date +%s) --overwrite
kubectl -n kube-prometheus-stack rollout restart deploy/kube-prometheus-stack-grafana
```

The restart is required — Grafana reads `GF_*` env vars once at startup.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Grafana pod stuck in `CreateContainerConfigError` | `grafana-oidc` Secret absent — check `kubectl -n kube-prometheus-stack describe externalsecret grafana-oidc`; usually Terraform hasn't been applied, so the Vault properties don't exist |
| Zitadel error page, never returns to Grafana | Either the `platform` project grant is still missing (see [the blocker](#️-blocked-upstream-nobody-can-log-in-yet) — this is the current state) or the registered `redirect_uris` doesn't match `root_url` + `/login/generic_oauth`. Neither is visible in Grafana's logs |
| "login provider denied login request" | `role_attribute_path` evaluated to null with `role_attribute_strict: true` — see [Roles](#roles-every-sso-user-is-a-viewer) |
| Token exchange fails with a TLS error | Endpoints point at `zitadel.home.arpa` (stepca cert) instead of the public domain |
| Users re-authenticate constantly | `offline_access` scope or the refresh-token grant missing on the Zitadel app |
| Render fails on `assertNoLeakedSecrets` | A secret value was added under `grafana.ini` instead of being passed via `envValueFrom` |
