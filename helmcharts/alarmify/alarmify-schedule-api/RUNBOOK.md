# 🔐 Tactical Runbook — `alarmify-schedule-api` Vault secrets

> 🎯 **Scope:** every Vault object this chart reads, how to create/rotate/verify it, and how to
> force the sync. Chart context: [`README.md`](./README.md). All-apps reference:
> [`../vault.md`](../vault.md).

---

## 🚨 CURRENT BLOCKER (dev)

> ✅ **RESOLVED (2026-08-01):** the chart no longer reads `kv/alarmify/dev/alarmify-schedule-api`.
> That object was deleted from Vault, and because ESO fails the **whole** ExternalSecret when any
> `dataFrom` entry is missing, an object that needed *no keys at all* was taking down `DB_*` and
> 500-ing every schedule route. It is out of `appVarsKeys` now — **do not recreate it.**
>
> ⚠️ **Independent, still open:** `ImagePullBackOff` — `…/alarmify-schedule-api:v0.0.2` returned
> `NotFound` from Harbor. Fixing Vault alone will **not** bring the pod up. See
> [🖼️ Image pull](#️-image-pull-second-blocker). *(Unverified as of 2026-08-01 — the robot creds
> at `kv/harbor/secret` no longer resolve, so the Harbor API returns 401.)*

---

## 🗺️ Secret map

| # | Vault object (KV v2, mount `kv`) | → K8s Secret | Consumed as |
|---|---|---|---|
| 1️⃣ | `alarmify/dev/postgres/credentials` (shared) | `alarmify-schedule-api-vars` | `envFrom` |
| 2️⃣ | `alarmify/dev/harbor` (shared) | `alarmify-schedule-api-registry` | `imagePullSecrets` |

🔁 `1️⃣` is the **only** `dataFrom.extract` entry — this chart has no per-app Vault object.

> 🚫 **No Zitadel keys here, by design.** Unlike its siblings this service reads **no `ZITADEL_*`
> env vars at all** (verified against the source), so it has no `externalSecrets.secretKeyRefs`
> block and does not reference `alarmify/management/zitadel`. Auth is enforced upstream.

> 🧷 **`dbHostOverride` beats Vault entirely.** `values/dev.yaml` injects `DB_HOST` as a literal
> `env` var and Kubernetes ranks `env` above `envFrom`. Effective dev value is always
> `postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local`.

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
vault kv get -format=json kv/alarmify/dev/postgres/credentials | jq -r '.data.data | keys[]'
```

---

## 1️⃣ ~~The app object~~ — 🗑️ removed

**There is no `kv/alarmify/dev/alarmify-schedule-api` any more, and there should not be.**

This app needs **no app-specific keys**: all its configuration is Postgres, from the shared
object below. The empty object used to exist only to satisfy `dataFrom` — ESO fails the *whole*
ExternalSecret when any `dataFrom` entry resolves to nothing, so an object holding zero keys
could still take the service down. It was deleted from Vault and dropped from `appVarsKeys`
on 2026-08-01.

> 🚫 **Do not recreate it.** Re-adding the path to `appVarsKeys` reintroduces a failure mode
> with no upside. If a future release genuinely needs app-specific config, add the object *and*
> the `appVarsKeys` entry together in the same change.

---

## 2️⃣ Shared Postgres credentials — 🎯 the ones that actually matter here

**`kv/alarmify/dev/postgres/credentials`** — shared with identity-api, incident-api, event-worker.
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
kubectl -n alarmify-schedule-api annotate externalsecret alarmify-schedule-api-vars \
  force-sync="$(date +%s)" --overwrite
kubectl -n alarmify-schedule-api get externalsecret -w

kubectl -n alarmify-schedule-api rollout restart deploy/dev-alarmify-schedule-api
kubectl -n alarmify-schedule-api rollout status  deploy/dev-alarmify-schedule-api
```

`refreshInterval: 1h`, and env vars are injected at pod start — both steps are required.

---

## ✅ Verify

```bash
# Vault side — the shared postgres object is the only one this chart reads
vault kv get -format=json kv/alarmify/dev/postgres/credentials | jq -r '.data.data | keys[]'

# Kubernetes side — should show the seven DB_* keys
kubectl -n alarmify-schedule-api get secret alarmify-schedule-api-vars \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

kubectl -n alarmify-schedule-api get externalsecret alarmify-schedule-api-vars \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

---

## 🧭 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `SecretSyncedError` + `err: Secret does not exist` | `dataFrom[0]` — the shared postgres object is missing | [2️⃣](#2️⃣-shared-postgres-credentials--🎯-the-ones-that-actually-matter-here) |
| Same error naming `alarmify/dev/alarmify-schedule-api` | Someone re-added the deleted per-app path to `appVarsKeys` | Remove it from `values.yaml` — don't recreate the Vault object → [1️⃣](#1️⃣-the-app-object--️-removed) |
| Schedule routes return **500** | `DB_HOST`/`DB_PASSWORD` never reached the container | Fix the shared postgres object, force-sync, restart |
| `SecretSyncedError` + `permission denied` / `403` | Vault token in `external-secrets/vault-token` expired or lacks a policy | Renew/replace that Secret in ns `external-secrets` |
| `SecretSyncedError` + connection refused / TLS | dev reaches Vault over the **public** `https://vault.jrclabs.xyz` | Check the Cloudflare tunnel + DNS; accepted risk for dev |
| Secret exists but pod has old values | Env vars injected at pod start | `kubectl rollout restart` |
| `DEBUG` never appears in the container | Expected — `debug: "true"` in `values.yaml` is inert for this chart; `deployment.yaml` renders no `DEBUG` env var | Add it to `deployment.yaml` if you actually need it |
| `ImagePullBackOff` | See below | |

### 🖼️ Image pull (second blocker)

`Secret/alarmify-schedule-api-registry` exists and its ES is `SecretSynced`, so **credentials are
not the problem**. containerd returns `NotFound` — the **tag is absent from Harbor**:

```bash
HARBOR_USER=$(vault kv get -field=user  kv/harbor/secret)
HARBOR_TOKEN=$(vault kv get -field=token kv/harbor/secret)
curl -su "$HARBOR_USER:$HARBOR_TOKEN" \
  "https://harbor.jrclabs.xyz/api/v2.0/projects/alarmify/repositories/alarmify-schedule-api/artifacts?page_size=20" \
  | jq -r '.[].tags[]?.name'
```

Push the missing tag, or correct `image.tag` in `values.yaml` and let ArgoCD sync.
🚫 Do **not** `kubectl set image` — `selfHeal: true` reverts it.

### 🔎 ESO controller logs

```bash
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=200 \
  | grep alarmify-schedule-api | tail -5
```

---

## 🧱 Guardrails

- 🚫 **Never** commit a Vault value to this repo.
- 🚫 **Never** `kubectl edit secret alarmify-schedule-api-vars` — ESO owns it
  (`creationPolicy: Owner`) and overwrites on the next refresh.
- 🚫 **Never** `kubectl label secret -n argocd local ...` — `selfHeal: true` reverts it.
- ⚠️ `deletionPolicy: Retain` — deleting the ExternalSecret leaves the K8s Secret behind.
- ♻️ `postgres/credentials` and `harbor` are **shared** — force-sync every namespace after a
  rotation.
- 🪫 An **empty** app object is a valid, intentional state here. Don't "fix" it by inventing keys.

---

## 📚 Related

- 📖 [`README.md`](./README.md) — chart design notes
- 🗝️ [`../vault.md`](../vault.md) — every `alarmify-*` app's Vault objects
- 🔑 `helmcharts/external-secrets/` — `ClusterSecretStore/vault-secretstore`
