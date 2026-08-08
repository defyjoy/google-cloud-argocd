# 🔐 Tactical Runbook — `alarmify-event-worker` Vault secrets

> 🎯 **Scope:** every Vault object this chart reads, how to create/rotate/verify it, and how to
> force the sync. Chart context lives in [`README.md`](./README.md); the all-apps reference is
> [`../vault.md`](../vault.md).

---

## 🚨 CURRENT BLOCKER (dev)

> ✅ **`kv/alarmify/dev/alarmify-event-worker` EXISTS.** Verified 2026-08-01: version 1, created
> 2026-07-31T01:52Z, holding `NATS_USER` and `NATS_PASSWORD`. This runbook previously claimed it
> did not exist — that was true only in the window before it was seeded. **No Vault action needed.**
>
> 🚫 **This chart is unaffected by the Zitadel consolidation.** The event worker reads **no
> `ZITADEL_*` env vars** (verified against the source), so it has no `externalSecrets.secretKeyRefs`
> block and does not reference `alarmify/management/zitadel`.
>
> ⚠️ **Independent, possibly still open:** `ImagePullBackOff` on
> `harbor.workquark.org/alarmify/alarmify-event-worker:v0.0.10`. Fixing Vault alone will **not**
> bring the pod up — see [🖼️ Image pull](#️-image-pull-second-blocker). *(Unverified as of
> 2026-08-01 — the robot creds at `kv/harbor/secret` no longer resolve, so Harbor returns 401.)*

---

## 🗺️ Secret map

| # | Vault object (KV v2, mount `kv`) | → K8s Secret | Consumed as |
|---|---|---|---|
| 1️⃣ | `alarmify/dev/alarmify-event-worker` | `alarmify-event-worker-vars` | `envFrom` |
| 2️⃣ | `alarmify/dev/postgres/credentials` (shared) | `alarmify-event-worker-vars` | `envFrom` |
| 3️⃣ | `alarmify/dev/harbor` (shared) | `alarmify-event-worker-registry` | `imagePullSecrets` |

🔁 Both `1️⃣` and `2️⃣` feed the **same** Secret via `dataFrom.extract`, in that order.
`mergePolicy: Replace` ⇒ **the object listed last wins** on any overlapping key, so the shared
Postgres object overrides `DB_*` on the app object.

> 🧷 **`dbHostOverride` beats Vault entirely.** `values/dev.yaml` injects `DB_HOST` as a literal
> `env` var, and Kubernetes ranks `env` above `envFrom`. Effective dev value is always
> `postgresql-cluster-rw.cloudnative-pg-system.svc.cluster.local`, whatever Vault says.
> Same applies to `NATS_USER`.

---

## 🧰 Prerequisites (once per shell)

```bash
export VAULT_ADDR="https://vault.workquark.org"
vault login            # or: export VAULT_TOKEN=...
vault token lookup     # sanity check

export KUBECONFIG=~/.kube/talos-dev.yaml   # this app runs on dev only
```

> 📎 **KV v2 path note:** manifests use the *logical* path (`alarmify/dev/...`); the CLI needs the
> mount prefix (`kv/alarmify/dev/...`).

Survey before you touch anything:

```bash
vault kv list kv/alarmify/dev
vault kv get -format=json kv/alarmify/dev/alarmify-event-worker | jq -r '.data.data | keys[]'
vault kv get -format=json kv/alarmify/dev/postgres/credentials  | jq -r '.data.data | keys[]'
```

---

## 1️⃣ Create the app object

**`kv/alarmify/dev/alarmify-event-worker`**

| Key | Value | Notes |
|---|---|---|
| `NATS_USER` | `alarmify-event-processor` | must match the account in `helmcharts/nats/values.yaml`; falls back to `NATS_USERNAME` |
| `NATS_PASSWORD` | 🔑 `REPLACE_WITH_STRONG_PASSWORD` | paired with `NATS_USER` |

```bash
vault kv put kv/alarmify/dev/alarmify-event-worker \
  NATS_USER='alarmify-event-processor' \
  NATS_PASSWORD='REPLACE_WITH_STRONG_PASSWORD'
```

> 💡 `vault kv put` **replaces the whole object**. To add a key without clobbering the rest, use
> `vault kv patch`.

Generate a password instead of inventing one:

```bash
NATS_PW=$(openssl rand -base64 32 | tr -d '\n')
vault kv put kv/alarmify/dev/alarmify-event-worker \
  NATS_USER='alarmify-event-processor' \
  NATS_PASSWORD="$NATS_PW"
```

⚠️ The same password must exist on the NATS side (`helmcharts/nats` account config) or the worker
connects and gets `Authorization Violation`.

---

## 2️⃣ Shared Postgres credentials

**`kv/alarmify/dev/postgres/credentials`** — shared with identity-api, incident-api, schedule-api.
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

🚫 Never set `DB_HOST` to the LAN name `cloudnative-postgres.home.arpa` — that hairpins through the
istio-gateway TCPRoute and ambient clients get `EOF`.

Rotate only the password, leaving every other field intact:

```bash
vault kv patch kv/alarmify/dev/postgres/credentials DB_PASSWORD='NEW_PASSWORD'
```

Then force-sync **every** consumer (see [🔄 Force a sync](#-force-a-sync)):

```bash
for ns in alarmify-identity-api alarmify-incident-api alarmify-schedule-api alarmify-event-worker; do
  kubectl -n "$ns" annotate externalsecret "${ns}-vars" force-sync="$(date +%s)" --overwrite
done
```

---

## 3️⃣ Harbor image-pull credentials

**`kv/alarmify/dev/harbor`**, single field `.dockerconfigjson`. Shared by all six `alarmify-*`
namespaces; each chart copies it into `<app>-registry`.

> 🟢 **Currently healthy** in `alarmify-event-worker` — `harbor-registry-credentials` reports
> `SecretSynced`, and `Secret/alarmify-event-worker-registry` exists. Only touch this on rotation.

> 🚫 **Store raw JSON, not base64.** ESO base64-encodes on write. Pre-encoding double-encodes and
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

jq -e '.auths | keys' dockerconfig.json
jq -r '.auths["harbor.workquark.org"].auth' dockerconfig.json | base64 -d   # -> user:token

vault kv put kv/alarmify/dev/harbor .dockerconfigjson=@dockerconfig.json
shred -u dockerconfig.json 2>/dev/null || rm -f dockerconfig.json
```

> 💲 **Harbor robot names contain `$`.** Always source them via `$(...)` as above. Typed by hand,
> use **single** quotes (`'robot$alarmify+puller'`) — in double quotes the shell expands
> `$alarmify` to empty and Harbor rejects the login.

---

## 🔄 Force a sync

`refreshInterval: 1h`, so ESO will not notice a Vault write immediately. Kick it:

```bash
kubectl -n alarmify-event-worker annotate externalsecret alarmify-event-worker-vars \
  force-sync="$(date +%s)" --overwrite

kubectl -n alarmify-event-worker annotate externalsecret harbor-registry-credentials \
  force-sync="$(date +%s)" --overwrite
```

Watch it flip to `SecretSynced` / `Ready=True`:

```bash
kubectl -n alarmify-event-worker get externalsecret -w
```

Then restart the worker to pick up new env values (env vars are injected at pod start, **not**
hot-reloaded):

```bash
kubectl -n alarmify-event-worker rollout restart deploy/dev-alarmify-event-worker
kubectl -n alarmify-event-worker rollout status  deploy/dev-alarmify-event-worker
```

---

## ✅ Verify

```bash
# Vault side — key names only, no values
vault kv get -format=json kv/alarmify/dev/alarmify-event-worker | jq -r '.data.data | keys[]'
vault kv get -format=json kv/alarmify/dev/postgres/credentials  | jq -r '.data.data | keys[]'
vault kv get -field=.dockerconfigjson kv/alarmify/dev/harbor | jq .   # must be JSON, not base64

# Kubernetes side — key names that landed in the Secret (no values)
kubectl -n alarmify-event-worker get secret alarmify-event-worker-vars \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

# ExternalSecret conditions
kubectl -n alarmify-event-worker get externalsecret alarmify-event-worker-vars \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'

# What the container actually resolved (secrets included — redact before pasting anywhere)
kubectl -n alarmify-event-worker exec deploy/dev-alarmify-event-worker -- env | sort | grep -E '^(NATS|DB|ENVIRONMENT|DEBUG)_?'
```

---

## 🧭 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `SecretSyncedError` + `err: Secret does not exist` | The Vault object in `appVarsKeys[N]` is missing. `dataFrom[0]` = app object, `dataFrom[1]` = shared postgres. | Create it → [1️⃣](#1️⃣-create-the-app-object) / [2️⃣](#2️⃣-shared-postgres-credentials) |
| `SecretSyncedError` + `permission denied` / `403` | Vault token in `external-secrets/vault-token` expired or lacks a policy on the path | Renew/replace the token Secret in ns `external-secrets` |
| `SecretSyncedError` + connection refused / TLS error | dev reaches Vault over the **public** `https://vault.workquark.org` (no in-cluster Vault). Cloudflare/DNS hiccup takes it out. | Check the tunnel + `vault.workquark.org` resolution; this cross-cluster dependency is a known, accepted risk for dev |
| Secret exists but pod still has old values | Env vars are injected at pod start | `kubectl rollout restart` |
| Worker logs `Authorization Violation` | `NATS_PASSWORD` in Vault ≠ the account password in `helmcharts/nats` | Align both, then force-sync + restart |
| Worker exits at startup complaining about `FilterSubject` | Live durable's filter ≠ `nats.subject`. **By design** — see README. | `nats consumer edit ALARMIFY_EVENTS_RAW alarmify-event-processor --filter "alarmify.events.raw.*"` |
| DB connections go to `localhost:5432` | `DB_*` never reached the container (Secret missing) | Fix the ExternalSecret first |
| `ImagePullBackOff` | Harbor object or the image tag | See below |

### 🖼️ Image pull (second blocker)

`Secret/alarmify-event-worker-registry` exists and the ES is `SecretSynced`, so the **credentials
are not the problem** here. Check the tag exists:

```bash
# Does v0.0.10 exist in Harbor? (Chart.yaml says appVersion v0.0.9)
HARBOR_USER=$(vault kv get -field=user  kv/harbor/secret)
HARBOR_TOKEN=$(vault kv get -field=token kv/harbor/secret)
curl -su "$HARBOR_USER:$HARBOR_TOKEN" \
  "https://harbor.workquark.org/api/v2.0/projects/alarmify/repositories/alarmify-event-worker/artifacts?page_size=20" \
  | jq -r '.[].tags[]?.name'

kubectl -n alarmify-event-worker describe pod -l app.kubernetes.io/name=alarmify-event-worker \
  | sed -n '/Events:/,$p'
```

If the tag is absent, push it — or correct `image.tag` in `values.yaml` and let ArgoCD sync.
🚫 Do **not** `kubectl set image`: `selfHeal: true` reverts it on the next reconcile.

### 🔎 ESO controller logs

```bash
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=200 \
  | grep alarmify-event-worker | tail -5
```

---

## 🧱 Guardrails

- 🚫 **Never** commit a Vault value to this repo. Charts reference *paths*, never secrets.
- 🚫 **Never** `kubectl edit secret alarmify-event-worker-vars` — ESO owns it
  (`creationPolicy: Owner`) and overwrites on the next refresh.
- 🚫 **Never** `kubectl label secret -n argocd local ...` to enable a component — `selfHeal: true`
  reverts it. Add the label in `helmcharts/argocd/templates/cluster/local-cluster-secret.yaml`.
- ⚠️ `deletionPolicy: Retain` — deleting the ExternalSecret leaves the K8s Secret behind. Clean up
  manually if you truly want it gone.
- ♻️ `alarmify/dev/postgres/credentials` and `alarmify/dev/harbor` are **shared**. Rotating either
  affects all `alarmify-*` apps; force-sync every namespace.

---

## 📚 Related

- 📖 [`README.md`](./README.md) — chart design notes
- 🗝️ [`../vault.md`](../vault.md) — every `alarmify-*` app's Vault objects
- 🔑 `helmcharts/external-secrets/` — `ClusterSecretStore/vault-secretstore` (dev override →
  `https://vault.workquark.org`)
- 📨 `helmcharts/nats/` — JetStream bootstrap + NATS accounts
