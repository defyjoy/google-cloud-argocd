# 🔐 Tactical Runbook — `alarmify-incident-api` Vault secrets

> 🎯 **Scope:** every Vault object this chart reads, how to create/rotate/verify it, and how to
> force the sync. Chart context: [`README.md`](./README.md). All-apps reference:
> [`../vault.md`](../vault.md).

---

## 🚨 CURRENT BLOCKER (dev)

> ✅ **RESOLVED (2026-08-01):** the chart no longer reads `kv/alarmify/dev/alarmify-incident-api`.
> That object was deleted from Vault, leaving the ES in `SecretSyncedError`
> (`spec.dataFrom[0].extract … Secret does not exist`) and the app on `localhost:5432`. Zitadel
> config now comes from the Terraform-owned `alarmify/management/zitadel`; `DB_*` comes from the
> shared Postgres object. **Do not recreate the per-app object.**
>
> ✅ **Also fixed:** `ZITADEL_AUDIENCE` was hardcoded to `380619948738806915` in `values.yaml` and
> rendered as a literal `env`, which outranks `envFrom` — so it shadowed Vault and pinned the app
> to a **dead project ID**, rejecting every token. The `auth.*` values and their `env` entries are
> gone; the value is now Vault-only.
>
> ⚠️ **Independent, still open:** `ImagePullBackOff` — `…/alarmify-incident-api:v0.0.20`
> returned `NotFound` from Harbor. Fixing Vault alone will **not** bring the pod up. See
> [🖼️ Image pull](#️-image-pull-second-blocker). *(Unverified as of 2026-08-01 — the robot creds
> at `kv/harbor/secret` no longer resolve, so the Harbor API returns 401.)*

---

## 🗺️ Secret map

| # | Vault object (KV v2, mount `kv`) | → K8s Secret | Consumed as |
|---|---|---|---|
| 1️⃣ | `alarmify/management/zitadel` (🏗️ Terraform-owned) | `alarmify-incident-api-vars` | `envFrom` |
| 2️⃣ | `alarmify/dev/postgres/credentials` (shared) | `alarmify-incident-api-vars` | `envFrom` |
| 3️⃣ | `alarmify/dev/harbor` (shared) | `alarmify-incident-api-registry` | `imagePullSecrets` |

🔁 `2️⃣` arrives via `spec.dataFrom.extract` (whole object). `1️⃣` arrives via **`spec.data`** —
one explicit `remoteRef` per key, listed as `externalSecrets.secretKeyRefs` in `values.yaml`.
This chart pulls exactly two: `ZITADEL_ISSUER` and `ZITADEL_AUDIENCE`.

> 🔐 **Why key-by-key and not `extract`?** `alarmify/management/zitadel` also holds the
> identity-api provisioner key and the Kiali client secret. An `extract` would copy **every**
> field into this namespace, so each key is pulled by name instead.

> 🥇 **`data` beats `dataFrom`.** ESO's `GetProviderSecretData` resolves all `dataFrom` entries
> first, then `data` — so the Zitadel keys win on any collision.

> 🧷 **`DB_HOST` still beats Vault.** `values/dev.yaml` injects it as a literal `env` var and
> Kubernetes ranks `env` above `envFrom`. It is now the **only** such override on this chart —
> the `ZITADEL_*` literals that used to sit alongside it have been removed.

---

## 🧰 Prerequisites (once per shell)

```bash
export VAULT_ADDR="https://vault.jrclabs.xyz"
vault login            # or: export VAULT_TOKEN=...
vault token lookup

export KUBECONFIG=~/.kube/talos-dev.yaml   # dev-only app
```

> 📎 **KV v2 path note:** manifests use the *logical* path (`alarmify/dev/...`); the CLI needs the
> mount prefix (`kv/alarmify/dev/...`).

```bash
vault kv list kv/alarmify/dev
vault kv get -format=json kv/alarmify/management/zitadel | jq -r '.data.data | keys[]'
```

---

## 1️⃣ Zitadel config (🏗️ Terraform-owned — do not hand-write)

**`kv/alarmify/management/zitadel`**

⚠️ This object is written by `alarmify-common-infra/terraform/zitadel` (`vault.tf`). It uses
`vault_kv_secret_v2`, which writes **exactly** its `data_json` — any key you add by hand
**disappears on the next `terraform apply`**. To change a value, change Terraform and re-apply.

This chart maps two keys, both 1:1, via `externalSecrets.secretKeyRefs`:

| Env var (what the app reads) | ← Vault key | Notes |
|---|---|---|
| `ZITADEL_ISSUER` | `ZITADEL_ISSUER` | JWKS verification |
| `ZITADEL_AUDIENCE` | `ZITADEL_AUDIENCE` | expected `aud` — the **API app's** client_id, not the project_id |

🚫 The object holds seven other keys (provisioner key, Kiali + UI client IDs/secrets, platform
project ID). This chart deliberately does **not** pull them — that is the whole reason it uses
per-key `spec.data` instead of a `dataFrom.extract`.

To (re)create the object, run Terraform:

```bash
cd alarmify-common-infra/terraform/zitadel
terraform apply           # writes kv/alarmify/management/zitadel wholesale
```

> 🪫 **There is no longer a per-app Vault object.** `alarmify/dev/alarmify-incident-api` is gone
> and out of `appVarsKeys`. Do not recreate it — an empty object is no longer needed to satisfy
> `dataFrom`, and a populated one would only reintroduce drift.

> 💡 `vault kv put` **replaces the whole object**; use `vault kv patch` to change one key.

---

## 2️⃣ Shared Postgres credentials — 🎯 the ones that actually matter here

**`kv/alarmify/dev/postgres/credentials`** — shared with identity-api, schedule-api, event-worker.
🚫 **Do not create a private copy.** Rotating here rotates for all four.

| Key | Value |
|---|---|
| `DB_HOST` | `pg-egress-bridge.pg-egress-bridge.svc.cluster.local` (overridden per-app, see note above) |
| `DB_PORT` | `5432` |
| `DB_USER` | `postgres` |
| `DB_PASSWORD` | 🔑 `REPLACE_WITH_STRONG_PASSWORD` |
| `DB_NAME` | `alarmify` |
| `DB_SSLMODE` | `disable` |
| `DB_TIMEZONE` | `UTC` |

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

🚫 Never set `DB_HOST` to the LAN name `cloudnative-postgres.home.arpa` — that hairpins through
the istio-gateway TCPRoute and ambient clients get `EOF`.

Rotate just the password, then force-sync **every** consumer:

```bash
vault kv patch kv/alarmify/dev/postgres/credentials DB_PASSWORD='NEW_PASSWORD'

for ns in alarmify-identity-api alarmify-incident-api alarmify-schedule-api alarmify-event-worker; do
  kubectl -n "$ns" annotate externalsecret "${ns}-vars" force-sync="$(date +%s)" --overwrite
  kubectl -n "$ns" rollout restart deploy/dev-"$ns"
done
```

---

## 3️⃣ Harbor image-pull credentials

**`kv/alarmify/dev/harbor`**, single field `.dockerconfigjson`. Shared by all six `alarmify-*`
namespaces.

> 🟢 **Currently healthy here** — `harbor-registry-credentials` is `SecretSynced`. Only touch on
> rotation.

> 🚫 **Store raw JSON, not base64.** ESO base64-encodes on write; pre-encoding double-encodes and
> every pod fails with `ImagePullBackOff` / `couldn't parse image reference`.

```bash
HARBOR_USER=$(vault kv get -field=user  kv/harbor/secret)
HARBOR_TOKEN=$(vault kv get -field=token kv/harbor/secret)
AUTH=$(printf '%s:%s' "$HARBOR_USER" "$HARBOR_TOKEN" | base64 | tr -d '\n')

jq -n --arg u "$HARBOR_USER" --arg p "$HARBOR_TOKEN" --arg a "$AUTH" '
  { auths:
      ( ["harbor.jrclabs.xyz", "https://harbor.jrclabs.xyz"]
        | map({ (.): { username: $u, password: $p, auth: $a } })
        | add ) }' > dockerconfig.json

vault kv put kv/alarmify/dev/harbor .dockerconfigjson=@dockerconfig.json
shred -u dockerconfig.json 2>/dev/null || rm -f dockerconfig.json
```

> 💲 **Harbor robot names contain `$`.** Source them via `$(...)`; typed by hand use **single**
> quotes (`'robot$alarmify+puller'`).

---

## 🔄 Force a sync

```bash
kubectl -n alarmify-incident-api annotate externalsecret alarmify-incident-api-vars \
  force-sync="$(date +%s)" --overwrite
kubectl -n alarmify-incident-api get externalsecret -w

kubectl -n alarmify-incident-api rollout restart deploy/dev-alarmify-incident-api
kubectl -n alarmify-incident-api rollout status  deploy/dev-alarmify-incident-api
```

`refreshInterval: 1h`, and env vars are injected at pod start — both steps are required.

---

## ✅ Verify

```bash
vault kv get -format=json kv/alarmify/management/zitadel      | jq -r '.data.data | keys[]'
vault kv get -format=json kv/alarmify/dev/postgres/credentials | jq -r '.data.data | keys[]'

# The audience the app will enforce — compare against the token's `aud`
vault kv get -field=ZITADEL_AUDIENCE kv/alarmify/management/zitadel

kubectl -n alarmify-incident-api get secret alarmify-incident-api-vars \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

kubectl -n alarmify-incident-api get externalsecret alarmify-incident-api-vars \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'

# End-to-end: the route should stop 500-ing once DB_* land
kubectl -n alarmify-incident-api exec deploy/dev-alarmify-incident-api -- \
  env | grep -E '^(DB_|ZITADEL_)' | sed 's/=.*/=<redacted>/'
```

---

## 🧭 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `SecretSyncedError` + `err: Secret does not exist` | `appVarsKeys[0]` (shared postgres) missing | [2️⃣](#2️⃣-shared-postgres-credentials--🎯-the-ones-that-actually-matter-here) |
| `SecretSyncedError` naming a `spec.data[N]` property | Key absent from `alarmify/management/zitadel` — usually Terraform not applied | Re-run the Zitadel Terraform |
| `GET /api/v1/incidents` → **500** | `DB_HOST`/`DB_PASSWORD` never reached the container; app defaults to `localhost:5432` | Fix the shared postgres object, force-sync, restart |
| `SecretSyncedError` + `permission denied` / `403` | Vault token in `external-secrets/vault-token` expired or lacks a policy | Renew/replace that Secret in ns `external-secrets` |
| `SecretSyncedError` + connection refused / TLS | dev reaches Vault over the **public** `https://vault.jrclabs.xyz` | Check the Cloudflare tunnel + DNS; accepted risk for dev |
| `401`/`403` on every request | `ZITADEL_AUDIENCE` ≠ the `aud` the caller sends | Compare the token's `aud` against `ZITADEL_AUDIENCE` in `kv/alarmify/management/zitadel`. 🚫 Never reintroduce it in `values.yaml` — see the row below |
| Vault Zitadel keys seem ignored | Someone reintroduced `auth.zitadelIssuer`/`auth.zitadelAudience` as chart values — they render as literal `env`, which Kubernetes ranks **above** `envFrom` | Delete the `auth.*` values *and* their `env` entries in `deployment.yaml`. This exact bug pinned the app to a dead project ID until 2026-08-01 |
| Kiali shows no HTTP codes for this app | waypoint down, or `VMPodScrape` not applied | `kubectl -n alarmify-incident-api get gateway,vmpodscrape` |
| `ImagePullBackOff` | See below | |

### 🖼️ Image pull (second blocker)

`Secret/alarmify-incident-api-registry` exists and its ES is `SecretSynced`, so **credentials are
not the problem**. containerd returns `NotFound` — the **tag is absent from Harbor**:

```bash
HARBOR_USER=$(vault kv get -field=user  kv/harbor/secret)
HARBOR_TOKEN=$(vault kv get -field=token kv/harbor/secret)
curl -su "$HARBOR_USER:$HARBOR_TOKEN" \
  "https://harbor.jrclabs.xyz/api/v2.0/projects/alarmify/repositories/alarmify-incident-api/artifacts?page_size=20" \
  | jq -r '.[].tags[]?.name'
```

Push the missing tag, or correct `image.tag` in `values.yaml` and let ArgoCD sync.
🚫 Do **not** `kubectl set image` — `selfHeal: true` reverts it.

### 🔎 ESO controller logs

```bash
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=200 \
  | grep alarmify-incident-api | tail -5
```

---

## 🧱 Guardrails

- 🚫 **Never** commit a Vault value to this repo.
- 🚫 **Never** `kubectl edit secret alarmify-incident-api-vars` — ESO owns it
  (`creationPolicy: Owner`) and overwrites on the next refresh.
- 🚫 **Never** `kubectl label secret -n argocd local ...` — `selfHeal: true` reverts it.
- ⚠️ `deletionPolicy: Retain` — deleting the ExternalSecret leaves the K8s Secret behind.
- ♻️ `postgres/credentials` and `harbor` are **shared** — force-sync every namespace after a
  rotation.

---

## 📚 Related

- 📖 [`README.md`](./README.md) — chart design notes
- 🗝️ [`../vault.md`](../vault.md) — every `alarmify-*` app's Vault objects
- 🔑 `helmcharts/external-secrets/` — `ClusterSecretStore/vault-secretstore`
