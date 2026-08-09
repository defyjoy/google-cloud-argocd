# 🔐 Tactical Runbook — `alarmify-identity-api` Vault secrets

> 🎯 **Scope:** every Vault object this chart reads, how to create/rotate/verify it, and how to
> force the sync. Chart context: [`README.md`](./README.md). All-apps reference:
> [`../vault.md`](../vault.md).

---

## 🚨 CURRENT BLOCKER (dev)

> ✅ **RESOLVED (2026-08-01):** the chart no longer reads `kv/alarmify/dev/alarmify-identity-api`.
> That object was deleted from Vault, which left the ES in `SecretSyncedError`
> (`spec.dataFrom[0].extract … Secret does not exist`). Zitadel config now comes from the
> Terraform-owned `alarmify/management/zitadel` and the object is gone from `appVarsKeys`
> — **do not recreate it.**
>
> ⚠️ **Independent, still open:** `ImagePullBackOff` — `…/alarmify-identity-api:v0.0.12`
> returned `NotFound` from Harbor. Fixing Vault alone will **not** bring the pod up. See
> [🖼️ Image pull](#️-image-pull-second-blocker). *(Unverified as of 2026-08-01 — the robot
> creds at `kv/harbor/secret` no longer resolve, so the Harbor API returns 401.)*

---

## 🗺️ Secret map

| # | Vault object (KV v2, mount `kv`) | → K8s Secret | Consumed as |
|---|---|---|---|
| 1️⃣ | `alarmify/management/zitadel` (🏗️ Terraform-owned) | `alarmify-identity-api-vars` | `envFrom` |
| 2️⃣ | `alarmify/dev/postgres/credentials` (shared) | `alarmify-identity-api-vars` | `envFrom` |
| 3️⃣ | `alarmify/dev/harbor` (shared) | `alarmify-identity-api-registry` | `imagePullSecrets` |

🔁 `2️⃣` arrives via `spec.dataFrom.extract` (whole object). `1️⃣` arrives via **`spec.data`** —
one explicit `remoteRef` per key, listed as `externalSecrets.secretKeyRefs` in `values.yaml`.

> 🔐 **Why key-by-key and not `extract`?** `alarmify/management/zitadel` also holds
> `ZITADEL_KIALI_CLIENT_SECRET`. An `extract` would copy **every** field into this namespace,
> so each key is pulled by name instead.

> 🥇 **`data` beats `dataFrom`.** ESO's `GetProviderSecretData` resolves all `dataFrom` entries
> first, then `data` — so the Zitadel keys win on any collision, regardless of ordering.

> 🧷 **`dbHostOverride` beats both.** `values/dev.yaml` injects `DB_HOST` as a literal `env` var
> and Kubernetes ranks `env` above `envFrom`. The effective dev value is always
> `postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local`.

> 🧩 **`AUTH_MODE` is not in Vault.** It is not a Zitadel object, so Terraform emits no output
> for it. It is chart config: `auth.authMode` in `values.yaml`, rendered as a literal `env`.
> The in-code default is `legacy` (`internal/config/config.go:86`), which is dead — leave it
> set to `zitadel`.

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

The chart maps these into env-var names via `externalSecrets.secretKeyRefs`. Two names differ
between Vault and the app, so read this table before assuming a 1:1 mapping:

| Env var (what the app reads) | ← Vault key | Notes |
|---|---|---|
| `ZITADEL_ISSUER` | `ZITADEL_ISSUER` | JWKS verification + mgmt API |
| `ZITADEL_AUDIENCE` | `ZITADEL_AUDIENCE` | expected `aud` — the **API app's** client_id |
| `ZITADEL_PROJECT_ID` | `ZITADEL_PROJECT_ID` | the Alarmify project |
| `ZITADEL_PROJECT_ORG_ID` | 🔀 **`ZITADEL_INSTANCE_ORG_ID`** | org owning the project — Terraform's name differs; same value (`internal/clients/zitadelclient/client.go:36`) |
| `ZITADEL_ACTION_SIGNING_KEY` | `ZITADEL_ACTION_SIGNING_KEY` | 🔑 verifies Zitadel Actions v2 calls; empty skips verification (**dev only**) |
| `ZITADEL_PROVISIONER_KEY_JSON` | `ZITADEL_PROVISIONER_KEY_JSON` | 🔑 machine-key JSON for the `identity-api-provisioner` service account |

🚫 The object also holds `ZITADEL_KIALI_CLIENT_ID` / `ZITADEL_KIALI_CLIENT_SECRET`,
`ZITADEL_UI_CLIENT_ID`, `ZITADEL_PLATFORM_PROJECT_ID` and `ZITADEL_PROVISIONER_USER_ID`. This
chart deliberately does **not** pull them — that is the whole reason it uses per-key
`spec.data` instead of a `dataFrom.extract`.

To (re)create the whole object, run Terraform:

```bash
cd alarmify-common-infra/terraform/zitadel
terraform apply           # writes kv/alarmify/management/zitadel wholesale
```

Read back the key names only (never the values):

```bash
vault kv get -format=json kv/alarmify/management/zitadel | jq -r '.data.data | keys[]'
```

---

## 2️⃣ Shared Postgres credentials

**`kv/alarmify/dev/postgres/credentials`** — shared with incident-api, schedule-api, event-worker.
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

> 🟢 **Currently healthy here** — `harbor-registry-credentials` is `SecretSynced` and
> `Secret/alarmify-identity-api-registry` exists. Only touch this on rotation.

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

jq -e '.auths | keys' dockerconfig.json
vault kv put kv/alarmify/dev/harbor .dockerconfigjson=@dockerconfig.json
shred -u dockerconfig.json 2>/dev/null || rm -f dockerconfig.json
```

> 💲 **Harbor robot names contain `$`.** Always source them via `$(...)`. Typed by hand, use
> **single** quotes (`'robot$alarmify+puller'`) — in double quotes the shell expands `$alarmify`
> to empty and Harbor rejects the login.

---

## 🔄 Force a sync

`refreshInterval: 1h`, so ESO will not notice a Vault write immediately:

```bash
kubectl -n alarmify-identity-api annotate externalsecret alarmify-identity-api-vars \
  force-sync="$(date +%s)" --overwrite
kubectl -n alarmify-identity-api get externalsecret -w
```

Env vars are injected at pod start and **not** hot-reloaded, so restart afterwards:

```bash
kubectl -n alarmify-identity-api rollout restart deploy/dev-alarmify-identity-api
kubectl -n alarmify-identity-api rollout status  deploy/dev-alarmify-identity-api
```

---

## ✅ Verify

```bash
# Vault side — key names only, no values
vault kv get -format=json kv/alarmify/management/zitadel     | jq -r '.data.data | keys[]'
vault kv get -format=json kv/alarmify/dev/postgres/credentials | jq -r '.data.data | keys[]'

# The provisioner key must be valid JSON
vault kv get -field=ZITADEL_PROVISIONER_KEY_JSON kv/alarmify/management/zitadel | jq -e .type

# Every property the chart references must exist (prints MISSING for any that don't)
AVAIL=$(vault kv get -format=json kv/alarmify/management/zitadel | jq -r '.data.data|keys[]')
grep -oE 'property: ZITADEL_[A-Z_]+' values.yaml | awk '{print $2}' | sort -u | while read p; do
  echo "$AVAIL" | grep -qx "$p" && echo "OK      $p" || echo "MISSING $p"
done

# Kubernetes side — key names in the Secret
kubectl -n alarmify-identity-api get secret alarmify-identity-api-vars \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

# ExternalSecret conditions
kubectl -n alarmify-identity-api get externalsecret alarmify-identity-api-vars \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

---

## 🧭 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `SecretSyncedError` + `err: Secret does not exist` | `appVarsKeys[0]` (shared postgres) missing | [2️⃣](#2️⃣-shared-postgres-credentials) |
| `SecretSyncedError` naming a `spec.data[N]` property | Key absent from `alarmify/management/zitadel` — usually Terraform not applied, or applied from a checkout that predates the key | Re-run the Zitadel Terraform; verify with the property check above |
| `SecretSyncedError` + `permission denied` / `403` | Vault token in `external-secrets/vault-token` expired or lacks a policy on the path | Renew/replace that Secret in ns `external-secrets` |
| `SecretSyncedError` + connection refused / TLS | dev reaches Vault over the **public** `https://vault.jrclabs.xyz` (no in-cluster Vault) | Check the Cloudflare tunnel + DNS; known, accepted risk for dev |
| Pod crashloops on startup, Zitadel error | `ZITADEL_ISSUER` / `ZITADEL_AUDIENCE` missing or wrong | Both are **Vault-only** for this app — verify with the round-trip above |
| `401`/`403` on every request | `ZITADEL_AUDIENCE` ≠ the `aud` claim the caller sends | Compare the token's `aud` against `ZITADEL_AUDIENCE` in `kv/alarmify/management/zitadel`. Never hardcode it in `values.yaml` — a literal `env` would silently shadow Vault |
| Provisioning fails, `ZITADEL_PROJECT_ORG_ID` looks unset | Expecting a Vault key of that name — there isn't one | It maps from **`ZITADEL_INSTANCE_ORG_ID`**; see the mapping table in [1️⃣](#1️⃣-zitadel-config-️-terraform-owned--do-not-hand-write) |
| A Zitadel key reverted after someone "fixed" it in Vault | `terraform apply` rewrote the object wholesale | Change it in `terraform/zitadel/vault.tf` and re-apply — never `vault kv patch` this object |
| Tenant provisioning fails, Zitadel `invalid assertion` | Stale `ZITADEL_PROVISIONER_KEY_JSON` — the SA key was rotated in Zitadel | Re-run the Zitadel Terraform, then force-sync + restart |
| Secret exists but pod has old values | Env vars injected at pod start | `kubectl rollout restart` |
| DB connections go to `localhost:5432` | `DB_*` never reached the container | Fix the ExternalSecret first |
| `ImagePullBackOff` | See below | |

### 🖼️ Image pull (second blocker)

`Secret/alarmify-identity-api-registry` exists and its ES is `SecretSynced`, so **credentials are
not the problem**. containerd returns `NotFound` — the **tag is absent from Harbor**:

```bash
HARBOR_USER=$(vault kv get -field=user  kv/harbor/secret)
HARBOR_TOKEN=$(vault kv get -field=token kv/harbor/secret)
curl -su "$HARBOR_USER:$HARBOR_TOKEN" \
  "https://harbor.jrclabs.xyz/api/v2.0/projects/alarmify/repositories/alarmify-identity-api/artifacts?page_size=20" \
  | jq -r '.[].tags[]?.name'
```

Push the missing tag, or correct `image.tag` in `values.yaml` and let ArgoCD sync.
🚫 Do **not** `kubectl set image` — `selfHeal: true` reverts it on the next reconcile.

### 🔎 ESO controller logs

```bash
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=200 \
  | grep alarmify-identity-api | tail -5
```

---

## 🧱 Guardrails

- 🚫 **Never** commit a Vault value to this repo. Charts reference *paths*, never secrets.
- 🚫 **Never** `kubectl edit secret alarmify-identity-api-vars` — ESO owns it
  (`creationPolicy: Owner`) and overwrites on the next refresh.
- 🚫 **Never** `kubectl label secret -n argocd local ...` — `selfHeal: true` reverts it. Add the
  label in `helmcharts/argocd/templates/cluster/local-cluster-secret.yaml`.
- ⚠️ `deletionPolicy: Retain` — deleting the ExternalSecret leaves the K8s Secret behind.
- ♻️ `postgres/credentials` and `harbor` are **shared** — rotating either affects all
  `alarmify-*` apps; force-sync every namespace.
- 🏗️ **Never hand-edit `alarmify/management/zitadel`.** `vault_kv_secret_v2` writes exactly its
  `data_json`, so hand-added keys vanish on the next `terraform apply`. Change
  `alarmify-common-infra/terraform/zitadel/vault.tf` instead.
- 🚫 **Never** reintroduce `ZITADEL_*` as chart `auth.*` values. They render as literal `env`,
  which Kubernetes ranks above `envFrom` — the literal silently shadows Vault. This exact bug
  pinned incident-api and ingest-api to a dead project ID.

---

## 📚 Related

- 📖 [`README.md`](./README.md) — chart design notes
- 🗝️ [`../vault.md`](../vault.md) — every `alarmify-*` app's Vault objects
- 🔑 `helmcharts/external-secrets/` — `ClusterSecretStore/vault-secretstore`
