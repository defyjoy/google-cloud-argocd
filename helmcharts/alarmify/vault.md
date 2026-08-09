# Vault commands — `alarmify-*` apps

All `vault` CLI commands needed to populate the secrets that the `alarmify-*` ArgoCD
apps consume, one section per app, with the environment-variable keys each object
must contain and their values (real values where fixed, `REPLACE_WITH_*` placeholders
for anything secret).

Grounded in the live charts under `helmcharts/alarmify/*` (the `ExternalSecret`
templates + `values.yaml`) and cross-referenced with the field-level schema docs in
`alarmify-docs/docs/vault/alarmify-secrets/`.

---

## How the secrets are wired

| Fact | Value |
|---|---|
| KV engine | KV **v2**, mounted at **`kv`** |
| Store (in cluster) | `ClusterSecretStore/vault-secretstore` → `http://local-vault.vault.svc.cluster.local:8200` |
| Store (dev override) | `https://vault.jrclabs.xyz` (`helmcharts/external-secrets/values/dev.yaml`) |
| CLI endpoint | `export VAULT_ADDR="https://vault.jrclabs.xyz"` |
| Live path prefix | **`alarmify/dev/*`** — every chart's `appVarsKeys` points here today |
| Legacy prefix | `alarmify/prod/*` — original source-of-truth tree (apps ran on `management`); still exists, no chart reads it now |

Each app's `ExternalSecret` uses `dataFrom.extract` — it copies **every field** of the
listed Vault object(s) into one Kubernetes `Secret` (`<app>-vars`), consumed via `envFrom`.
Where two objects are listed, `mergePolicy: Replace` means the object listed **last**
(the shared `postgres/credentials`) wins on any overlapping key.

> **KV v2 path note:** in manifests the path is logical (`alarmify/dev/...`). On the CLI you
> prefix the mount: `vault kv get kv/alarmify/dev/...`.

---

## Prerequisites (run once per shell)

```bash
export VAULT_ADDR="https://vault.jrclabs.xyz"
vault login          # or: export VAULT_TOKEN=...
vault token lookup   # sanity check
```

List the tree before touching anything:

```bash
vault kv list kv/alarmify            # -> dev/  prod/
vault kv list kv/alarmify/dev        # the live objects
vault kv list kv/alarmify/prod       # legacy source objects
```

---

## `alarmify-identity-api`

- **Namespace / K8s Secret:** `alarmify-identity-api` / `alarmify-identity-api-vars`
- **Vault objects (in order):** `alarmify/dev/alarmify-identity-api`, then shared `alarmify/dev/postgres/credentials`
- `values/dev.yaml` sets `dbHostOverride: postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local` (injected literally, overrides Vault `DB_HOST`).

| Key | Value | Notes |
|---|---|---|
| `AUTH_MODE` | `zitadel` | `legacy` \| `zitadel` \| `dual` (cutover) |
| `ZITADEL_ISSUER` | `https://zitadel.jrclabs.xyz` | JWKS verification + mgmt API |
| `ZITADEL_AUDIENCE` | `380619948738806915` | expected `aud` (client_id / project_id) |
| `ZITADEL_PROJECT_ID` | `380619948738806915` | Alarmify project |
| `ZITADEL_PROJECT_ORG_ID` | `REPLACE_WITH_ORG_ID` | org owning the project |
| `ZITADEL_ACTION_SIGNING_KEY` | `REPLACE_WITH_SIGNING_KEY` | verifies Zitadel Actions v2 calls; empty skips (dev only) |
| `ZITADEL_PROVISIONER_KEY_JSON` | `REPLACE_WITH_SA_KEY_JSON` | machine-key JSON for `identity-api-provisioner` |

```bash
vault kv put kv/alarmify/dev/alarmify-identity-api \
  AUTH_MODE='zitadel' \
  ZITADEL_ISSUER='https://zitadel.jrclabs.xyz' \
  ZITADEL_AUDIENCE='380619948738806915' \
  ZITADEL_PROJECT_ID='380619948738806915' \
  ZITADEL_PROJECT_ORG_ID='REPLACE_WITH_ORG_ID' \
  ZITADEL_ACTION_SIGNING_KEY='REPLACE_WITH_SIGNING_KEY' \
  ZITADEL_PROVISIONER_KEY_JSON='REPLACE_WITH_SA_KEY_JSON'
```

> Postgres `DB_*` come from the shared object below (this app's own object historically
> also carries `DB_*`, but the shared object wins per `mergePolicy: Replace`).

---

## `alarmify-incident-api`

- **Namespace / K8s Secret:** `alarmify-incident-api` / `alarmify-incident-api-vars`
- **Vault objects:** `alarmify/dev/alarmify-incident-api`, then shared `alarmify/dev/postgres/credentials`
- `ZITADEL_ISSUER` / `ZITADEL_AUDIENCE` are also set in chart `values.yaml`; Vault can supply them too.
- `values/dev.yaml` sets `dbHostOverride: postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local`.

| Key | Value | Notes |
|---|---|---|
| `ZITADEL_ISSUER` | `https://zitadel.jrclabs.xyz` | JWKS verification |
| `ZITADEL_AUDIENCE` | `380619948738806915` | expected `aud` |

```bash
vault kv put kv/alarmify/dev/alarmify-incident-api \
  ZITADEL_ISSUER='https://zitadel.jrclabs.xyz' \
  ZITADEL_AUDIENCE='380619948738806915'
```

> Postgres `DB_*` come from the shared object. Without `DB_HOST`/`DB_PASSWORD` the app
> defaults to `localhost:5432` and `GET /api/v1/incidents` returns 500.

---

## `alarmify-schedule-api`

- **Namespace / K8s Secret:** `alarmify-schedule-api` / `alarmify-schedule-api-vars`
- **Vault objects:** `alarmify/dev/alarmify-schedule-api` (app-specific, may be empty), then shared `alarmify/dev/postgres/credentials`
- `values/dev.yaml` sets `dbHostOverride: postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local`.

No app-specific keys required today — all config is Postgres, supplied by the shared object.
Create/keep the object (empty or with future keys):

```bash
vault kv put kv/alarmify/dev/alarmify-schedule-api
```

> Without `DB_HOST`/`DB_PASSWORD` (shared object), schedule API routes return 500.

---

## `alarmify-event-worker`

- **Namespace / K8s Secret:** `alarmify-event-worker` / `alarmify-event-worker-vars`
- **Vault objects:** `alarmify/dev/alarmify-event-worker`, then shared `alarmify/dev/postgres/credentials`
- `values/dev.yaml` sets `dbHostOverride: postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local` and NATS URL `nats://dev-nats.nats.svc.cluster.local:4222`.

| Key | Value | Notes |
|---|---|---|
| `NATS_USER` | `alarmify-event-processor` | must match account in `helmcharts/nats/values.yaml`; falls back to `NATS_USERNAME` |
| `NATS_PASSWORD` | `REPLACE_WITH_STRONG_PASSWORD` | paired with `NATS_USER` |

```bash
vault kv put kv/alarmify/dev/alarmify-event-worker \
  NATS_USER='alarmify-event-processor' \
  NATS_PASSWORD='REPLACE_WITH_STRONG_PASSWORD'
```

> Also needs the `ALARMIFY_EVENTS_RAW` stream + `alarmify-event-processor` durable
> consumer to pre-exist on dev's NATS (not chart-managed). Postgres `DB_*` come from the
> shared object.

---

## `alarmify-ingest-api`

- **Namespace / K8s Secret:** `alarmify-ingest-api` / `alarmify-ingest-api-vars`
- **Vault objects:** `alarmify/dev/alarmify-ingest-api` only (**no** shared postgres — this app has no Postgres dependency).
- `ZITADEL_ISSUER` / `ZITADEL_AUDIENCE` are set in chart `values.yaml`; Vault may also carry them.
- `values/dev.yaml` sets `dbHostOverride: postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local`, which forces the ES to `mergePolicy: Merge` and injects a literal `DB_HOST` (unrelated to the unused legacy `DB_*` below).

| Key | Value | Notes |
|---|---|---|
| `NATS_USER` | `alarmify-ingest-api` | publishes raw ingest events to dev's local NATS |
| `NATS_PASSWORD` | `REPLACE_WITH_STRONG_PASSWORD` | publish-connection password |
| `ZITADEL_ISSUER` | `https://zitadel.jrclabs.xyz` | JWKS verification |
| `ZITADEL_AUDIENCE` | `380619948738806915` | expected `aud` |

```bash
vault kv put kv/alarmify/dev/alarmify-ingest-api \
  NATS_USER='alarmify-ingest-api' \
  NATS_PASSWORD='REPLACE_WITH_STRONG_PASSWORD' \
  ZITADEL_ISSUER='https://zitadel.jrclabs.xyz' \
  ZITADEL_AUDIENCE='380619948738806915'
```

> This object may still carry legacy `DB_*` keys — **not read** by the app and not merged
> by the chart. Harmless; safe to prune.

---

## `alarmify-ui`

- **Namespace / K8s Secret:** `alarmify-ui` / `alarmify-ui-vars`
- **Vault object:** `alarmify/dev/alarmify-ui` only (no Postgres).
- **Seeded by** `alarmify-common-infra/terraform/zitadel` (Terraform normally writes these).

| Key | Value | Notes |
|---|---|---|
| `SESSION_SECRET` | `REPLACE_WITH_STRONG_RANDOM` | derives AES-256-GCM key for the httpOnly session cookie; **must** be set for real deploys |
| `ZITADEL_ISSUER` | `https://zitadel.jrclabs.xyz` | OIDC discovery base |
| `ZITADEL_CLIENT_ID` | `REPLACE_WITH_PKCE_CLIENT_ID` | public PKCE client for the BFF login flow |
| `ZITADEL_PROJECT_ID` | `380619948738806915` | scopes hosted login to the Alarmify project |

```bash
vault kv put kv/alarmify/dev/alarmify-ui \
  SESSION_SECRET='REPLACE_WITH_STRONG_RANDOM' \
  ZITADEL_ISSUER='https://zitadel.jrclabs.xyz' \
  ZITADEL_CLIENT_ID='REPLACE_WITH_PKCE_CLIENT_ID' \
  ZITADEL_PROJECT_ID='380619948738806915'
```

---

## Shared: `postgres/credentials`

- **Vault object:** `alarmify/dev/postgres/credentials`
- **Consumed by:** identity-api, incident-api, schedule-api, event-worker, ingest-api (second
  `appVarsKeys` entry; wins on overlapping `DB_*` keys). **Not** used by ui.
- One object so the Postgres password / host is rotated in a single place.

| Key | Value | Notes |
|---|---|---|
| `DB_HOST` | `pg-egress-bridge.pg-egress-bridge.svc.cluster.local` | cross-cluster bridge value for dev. **Overridden per-app** in `values/dev.yaml` via `dbHostOverride` → `postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local` (Istio ambient global-service path). Never the LAN host `cloudnative-postgres.home.arpa`. |
| `DB_PORT` | `5432` | |
| `DB_USER` | `postgres` | |
| `DB_PASSWORD` | `REPLACE_WITH_STRONG_PASSWORD` | |
| `DB_NAME` | `alarmify` | |
| `DB_SSLMODE` | `disable` | use `require`/`verify-full` under TLS in prod |
| `DB_TIMEZONE` | `UTC` | |

```bash
vault kv put kv/alarmify/dev/postgres/credentials \
  DB_HOST='pg-egress-bridge.pg-egress-bridge.svc.cluster.local' \
  DB_PORT='5432' \
  DB_USER='postgres' \
  DB_PASSWORD='REPLACE_WITH_STRONG_PASSWORD' \
  DB_NAME='alarmify' \
  DB_SSLMODE='disable' \
  DB_TIMEZONE='UTC'
```

> Because each Postgres-dependent chart sets `dbHostOverride` in `values/dev.yaml`, the
> injected literal `DB_HOST` supersedes whatever this object holds — so the effective host
> in dev is `postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local`.

---

## Shared: Harbor image-pull credentials

All alarmify workloads pull with the **same** Vault object, into a per-namespace
`imagePullSecret` (`harbor-registry-credentials` ES → `<app>-registry` Secret).

- **Vault object:** `alarmify/dev/harbor` (field `.dockerconfigjson`)
- **Robot account source:** `harbor/secret` (fields `user`, `token`)
- **Registry:** `harbor.jrclabs.xyz` (namespace `alarmify`)
- **ES → Secret:** each chart's `templates/harbor-registry-external-secret.yaml` copies the
  single field `.dockerconfigjson` verbatim into `<app>-registry`
  (`type: kubernetes.io/dockerconfigjson`), referenced by `imagePullSecrets` in `values.yaml`.

> **Store raw JSON, not base64.** External Secrets base64-encodes the value when it writes
> the Kubernetes `Secret`. If you pre-encode it in Vault it gets encoded twice and every pod
> fails with `ImagePullBackOff` / `couldn't parse image reference` on the pull secret.

### 1. Generate `dockerconfig.json`

Both the bare host and the `https://` form are included — containerd matches the bare host,
while `docker login` / older tooling writes the `https://` key, so carrying both makes the
same object usable from either path.

> **Quoting: Harbor robot names contain `$`.** Always source them via command substitution
> as below — `$(...)` assigns verbatim. If you ever type one by hand, use **single** quotes
> (`'robot$alarmify+puller'`); in double quotes the shell expands `$alarmify` to empty and
> Harbor rejects the login. Prefer sourcing from Vault regardless, so the token never lands
> in your shell history.

```bash
export VAULT_ADDR="https://vault.jrclabs.xyz"
HARBOR_USER=$(vault kv get -field=user  kv/harbor/secret)
HARBOR_TOKEN=$(vault kv get -field=token kv/harbor/secret)

# `auth` is base64("user:token") — tr strips the newline GNU base64 adds.
AUTH=$(printf '%s:%s' "$HARBOR_USER" "$HARBOR_TOKEN" | base64 | tr -d '\n')

jq -n --arg u "$HARBOR_USER" --arg p "$HARBOR_TOKEN" --arg a "$AUTH" '
  { auths:
      ( ["harbor.jrclabs.xyz", "https://harbor.jrclabs.xyz"]
        | map({ (.): { username: $u, password: $p, auth: $a } })
        | add ) }' > dockerconfig.json
```

<details>
<summary>Alternative: let <code>kubectl</code> build it (single host only)</summary>

`--dry-run=client` contacts no cluster; nothing is created. Some interactive zsh setups
mangle pasted `\`-continuations (`parse error near '\n'`) — if that happens, paste the
one-line form below instead.

```bash
kubectl create secret docker-registry tmp-harbor --docker-server=harbor.jrclabs.xyz --docker-username="$HARBOR_USER" --docker-password="$HARBOR_TOKEN" --dry-run=client -o go-template='{{index .data ".dockerconfigjson"}}' | base64 -d > dockerconfig.json
```
</details>

### 2. Sanity-check before writing

```bash
jq -e '.auths | keys' dockerconfig.json                       # both hosts present
jq -r '.auths["harbor.jrclabs.xyz"].auth' dockerconfig.json | base64 -d   # -> user:token
```

### 3. Write it to Vault

`vault kv put` replaces the whole object; this object holds only this one field, so a plain
put is correct. The `@` prefix makes the CLI read the value from the file.

```bash
vault kv put kv/alarmify/dev/harbor \
  .dockerconfigjson=@dockerconfig.json

shred -u dockerconfig.json 2>/dev/null || rm -f dockerconfig.json
```

### 4. Verify the round-trip

```bash
# Back out of Vault — must be readable JSON, not a base64 blob.
vault kv get -field=.dockerconfigjson kv/alarmify/dev/harbor | jq .

# In-cluster, after ESO syncs (refreshInterval: 1h — force it if you don't want to wait):
kubectl -n alarmify-identity-api annotate externalsecret harbor-registry-credentials \
  force-sync="$(date +%s)" --overwrite
kubectl -n alarmify-identity-api get secret alarmify-identity-api-registry \
  -o go-template='{{index .data ".dockerconfigjson"}}' | base64 -d | jq .
```

On rotation, only this one Vault object changes — all six namespaces pick it up on their next
refresh (or immediately with the `force-sync` annotation above, repeated per namespace).

---

## Legacy: `alarmify-auth-api` (prod only — do not recreate for dev)

Decommissioned 2026-07-07 when Zitadel became the only JWT trust anchor. No chart consumes
it; **do not copy to `alarmify/dev/*`**. Documented for audit history only.

- **Vault object:** `alarmify/prod/alarmify-auth-api`
- Keys: `JWT_PRIVATE_KEY`, `JWT_PUBLIC_KEY`, `JWT_KEY_ID`, `PUBLIC_BASE_URL`,
  `AUTH_API_INTERNAL_KEY`, `APP_BASE_URL`, `RESEND_API_KEY`, `RESEND_FROM`, and the
  standard `DB_*` set.

```bash
# Historical shape (RSA keys as single-line PEM):
pem_oneline() { awk 'NF {sub(/\r/, ""); printf "%s\\n",$0;}' "$1"; }
vault kv put kv/alarmify/prod/alarmify-auth-api \
  JWT_PRIVATE_KEY="$(pem_oneline jwt_private.pem)" \
  JWT_PUBLIC_KEY="$(pem_oneline jwt_public.pem)" \
  JWT_KEY_ID='alarmify-auth-prod-1' \
  PUBLIC_BASE_URL='https://auth.home.arpa' \
  AUTH_API_INTERNAL_KEY='REPLACE_WITH_STRONG_RANDOM'
```

---

## Verify / read back

```bash
# One app
vault kv get kv/alarmify/dev/alarmify-identity-api

# Field names only (no values) for every live object
for p in alarmify-identity-api alarmify-incident-api alarmify-schedule-api \
         alarmify-event-worker alarmify-ingest-api alarmify-ui; do
  echo "=== alarmify/dev/$p ==="
  vault kv get -format=json "kv/alarmify/dev/$p" | jq -r '.data.data | keys | .[]'
done
vault kv get -format=json kv/alarmify/dev/postgres/credentials | jq -r '.data.data | keys | .[]'

# Single field
vault kv get -field=NATS_USER kv/alarmify/dev/alarmify-ingest-api
```

---

## Bulk: copy `prod` → `dev` (byte-for-byte)

The `dev` tree was seeded from the legacy `prod` objects. To recreate it (from
`alarmify-docs/docs/vault/alarmify-secrets/scripts/dev/01-copy-prod-to-dev.sh`):

```bash
copy_kv() {  # copies one KV v2 object, values unchanged
  local src="$1" dst="$2" tmp; tmp="$(mktemp)"
  vault kv get -format=json "kv/$src" | jq '.data.data' > "$tmp"
  vault kv put "kv/$dst" @"$tmp"; rm -f "$tmp"
}
copy_kv alarmify/prod/alarmify-identity-api  alarmify/dev/alarmify-identity-api
copy_kv alarmify/prod/alarmify-incident-api  alarmify/dev/alarmify-incident-api
copy_kv alarmify/prod/alarmify-schedule-api  alarmify/dev/alarmify-schedule-api
copy_kv alarmify/prod/alarmify-event-worker  alarmify/dev/alarmify-event-worker
copy_kv alarmify/prod/alarmify-ingest-api    alarmify/dev/alarmify-ingest-api
copy_kv alarmify/prod/alarmify-ui            alarmify/dev/alarmify-ui
copy_kv alarmify/prod/postgres/credentials   alarmify/dev/postgres/credentials
# alarmify-auth-api intentionally excluded (legacy, no chart consumes it).
```

Confirm the copy matches its source (every diff must be empty):

```bash
for p in alarmify-identity-api alarmify-incident-api alarmify-schedule-api \
         alarmify-event-worker alarmify-ingest-api alarmify-ui postgres/credentials; do
  echo "=== $p ==="
  diff <(vault kv get -format=json "kv/alarmify/prod/$p" | jq -S '.data.data') \
       <(vault kv get -format=json "kv/alarmify/dev/$p"  | jq -S '.data.data') \
    && echo "OK: dev matches prod"
done
```

---

## Source references

- Charts: `helmcharts/alarmify/*/templates/external-secret.yaml`, `.../values.yaml`, `.../values/dev.yaml`
- Store: `helmcharts/external-secrets/values.yaml` (+ `values/dev.yaml`)
- Field-level schema + scripts: `alarmify-docs/docs/vault/alarmify-secrets/`
- Reference commands: `alarmify-docs/docs/vault/alarmify-secrets/vault-secrets-reference.md`
