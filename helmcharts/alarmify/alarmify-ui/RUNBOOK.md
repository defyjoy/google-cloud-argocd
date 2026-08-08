# 🔐 Tactical Runbook — `alarmify-ui` Vault secrets

> 🎯 **Scope:** every Vault object this chart reads, how to create/rotate/verify it, and how to
> force the sync. Chart context: [`README.md`](./README.md). All-apps reference:
> [`../vault.md`](../vault.md).

---

## 🟢 CURRENT STATE (dev, 2026-07-31)

> ### ✅ Vault is **healthy** and the app is **Running**
>
> ```
> dev-alarmify-ui                              1/1 Running
> ExternalSecret/alarmify-ui-vars              SecretSynced   Ready=True
> ExternalSecret/harbor-registry-credentials   SecretSynced   Ready=True
> ```
>
> This is the **only** `alarmify-*` app that is fully up. **No Vault action needed right now.**
>
> ### ⚠️ But it has nothing to talk to
>
> All four `backendUrls` targets (incident / ingest / schedule / identity) are in
> `ImagePullBackOff`, and three of them are additionally missing their Vault objects. Login will
> work (Zitadel is external); **every data view will error.** Fix the backends via their own
> runbooks.

---

## 🚨 The one secret that will take the site down

> ### 🔑 `SESSION_SECRET`
>
> It derives the **AES-256-GCM key** for the httpOnly session cookie.
>
> - 🔻 **Missing or empty** → the BFF cannot create sessions; login loops or 500s.
> - 🔄 **Changed** → **every existing session is invalidated instantly**. Every logged-in user is
>   signed out. Rotate deliberately, not casually.
>
> 🚫 Never let this fall back to a development default in a real deployment.

---

## 🗺️ Secret map

| # | Vault object (KV v2, mount `kv`) | → K8s Secret | Consumed as |
|---|---|---|---|
| 1️⃣ | `alarmify/dev/alarmify-ui` (`SESSION_SECRET`) | `alarmify-ui-vars` | `envFrom` |
| 2️⃣ | `alarmify/management/zitadel` (🏗️ Terraform-owned) | `alarmify-ui-vars` | `envFrom` |
| 3️⃣ | `alarmify/dev/harbor` (shared) | `alarmify-ui-registry` | `imagePullSecrets` |

🔁 `1️⃣` arrives via `spec.dataFrom.extract` (whole object). `2️⃣` arrives via **`spec.data`** —
one explicit `remoteRef` per key, listed as `externalSecrets.secretKeyRefs` in `values.yaml`.

> 🐘 **No shared `postgres/credentials`** — the UI has no database.
> 🔓 **Nothing shadows Vault here.** This chart has no `auth.zitadel*` values (its only `auth.*`
> value is `appBaseUrl`), so unlike incident/ingest ever did, what Vault holds is what the app gets.

> 🔐 **Why key-by-key and not `extract`?** `alarmify/management/zitadel` also holds the
> identity-api provisioner key and the Kiali client secret. An `extract` would copy **every**
> field into this namespace, so each key is pulled by name instead.

> 🥇 **`data` beats `dataFrom` — and that matters here.** `alarmify/dev/alarmify-ui` still carries
> its own stale `ZITADEL_*` copies. ESO's `GetProviderSecretData` resolves all `dataFrom` entries
> first, then `data`, so the Terraform-owned values win. The stale copies are safe to prune.

> 🧬 **Conditional rendering:** both the ExternalSecret and the deployment's `envFrom` are wrapped in
> `{{- if .Values.externalSecrets.appVarsKeys }}`. Emptying that list makes the chart render **no
> ExternalSecret and no `envFrom`** — the pod starts with no Zitadel config and no session key.

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
vault kv get -format=json kv/alarmify/dev/alarmify-ui | jq -r '.data.data | keys[]'
```

---

## 1️⃣ The app object

**`kv/alarmify/dev/alarmify-ui`**

| Key | Value | Notes |
|---|---|---|
| `SESSION_SECRET` | 🔑 `REPLACE_WITH_STRONG_RANDOM` | derives the AES-256-GCM key for the httpOnly session cookie; **must** be set for real deploys. **The only key this object still owns.** |
| ~~`ZITADEL_ISSUER`~~ | *(stale leftover)* | 🧹 **Prunable.** Overridden by `spec.data` from `alarmify/management/zitadel` |
| ~~`ZITADEL_CLIENT_ID`~~ | *(stale leftover)* | 🧹 **Prunable.** Same override |
| ~~`ZITADEL_PROJECT_ID`~~ | *(stale leftover)* | 🧹 **Prunable.** Same override |

```bash
vault kv put kv/alarmify/dev/alarmify-ui \
  SESSION_SECRET='REPLACE_WITH_STRONG_RANDOM'
```

> 🛑 **This object already exists and is syncing.** A bare `vault kv put` **replaces the whole
> object** and would destroy the live `SESSION_SECRET`, signing out every user. To change one key,
> always use:
>
> ```bash
> vault kv patch kv/alarmify/dev/alarmify-ui SESSION_SECRET='...'
> ```

> 🧹 **The `ZITADEL_*` keys here are dead weight.** They predate the move to
> `alarmify/management/zitadel` and hold the retired project ID. `spec.data` outranks
> `spec.dataFrom`, so they have no effect — but pruning them removes a trap for the next reader:
>
> ```bash
> vault kv get -format=json kv/alarmify/dev/alarmify-ui \
>   | jq '.data.data | del(.ZITADEL_ISSUER, .ZITADEL_CLIENT_ID, .ZITADEL_PROJECT_ID)' > /tmp/ui.json
> vault kv put kv/alarmify/dev/alarmify-ui @/tmp/ui.json && rm -f /tmp/ui.json
> ```

---

## 1️⃣b Zitadel config (🏗️ Terraform-owned — do not hand-write)

**`kv/alarmify/management/zitadel`** — written by `alarmify-common-infra/terraform/zitadel`
(`vault.tf`) via `vault_kv_secret_v2`, which writes **exactly** its `data_json`. Keys added by
hand **disappear on the next `terraform apply`**. Change Terraform and re-apply instead.

One name differs between Vault and the app, so read this before assuming a 1:1 mapping:

| Env var (what the BFF reads) | ← Vault key | Notes |
|---|---|---|
| `ZITADEL_ISSUER` | `ZITADEL_ISSUER` | OIDC discovery base |
| `ZITADEL_PROJECT_ID` | `ZITADEL_PROJECT_ID` | scopes the hosted login to the Alarmify project |
| `ZITADEL_CLIENT_ID` | 🔀 **`ZITADEL_UI_CLIENT_ID`** | public **PKCE** client for the BFF login flow (`bff/zitadelOidc.ts:31`). Terraform prefixes it `UI_` to distinguish it from the Kiali client |

Must match a real PKCE client with `https://ui.workquark.org` registered as a redirect URI —
which is exactly what Terraform guarantees, hence the "don't hand-write" rule.

### 🔄 Rotating `SESSION_SECRET` (signs everyone out)

```bash
NEW=$(openssl rand -base64 48 | tr -d '\n')
vault kv patch kv/alarmify/dev/alarmify-ui SESSION_SECRET="$NEW"

kubectl -n alarmify-ui annotate externalsecret alarmify-ui-vars \
  force-sync="$(date +%s)" --overwrite
kubectl -n alarmify-ui rollout restart deploy/dev-alarmify-ui
```

⚠️ Announce this first — it is a **user-visible** action.

---

## 2️⃣ Harbor image-pull credentials

**`kv/alarmify/dev/harbor`**, single field `.dockerconfigjson`. Shared by all six `alarmify-*`
namespaces.

> 🟢 **Currently healthy** — and notably, `…/alarmify-ui:v0.0.115` is the **only** alarmify tag that
> actually resolves in Harbor today. Only touch this on rotation.

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

⚠️ Rotating this affects **all six** namespaces — force-sync each one:

```bash
for ns in alarmify-ui alarmify-identity-api alarmify-incident-api \
          alarmify-schedule-api alarmify-ingest-api alarmify-event-worker; do
  kubectl -n "$ns" annotate externalsecret harbor-registry-credentials \
    force-sync="$(date +%s)" --overwrite
done
```

---

## 🔄 Force a sync

```bash
kubectl -n alarmify-ui annotate externalsecret alarmify-ui-vars \
  force-sync="$(date +%s)" --overwrite
kubectl -n alarmify-ui get externalsecret -w

kubectl -n alarmify-ui rollout restart deploy/dev-alarmify-ui
kubectl -n alarmify-ui rollout status  deploy/dev-alarmify-ui
```

`refreshInterval: 1h`, and env vars are injected at pod start — both steps are required.

---

## ✅ Verify

```bash
# Vault side — key names only, never print SESSION_SECRET
vault kv get -format=json kv/alarmify/dev/alarmify-ui     | jq -r '.data.data | keys[]'
vault kv get -format=json kv/alarmify/management/zitadel  | jq -r '.data.data | keys[]'

# The app object needs only SESSION_SECRET now
vault kv get -format=json kv/alarmify/dev/alarmify-ui \
  | jq -r '["SESSION_SECRET"] - (.data.data | keys)
           | if length==0 then "OK: SESSION_SECRET present" else "MISSING: \(.)" end'

# The three Zitadel keys must exist under their *Terraform* names
vault kv get -format=json kv/alarmify/management/zitadel \
  | jq -r '["ZITADEL_ISSUER","ZITADEL_UI_CLIENT_ID","ZITADEL_PROJECT_ID"] - (.data.data | keys)
           | if length==0 then "OK: all present" else "MISSING: \(.)" end'

# Kubernetes side — key names in the Secret
kubectl -n alarmify-ui get secret alarmify-ui-vars \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

kubectl -n alarmify-ui get externalsecret alarmify-ui-vars \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'

# End-to-end: OIDC discovery must be reachable from the pod
kubectl -n alarmify-ui exec deploy/dev-alarmify-ui -- \
  wget -qO- https://zitadel.workquark.org/.well-known/openid-configuration | head -c 200
```

---

## 🧭 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Login loops, or 500 on callback | `SESSION_SECRET` missing/empty | [1️⃣](#1️⃣-the-app-object) — then force-sync + restart |
| Everyone suddenly signed out | `SESSION_SECRET` was rotated | Expected; sessions cannot survive a key change |
| Zitadel `invalid_client` / `unauthorized_client` | `ZITADEL_CLIENT_ID` wrong, or the client is not a **public PKCE** client | Re-run the Zitadel Terraform; verify the client type |
| `ZITADEL_CLIENT_ID` "missing" from Vault | Looking for that name in `alarmify/management/zitadel` — there isn't one | It maps from **`ZITADEL_UI_CLIENT_ID`**; see [1️⃣b](#1️⃣b-zitadel-config-️-terraform-owned--do-not-hand-write) |
| A Zitadel key reverted after being "fixed" in Vault | `terraform apply` rewrote `alarmify/management/zitadel` wholesale | Change `terraform/zitadel/vault.tf` and re-apply — never `vault kv patch` that object |
| Zitadel `redirect_uri_mismatch` | `auth.appBaseUrl` ≠ the redirect URI registered in Zitadel | Both must be `https://ui.workquark.org` — `values/dev.yaml` + Zitadel |
| `SecretSyncedError` + `err: Secret does not exist` | `kv/alarmify/dev/alarmify-ui` deleted | Recreate → [1️⃣](#1️⃣-the-app-object) |
| Secret suddenly lost keys | Someone used `vault kv put` (replaces whole object) instead of `patch` | Rewrite the full object, force-sync, restart |
| No `alarmify-ui-vars` Secret at all, no ES object | `externalSecrets.appVarsKeys` was emptied — the whole template is conditional | Restore the list in `values.yaml` |
| Intermittent **502/503** on `ui.workquark.org` | The Node/Envoy keepalive race | The `DestinationRule` mitigates it — see [`README.md`](./README.md#-the-keepalive-destinationrule--read-this-before-deleting-it). Confirm `idleTimeout` is still **< 5s** |
| Pages load, all data views error | The four backend APIs are down | Their own runbooks — **this is the current state** |
| `ui.workquark.org` doesn't resolve | external-dns `target` missing | `target` lives on the **`istio-gateway` `Gateway`**, never on the HTTPRoute |
| `SecretSyncedError` + connection refused / TLS | dev reaches Vault over the **public** `https://vault.workquark.org` | Check the Cloudflare tunnel + DNS; accepted risk for dev |

### 🔎 ESO controller logs

```bash
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=200 \
  | grep alarmify-ui | tail -5
```

---

## 🧱 Guardrails

- 🛑 **Use `vault kv patch`, not `put`, on this object** — it holds a live `SESSION_SECRET` that a
  full `put` would destroy, signing out every user.
- 🔇 **Never print `SESSION_SECRET`.** Use `jq -r '.data.data | keys[]'` to inspect, not `vault kv get`.
- 🚫 **Never** commit a Vault value to this repo.
- 🚫 **Never** `kubectl edit secret alarmify-ui-vars` — ESO owns it (`creationPolicy: Owner`) and
  overwrites on the next refresh.
- 🚫 **Never** `kubectl label secret -n argocd local ...` — `selfHeal: true` reverts it.
- ⚠️ `deletionPolicy: Retain` — deleting the ExternalSecret leaves the K8s Secret behind.
- 🏗️ Zitadel keys are Terraform-managed; hand-edits in Vault drift from
  `alarmify-common-infra/terraform/zitadel`.
- 🌍 This is the **public** app. Treat every change here as user-visible.

---

## 📚 Related

- 📖 [`README.md`](./README.md) — chart design notes, incl. the keepalive DestinationRule write-up
- 🗝️ [`../vault.md`](../vault.md) — every `alarmify-*` app's Vault objects
- 🏗️ `alarmify-common-infra/terraform/zitadel` — seeds this app's Vault object
- ☁️ `helmcharts/cloudflared/values/dev.yaml` — the dedicated dev tunnel
- 🚪 `helmcharts/istio/istio-gateway/values/dev.yaml` — where the external-dns `target` lives
