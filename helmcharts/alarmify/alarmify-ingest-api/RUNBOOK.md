# 🔐 Tactical Runbook — `alarmify-ingest-api` Vault secrets

> 🎯 **Scope:** every Vault object this chart reads, how to create/rotate/verify it, and how to
> force the sync. Chart context: [`README.md`](./README.md). All-apps reference:
> [`../vault.md`](../vault.md).

---

## 🟢 CURRENT STATE (dev, 2026-07-31)

> ### ✅ Vault is **healthy** for this app
>
> ```
> ExternalSecret/alarmify-ingest-api-vars      SecretSynced   Ready=True
> ExternalSecret/harbor-registry-credentials   SecretSynced   Ready=True
> ```
>
> `kv/alarmify/dev/alarmify-ingest-api` **exists** — the only one of the five Postgres/NATS apps
> whose app object was actually created. **No Vault action needed right now.**
>
> ### 🔴 But the workload is still down
>
> `ImagePullBackOff` — `…/alarmify-ingest-api:v0.0.14` returns **`NotFound`** from Harbor. This is
> **not** a secrets problem. Jump to
> [🖼️ Image pull](#️-image-pull-the-only-blocker-here).

---

## 🗺️ Secret map

| # | Vault object (KV v2, mount `kv`) | → K8s Secret | Consumed as |
|---|---|---|---|
| 1️⃣ | `alarmify/dev/alarmify-ingest-api` (NATS creds) | `alarmify-ingest-api-vars` | `envFrom` |
| 2️⃣ | `alarmify/dev/postgres/credentials` (shared) | `alarmify-ingest-api-vars` | `envFrom` |
| 3️⃣ | `alarmify/management/zitadel` (🏗️ Terraform-owned) | `alarmify-ingest-api-vars` | `envFrom` |
| 4️⃣ | `alarmify/dev/harbor` (shared) | `alarmify-ingest-api-registry` | `imagePullSecrets` |

🔁 `1️⃣` and `2️⃣` arrive via `spec.dataFrom.extract` (whole objects), in that order.
`3️⃣` arrives via **`spec.data`** — one explicit `remoteRef` per key, listed as
`externalSecrets.secretKeyRefs` in `values.yaml`: `ZITADEL_ISSUER` and `ZITADEL_AUDIENCE`.

> 🐘 **`postgres/credentials` is required** (added by commit `d4cf90b`). This app *does* persist
> to Postgres (`internal/database/postgres.go`). Without it, `internal/config/postgres.go` falls
> back to its compiled defaults `postgres`/`postgres` and every query fails with
> `SASL auth: password authentication failed for user "postgres" (SQLSTATE 28P01)`.

> 🔐 **Why key-by-key and not `extract`?** `alarmify/management/zitadel` also holds the
> identity-api provisioner key and the Kiali client secret. An `extract` would copy **every**
> field into this namespace, so each key is pulled by name instead.

> 🥇 **`data` beats `dataFrom` — and that matters here.** `alarmify/dev/alarmify-ingest-api`
> still carries its own stale `ZITADEL_ISSUER` / `ZITADEL_AUDIENCE` copies. ESO's
> `GetProviderSecretData` resolves all `dataFrom` entries first, then `data`, so the
> Terraform-owned values win. The stale copies are harmless but safe to prune.

### ⚠️ This ES behaves differently from its siblings

Because `values/dev.yaml` sets `dbHostOverride`, the template switches to **`mergePolicy: Merge`**
and injects `DB_HOST` **into the Secret itself**:

```yaml
mergePolicy: {{ if .Values.externalSecrets.dbHostOverride }}Merge{{ else }}Replace{{ end }}
{{- if .Values.externalSecrets.dbHostOverride }}
data:
  DB_HOST: {{ .Values.externalSecrets.dbHostOverride | quote }}
{{- end }}
```

**Merge is required** — with `Replace`, this template block would wipe every key the `dataFrom`
extract produced (including `NATS_PASSWORD`). 🚨 If you ever add a `data:` key here, keep
`mergePolicy: Merge`.

---

## 🧰 Prerequisites (once per shell)

```bash
export VAULT_ADDR="https://vault.workquark.org"
vault login            # or: export VAULT_TOKEN=...
vault token lookup

export KUBECONFIG=~/.kube/talos-dev.yaml   # dev-only app
```

> 📎 **KV v2 path note:** manifests use the *logical* path (`alarmify/dev/...`); the CLI needs the
> mount prefix (`kv/alarmify/dev/...`).

```bash
vault kv get -format=json kv/alarmify/dev/alarmify-ingest-api | jq -r '.data.data | keys[]'
```

---

## 1️⃣ The app object

**`kv/alarmify/dev/alarmify-ingest-api`**

| Key | Value | Notes |
|---|---|---|
| `NATS_USER` | `alarmify-ingest-api` | publishes raw ingest events to dev's local NATS |
| `NATS_PASSWORD` | 🔑 `REPLACE_WITH_STRONG_PASSWORD` | publish-connection password |
| ~~`ZITADEL_ISSUER`~~ | *(stale leftover)* | 🧹 **Prunable.** Overridden by `spec.data` from `alarmify/management/zitadel` |
| ~~`ZITADEL_AUDIENCE`~~ | *(stale leftover — dead project ID)* | 🧹 **Prunable.** Same override |

```bash
vault kv put kv/alarmify/dev/alarmify-ingest-api \
  NATS_USER='alarmify-ingest-api' \
  NATS_PASSWORD='REPLACE_WITH_STRONG_PASSWORD'
```

> 🛑 **This object already exists and is syncing.** A bare `vault kv put` **replaces the whole
> object** and would destroy the live `NATS_PASSWORD`. To change one key, always use:
>
> ```bash
> vault kv patch kv/alarmify/dev/alarmify-ingest-api NATS_PASSWORD='...'
> ```

> 🧹 **The `ZITADEL_*` keys here are dead weight.** They predate the move to
> `alarmify/management/zitadel` and still hold the retired project ID. `spec.data` outranks
> `spec.dataFrom`, so they have no effect — but pruning them removes a trap for the next reader:
>
> ```bash
> vault kv get -format=json kv/alarmify/dev/alarmify-ingest-api \
>   | jq '.data.data | del(.ZITADEL_ISSUER, .ZITADEL_AUDIENCE)' > /tmp/ingest.json
> vault kv put kv/alarmify/dev/alarmify-ingest-api @/tmp/ingest.json && rm -f /tmp/ingest.json
> ```

🔑 Generate a NATS password rather than inventing one:

```bash
NATS_PW=$(openssl rand -base64 32 | tr -d '\n')
vault kv patch kv/alarmify/dev/alarmify-ingest-api NATS_PASSWORD="$NATS_PW"
```

⚠️ The same password must exist on the NATS side (`helmcharts/nats` account config) or the app
connects and gets `Authorization Violation` on publish.

### 🧹 Legacy `DB_*` keys

This object may still carry `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` from when
the app was scoped with a database. They are **not read by the app** and **not merged from any
shared object**. Harmless, but safe to prune:

```bash
vault kv get -format=json kv/alarmify/dev/alarmify-ingest-api \
  | jq '.data.data | with_entries(select(.key | startswith("DB_") | not))' > /tmp/ingest.json
vault kv put kv/alarmify/dev/alarmify-ingest-api @/tmp/ingest.json
rm -f /tmp/ingest.json
```

> ℹ️ The `DB_HOST` you'll see **in the Kubernetes Secret** is a different thing — it is injected by
> the ES template from `dbHostOverride`, not extracted from Vault. Pruning Vault's copy does not
> remove it.

---

## 2️⃣ Harbor image-pull credentials

**`kv/alarmify/dev/harbor`**, single field `.dockerconfigjson`. Shared by all six `alarmify-*`
namespaces.

> 🟢 **Currently healthy** — `harbor-registry-credentials` is `SecretSynced`. Only touch on
> rotation.

> 🚫 **Store raw JSON, not base64.** ESO base64-encodes on write; pre-encoding double-encodes and
> every pod fails with `ImagePullBackOff` / `couldn't parse image reference`.

```bash
HARBOR_USER=$(vault kv get -field=user  kv/harbor/secret)
HARBOR_TOKEN=$(vault kv get -field=token kv/harbor/secret)
AUTH=$(printf '%s:%s' "$HARBOR_USER" "$HARBOR_TOKEN" | base64 | tr -d '\n')

jq -n --arg u "$HARBOR_USER" --arg p "$HARBOR_TOKEN" --arg a "$AUTH" '
  { auths:
      ( ["harbor.workquark.org", "https://harbor.workquark.org"]
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
kubectl -n alarmify-ingest-api annotate externalsecret alarmify-ingest-api-vars \
  force-sync="$(date +%s)" --overwrite
kubectl -n alarmify-ingest-api get externalsecret -w

kubectl -n alarmify-ingest-api rollout restart deploy/dev-alarmify-ingest-api
kubectl -n alarmify-ingest-api rollout status  deploy/dev-alarmify-ingest-api
```

`refreshInterval: 1h`, and env vars are injected at pod start — both steps are required.

---

## ✅ Verify

```bash
# Vault side — key names only
vault kv get -format=json kv/alarmify/dev/alarmify-ingest-api | jq -r '.data.data | keys[]'

# Kubernetes side — must include NATS_USER, NATS_PASSWORD and the injected DB_HOST
kubectl -n alarmify-ingest-api get secret alarmify-ingest-api-vars \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

kubectl -n alarmify-ingest-api get externalsecret alarmify-ingest-api-vars \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'

# End-to-end: publish path is working if the stream count moves
NATSBOX=$(kubectl -n nats get pod -l app.kubernetes.io/name=nats-box -o name | head -1)
kubectl -n nats exec "$NATSBOX" -- \
  nats --server nats://dev-nats.nats.svc.cluster.local:4222 stream info ALARMIFY_EVENTS_RAW -j \
  | jq '{messages:.state.messages, last:.state.last_ts}'
```

---

## 🧭 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `SecretSyncedError` + `err: Secret does not exist` | `kv/alarmify/dev/alarmify-ingest-api` deleted | Recreate → [1️⃣](#1️⃣-the-app-object) |
| `NATS_PASSWORD` vanished from the Secret after an edit | Someone used `vault kv put` (replaces whole object) instead of `patch` | Rewrite the full object, force-sync, restart |
| Every key except `DB_HOST` vanished from the Secret | `mergePolicy` flipped to `Replace` while `dbHostOverride` is set | Keep the `Merge`/`Replace` conditional in `external-secret.yaml` intact |
| Publish fails, `Authorization Violation` | `NATS_PASSWORD` in Vault ≠ the account password in `helmcharts/nats` | Align both, force-sync, restart |
| Publishes succeed but the worker never consumes | Subject/filter mismatch — publisher sends `alarmify.events.raw.{tenant}`, durable filters `alarmify.events.raw.*` | `nats consumer info ALARMIFY_EVENTS_RAW alarmify-event-processor` |
| `401`/`403` on every request | `ZITADEL_AUDIENCE` ≠ the `aud` the caller sends | Compare the token's `aud` against `ZITADEL_AUDIENCE` in `kv/alarmify/management/zitadel`. 🚫 Never reintroduce it in `values.yaml` — see the row below |
| Vault Zitadel keys seem ignored | Someone reintroduced `auth.zitadelIssuer`/`auth.zitadelAudience` as chart values — they render as literal `env`, which Kubernetes ranks **above** `envFrom` | Delete the `auth.*` values *and* their `env` entries in `deployment.yaml`. This exact bug pinned the app to a dead project ID until 2026-08-01 |
| Zitadel keys hold the *old* project ID | Reading the stale copies still in `kv/alarmify/dev/alarmify-ingest-api` rather than the `spec.data` values | `spec.data` wins, so the app is fine — but prune them → [1️⃣](#1️⃣-the-app-object) |
| `SecretSyncedError` + connection refused / TLS | dev reaches Vault over the **public** `https://vault.workquark.org` | Check the Cloudflare tunnel + DNS; accepted risk for dev |
| `ImagePullBackOff` | See below | |

### 🖼️ Image pull — the only blocker here

`Secret/alarmify-ingest-api-registry` exists and its ES is `SecretSynced`, so **credentials are not
the problem**. containerd returns `NotFound` — the **tag is absent from Harbor**:

```bash
HARBOR_USER=$(vault kv get -field=user  kv/harbor/secret)
HARBOR_TOKEN=$(vault kv get -field=token kv/harbor/secret)
curl -su "$HARBOR_USER:$HARBOR_TOKEN" \
  "https://harbor.workquark.org/api/v2.0/projects/alarmify/repositories/alarmify-ingest-api/artifacts?page_size=20" \
  | jq -r '.[].tags[]?.name'
```

Push the missing tag, or correct `image.tag` in `values.yaml` and let ArgoCD sync.
🚫 Do **not** `kubectl set image` — `selfHeal: true` reverts it.

### 🔎 ESO controller logs

```bash
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=200 \
  | grep alarmify-ingest-api | tail -5
```

---

## 🧱 Guardrails

- 🛑 **Use `vault kv patch`, not `put`, on this object** — it holds a live `NATS_PASSWORD` that a
  full `put` would silently destroy.
- 🚫 **Never** commit a Vault value to this repo.
- 🚫 **Never** `kubectl edit secret alarmify-ingest-api-vars` — ESO owns it and overwrites on the
  next refresh.
- 🚫 **Never** `kubectl label secret -n argocd local ...` — `selfHeal: true` reverts it.
- ⚠️ `deletionPolicy: Retain` — deleting the ExternalSecret leaves the K8s Secret behind.
- ♻️ `harbor` is **shared** — rotating it affects all `alarmify-*` apps; force-sync every namespace.

---

## 📚 Related

- 📖 [`README.md`](./README.md) — chart design notes
- 🗝️ [`../vault.md`](../vault.md) — every `alarmify-*` app's Vault objects
- 🛠️ [`../alarmify-event-worker/RUNBOOK.md`](../alarmify-event-worker/RUNBOOK.md) — the consumer's
  NATS credentials
- 📨 `helmcharts/nats/` — JetStream bootstrap + NATS accounts
