# Zitadel

Wrapper around the [official Zitadel Helm chart](https://github.com/zitadel/zitadel-charts) (chart `10.0.4`, app `v4.15.3`). Deployed by the `zitadel` ApplicationSet (`helmcharts/argocd-apps/templates/applicationsets/zitadel-as.yaml`) to the `zitadel` namespace on clusters labelled `zitadel: "true"`.

Zitadel is the platform identity provider replacing `alarmify-auth-api` — see `alarmify-docs/docs/auth/adr-001-zitadel-as-identity-provider.md`.

## Topology

Two domains, one instance — see `https://github.com/Alarmify/alarmify-docs/blob/main/docs/auth/zitadel-public-exposure.md`
for the hardening/rollout runbook.

```text
Public ── https://zitadel.jrclabs.xyz ──▶ Cloudflare (edge TLS, WAF/Access;
              │                              /system + /debug blocked at CF —
              │                              gateway pathGuards empty while TCP
              │                              listeners share istio-gateway)
              └─ cloudflared tunnel ──▶ istio-gateway (listener `http`)
                                            ├─ HTTPRoute /ui/v2/login ▶ zitadel-login:3000  (Login UI v2)
                                            └─ HTTPRoute /            ▶ zitadel:8080        (API, h2c)

LAN ── https://zitadel.home.arpa ──▶ istio-gateway (listener `https`, stepca SAN cert)
                                            └─ HTTPRoute /            ▶ zitadel:8080  (terraform gRPC, admin)
                                               x-zitadel-instance-host pins instance resolution
                                               (see "Two domains, one instance"); no login route
                                               here — Login UI v2 is public-only

zitadel pods ── postgresql-cluster-rw.cloudnative-pg-system.svc:5432 ──▶ CNPG (direct; CNPG out of ambient)
LAN clients  ── cloudnative-pg.home.arpa:5432 ──▶ Istio Gateway (listener `postgres`, TCPRoute)
                                                     └─▶ postgresql-cluster-rw (CNPG, cloudnative-pg-system)
```

## Two domains, one instance (LAN + public)

Zitadel decides **which instance** serves a request by matching the inbound host against the
instance domains registered in its **database** — this is application state, not Helm config.
Only `ExternalDomain` (`zitadel.jrclabs.xyz`) is registered, so a LAN request arriving as
`zitadel.home.arpa` was rejected even though DNS, the HTTPRoute and the stepca cert were all
correct:

```text
unable to set instance using origin &{zitadel.home.arpa https}
(ExternalDomain is zitadel.jrclabs.xyz): Message=Instance not found
```

`x-zitadel-instance-host` is first in Zitadel's `InstanceHostHeaders` precedence, so the
zitadel HTTPRoute pins it to the registered domain. This is what makes the LAN hostname work,
and it is set (not added) at the gateway so a client cannot spoof it:

```yaml
# values.yaml → zitadel.gateway.httpRoute
filters:
  - type: RequestHeaderModifier
    requestHeaderModifier:
      set:
        - name: x-zitadel-instance-host
          value: zitadel.jrclabs.xyz
```

Verify from a LAN client (the gateway's `http` listener, h2c — no TLS needed for the check):

```bash
# without the header → "Instance not found"; with it → the discovery document
curl -s --http2-prior-knowledge -H 'Host: zitadel.home.arpa' \
  -H 'x-zitadel-instance-host: zitadel.jrclabs.xyz' \
  http://192.168.3.10/.well-known/openid-configuration
```

### What this does and does not give you

**Does:** `zitadel.home.arpa` serves the API and Console over the LAN, bypassing Cloudflare
entirely — which is what Terraform's gRPC provider needs, since Cloudflare's edge rejects
`Content-Type: application/grpc` with a 403 unless gRPC is enabled on the zone, and gRPC over a
Tunnel *public hostname* is [not supported by Cloudflare](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/use-cases/grpc/).

**Does not:** change the URLs Zitadel *emits*. The issuer, redirects and links still say
`https://zitadel.jrclabs.xyz`, so browser login flows on the LAN hostname bounce to the public
domain. Making Zitadel emit `zitadel.home.arpa` requires **also** registering it as a *trusted*
domain via the API and asserting `x-zitadel-public-host`; without the registration Zitadel rejects
the request outright:

```text
Parent=(public domain "zitadel.home.arpa" not trusted)
```

**Do not add `x-zitadel-public-host` to the filter above.** This route serves both hostnames from
one `hostnames` list with a single shared `filters` block, so that header would rewrite the issuer
for **public** traffic too and break every OIDC client (alarmify-ui, JWKS verification in
ingest/incident). Nor can it be pushed per-request from Terraform: the zitadel provider's
`transport_headers` is not applied to the OIDC discovery request (verified against v3.3.0), and
discovery is where the issuer is read.

The supported fix is to register `zitadel.home.arpa` as a **custom domain** via
`InstanceService/v2` `AddCustomDomain`, which makes it a real instance domain — Zitadel then routes
*and* issues for it natively. **That registration supersedes the filter above: once it exists,
delete the `filters` block**, or it keeps forcing resolution back to the public name and the LAN
issuer stays wrong. See `terraform/zitadel/README.md` §3 in `alarmify-common-infra`.

Note trusted domains are *not* used to route requests to an instance ([docs](https://zitadel.com/docs/apis/resources/admin/admin-service-list-instance-trusted-domains)),
so `AddTrustedDomain` alone would not have fixed instance resolution — the header above is what
does that. Registering a domain is a one-time API call, not chart config
(`InstanceService/v2` `AddCustomDomain` / `AddTrustedDomain`; both exist on v4.15.3 and are
reachable over the JSON/Connect path, which Cloudflare does not block).

## Prerequisites (all in this repo)

| Dependency | Where | Notes |
|---|---|---|
| CNPG cluster | `helmcharts/cloudnative-pg` | `enableSuperuserAccess: true` + `postgresql-superuser` secret; the Zitadel init Job uses it to create the `zitadel` DB and role — no CNPG manifest changes needed |
| Postgres TCP edge | `helmcharts/cloudnative-pg/templates/postgresql-tcproute.yaml` | LAN: `cloudnative-pg.home.arpa` → Istio TCPRoute → `postgresql-cluster-rw:5432`; in-cluster (zitadel): Service DNS direct |
| DNS | `helmcharts/argocd/templates/kube-system/core-dns-cofigmap.yaml` | `zitadel.home.arpa → 192.168.3.10` (the istio-gateway LB address) |
| Edge TLS | `helmcharts/stepca/values.yaml` `edgeGatewayTls.dnsNames` | `zitadel.home.arpa` added to the SAN list (cert-manager re-issues the gateway cert) |
| Cluster label | ArgoCD cluster secret | `zitadel: "true"` to enroll a cluster |

## Secrets to change before production

All placeholders live in `values.yaml` (repo convention — same as `helmcharts/cloudnative-pg`). Secrets live in the **`kv`** KV v2 engine (mount `kv`, the `vault-secretstore` `ClusterSecretStore`), under the `alarmify/local/zitadel/*` prefix that `values.yaml`'s `externalSecrets.*.vaultPath` entries point at. Each row maps the Vault path to its field key, the matching inline `values.yaml` key, a dummy value, and how to source it.

| Vault path (`kv` mount) | Key | `values.yaml` key | Dummy value | Where to find / how to generate |
|---|---|---|---|---|
| `kv/alarmify/local/zitadel/masterkey` | `masterkey` | `zitadel.zitadel.masterkey` | `ChangeMeZitadelMasterkey32Char!!` | **Exactly 32 bytes.** `LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom \| head -c 32` (`LC_ALL=C` avoids `tr: Illegal byte sequence` on macOS). **Immutable after first install** — changing it makes encrypted data unreadable. |
| `kv/alarmify/local/zitadel/database` | `adminPassword` | `zitadel.zitadel.secretConfig.Database.Postgres.Admin.Password` | `postgres-change-me-in-production` | Must **match** the CNPG `postgresql-superuser` Secret (`helmcharts/cloudnative-pg`): `kubectl get secret postgresql-superuser -n cloudnative-pg-system -o jsonpath='{.data.password}' \| base64 -d`. |
| `kv/alarmify/local/zitadel/database` | `userPassword` | `zitadel.zitadel.secretConfig.Database.Postgres.User.Password` | `zitadel-change-me-in-production` | Free choice — the password the init Job sets for the `zitadel` role. Generate e.g. `openssl rand -base64 24`. |
| `kv/alarmify/local/zitadel/login-service-key` | `tls.crt`, `tls.key` | `zitadel.login.loginServiceKeySecretName` | *(RSA keypair PEM)* | RSA keypair the Login UI signs RS256 with: `openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=login-service" -keyout tls.key -out tls.crt`. See §"One-time: login service keypair". |

### Vault commands (one per row above)

Run these from a host that has **both** `vault` and `kubectl` (point `vault` at the cluster via port-forward — `kubectl port-forward -n vault svc/local-vault 8200:8200` — then `export VAULT_ADDR=http://localhost:8200` and `vault login <root-token>`). The `kubectl` in step 2 fetches the CNPG password, so don't run these from inside the Vault pod (no `kubectl` there). Paths use the **`kv`** KV v2 mount, so `vault kv put kv/alarmify/...` stores under `kv/data/alarmify/...` and ESO reads the key `alarmify/...` against the `kv` mount.

```bash
# 1. masterkey — exactly 32 bytes (LC_ALL=C avoids "tr: Illegal byte sequence" on macOS)
MASTERKEY=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
vault kv put kv/alarmify/local/zitadel/masterkey masterkey="$MASTERKEY"

# 2. database — adminPassword MUST match the CNPG postgresql-superuser secret; userPassword is free
vault kv put kv/alarmify/local/zitadel/database \
  adminPassword="$(kubectl get secret postgresql-superuser -n cloudnative-pg-system -o jsonpath='{.data.password}' | base64 -d)" \
  userPassword="$(openssl rand -base64 24)"

# 3. login-service-key — RSA keypair (RS256); read the tls.crt/tls.key files created by openssl above
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=login-service" \
  -keyout /tmp/tls.key -out /tmp/tls.crt
vault kv put kv/alarmify/local/zitadel/login-service-key \
  tls.crt="$(cat /tmp/tls.crt)" \
  tls.key="$(cat /tmp/tls.key)"
```

> Verify with `vault kv get kv/alarmify/local/zitadel/masterkey` (repeat per path). ExternalSecrets read these via the `vault-secretstore` `ClusterSecretStore` — see §"Vault + External Secrets".

For production, **do not keep these in `values.yaml`** — use Vault + External Secrets instead (see below).

## Vault + External Secrets

Enabling `externalSecrets.enabled: true` deploys three `ExternalSecret` resources (sync-wave `-1`, before Zitadel's own resources) that pull credentials from HashiCorp Vault via the `vault-secretstore` `ClusterSecretStore` (from `helmcharts/external-secrets`). The ExternalSecrets create Kubernetes Secrets that the upstream Zitadel chart consumes directly, so no plaintext credentials live in Git.

### Secret layout in Vault (KV v2, `kv` mount)

| Vault path (`kv` mount) | Fields | `values.yaml` `vaultPath` | Consumed by |
|---|---|---|---|
| `kv/alarmify/local/zitadel/masterkey` | `masterkey` | `externalSecrets.masterkey.vaultPath` | `masterkeySecretName` |
| `kv/alarmify/local/zitadel/database` | `adminPassword`, `userPassword` | `externalSecrets.database.vaultPath` | `configSecretName` |
| `kv/alarmify/local/zitadel/login-service-key` | `tls.crt`, `tls.key` | `externalSecrets.loginServiceKey.vaultPath` | `loginServiceKeySecretName` |

### Step 1 — Write secrets to Vault

See §"Vault commands (one per row above)" under [Secrets to change before production](#secrets-to-change-before-production) — the three `vault kv put kv/alarmify/local/zitadel/*` commands write exactly these paths. `adminPassword` **must** match the CNPG `postgresql-superuser` Secret in `helmcharts/cloudnative-pg`.

### Step 2 — Vault policy

The `external-secrets-operator` role in `helmcharts/vault/VAULT-KUBERNETES-AUTH.md` uses `external-secrets-policy` which already grants `read` on `kv/data/*`. For tighter scoping, create a dedicated Zitadel policy:

```bash
vault policy write zitadel-policy - <<'EOF'
path "kv/data/alarmify/local/zitadel/*" {
  capabilities = ["read"]
}
path "kv/metadata/alarmify/local/zitadel/*" {
  capabilities = ["list"]
}
EOF

# Add the policy to the existing external-secrets-operator role
vault write auth/kubernetes/role/external-secrets-operator \
  bound_service_account_names=local-external-secrets-operator \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-policy,zitadel-policy \
  ttl=24h
```

### Step 3 — Switch values.yaml to Vault mode

In `values.yaml`, make these changes:

```yaml
externalSecrets:
  enabled: true                      # ← flip from false

zitadel:
  zitadel:
    # Remove masterkey — use Vault-backed secret instead
    # masterkey: "..."               # ← delete this line
    masterkeySecretName: zitadel-masterkey   # created by ExternalSecret

    # Remove secretConfig — use Vault-backed secret instead
    # secretConfig: ...              # ← delete this block
    configSecretName: zitadel-secret-config  # created by ExternalSecret
    configSecretKey: zitadel-secrets-yaml    # key inside the secret

    # loginServiceKeySecretName is already set in values.yaml;
    # ESO now creates the secret instead of you creating it manually.
    # loginServiceKeySecretName: zitadel-login-service-key  ← no change needed
```

> The upstream chart enforces `masterkey` XOR `masterkeySecretName` — exactly one must be set. Leaving both set (or neither) causes a `helm template` failure.

### How the ExternalSecrets work

```text
Vault KV v2
  kv/alarmify/local/zitadel/masterkey         ──▶ ExternalSecret (sync-wave -1)
  kv/alarmify/local/zitadel/database                ↓
  kv/alarmify/local/zitadel/login-service-key  K8s Secrets in zitadel namespace
                                               ├─ zitadel-masterkey          (Opaque, key: masterkey)
                                               ├─ zitadel-secret-config      (Opaque, key: zitadel-secrets-yaml)
                                               └─ zitadel-login-service-key  (kubernetes.io/tls)
                                                    ↓
                                              Zitadel chart consumes via:
                                               ├─ masterkeySecretName
                                               ├─ configSecretName + configSecretKey
                                               └─ login.loginServiceKeySecretName
```

The `zitadel-secret-config` Secret is rendered by ESO's v2 template engine into a YAML config file structure that matches what the Zitadel init/setup/runtime pods expect:

```yaml
Database:
  Postgres:
    User:
      Password: "<userPassword from Vault>"
    Admin:
      Password: "<adminPassword from Vault>"
```

### Rotating secrets

| Secret | Rotation procedure |
|---|---|
| **masterkey** | **Cannot be rotated** without re-encrypting all data. Treat as permanent. |
| **DB passwords** | Update in Vault → ESO auto-refreshes (`refreshInterval: 1h`) → restart Zitadel pods |
| **Login keypair** | Update in Vault → ESO refreshes → restart Login UI + Zitadel pods; existing sessions using the old key will fail — plan a maintenance window |

### Troubleshooting

```bash
# Check ExternalSecret sync status
kubectl get externalsecret -n zitadel
kubectl describe externalsecret zitadel-masterkey-eso -n zitadel

# Check if K8s Secrets were created
kubectl get secret -n zitadel | grep -E 'zitadel-masterkey|zitadel-secret-config|zitadel-login-service-key'

# Verify ESO can reach Vault
kubectl logs -n external-secrets deployment/local-external-secrets-operator | tail -50

# Check ClusterSecretStore health
kubectl get clustersecretstore vault-secretstore -o jsonpath='{.status.conditions}' | jq .
```

## One-time: login service keypair

`login.loginServiceKeySecretName` points at a pre-created secret because the upstream
chart's `lookup`-based reuse does not work under ArgoCD (`helm template` renders
`lookup` as empty, so each sync would rotate the login signing key).

**With Vault (recommended)**: enable `externalSecrets.enabled: true` and store the keypair in
`kv/alarmify/local/zitadel/login-service-key` as shown in the Vault section above. The
`ExternalSecret` (sync-wave `-1`) creates `zitadel-login-service-key` before Zitadel syncs,
and `deletionPolicy: Retain` prevents key rotation on prune cycles.

**Without Vault**: create it once per cluster **before** the app syncs — either copy the
keypair the chart already generated:

```bash
kubectl get secret local-zitadel-login-service-key -n zitadel -o json \
  | jq '{apiVersion, kind, type, data, metadata: {name: "zitadel-login-service-key", namespace: "zitadel"}}' \
  | kubectl apply -f -
```

or mint a fresh RSA keypair (must be RSA — the login container signs RS256 JWTs):

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=login-service" \
  -keyout tls.key -out tls.crt
kubectl create secret tls zitadel-login-service-key -n zitadel --cert=tls.crt --key=tls.key
```

## First login

After the first sync, open `https://zitadel.home.arpa/ui/console`. The default admin is `zitadel-admin@zitadel.zitadel.home.arpa` with password `Password1!` (change forced on first login). The setup Job also creates an `iam-admin` machine user whose key/PAT are written to Secrets `iam-admin` / `iam-admin-pat` in the `zitadel` namespace for automation.

## Values reference — why each non-obvious setting is set

`values.yaml` is kept comment-free; every non-obvious value is explained here.

### Wrapper chart and dependency nesting

Top-level `enabled` toggles the upstream dependency via `Chart.yaml`'s `condition: enabled`.
Everything for the upstream chart must be nested under the dependency key `zitadel:` — hence the
doubled `zitadel.zitadel.*` for the upstream chart's own `zitadel` block
([upstream defaults](https://github.com/zitadel/zitadel-charts/blob/main/charts/zitadel/values.yaml)).

```yaml
enabled: true          # this wrapper
zitadel:               # dependency key
  zitadel:             # upstream chart's own `zitadel` block
    configmapConfig: {}
```

### Database — in-cluster Service, never the LAN VIP

```yaml
Database:
  Postgres:
    Host: postgresql-cluster-rw.cloudnative-pg-system.svc
    User:
      SSL:
        Mode: require
```

The CNPG cluster from `helmcharts/cloudnative-pg` is reached by **in-cluster Service DNS**.
Do not point this at `cloudnative-pg.home.arpa`: hairpinning back out through istio-gateway caused
the 2026-07-10 Zitadel outage (HBONE/TcpProxy stream accounting under short-lived churn — see
[istio docs](https://github.com/Alarmify/alarmify-docs/blob/main/docs/istio/index.md)). LAN clients
still use `cloudnative-pg.home.arpa` → istio-gateway TCPRoute; only Zitadel's own pods go direct.

`Mode: require` means encrypted without CA verification (CNPG presents its own CA's cert and TLS is
end-to-end to the Service). For `verify-full`, mount the CNPG CA via `zitadel.dbSslCaCrtSecret`.

The `Admin` user is the CNPG superuser, used **only** by the init/setup Jobs to create the `zitadel`
database and role — no CNPG manifest changes are needed. It must match `postgresql-superuser`
(`enableSuperuserAccess: true`).

### `HTTPClient.DenyList` — required for Actions v2

Actions v2 targets call `alarmify-identity-api` by in-cluster Service DNS, which resolves into
`10.0.0.0/8` (the service CIDR). Zitadel's default `HTTPClient.DenyList` blocks that range as an
SSRF guard, so target creation fails with `Errors.Target.DeniedURL`. The value in `values.yaml`
restates Zitadel's default list **minus `10.0.0.0/8`**:

```yaml
HTTPClient:
  DenyList:
    - localhost
    - "0.0.0.0/8"
    # ... default list continues, with 10.0.0.0/8 omitted
```

Lists replace defaults wholesale — they do not merge — so the whole list must be restated.

### Gateway routes

Two attachment points on the same HTTPRoute:

| Listener | Hostname | Path |
|---|---|---|
| `http` | `zitadel.jrclabs.xyz` | public — cloudflared tunnel; external-dns creates the proxied CNAME |
| `https` | `zitadel.home.arpa` | LAN — stepca SAN cert (keep the name in `helmcharts/stepca` `edgeGatewayTls.dnsNames`) |

The external-dns `target` annotation deliberately lives on the parent istio-gateway `Gateway`, not
here — external-dns reads it only from Gateway resources and silently ignores it on an HTTPRoute
(see `helmcharts/istio/istio-gateway/templates/gateway.yaml`). Only `hostname` and `class` belong here:

```yaml
annotations:
  external-dns.alpha.kubernetes.io/hostname: zitadel.jrclabs.xyz
  external-dns.alpha.kubernetes.io/class: cloudflare
```

### Login UI v2 is public-only

```yaml
login:
  gateway:
    httpRoute:
      hostnames:
        - zitadel.jrclabs.xyz   # never zitadel.home.arpa
```

The login app's `CUSTOM_REQUEST_HEADERS` always asserts `ExternalDomain=zitadel.jrclabs.xyz` to
the core API. Served over `zitadel.home.arpa` that contradicts the real inbound Host, and Zitadel
rejects it with `public domain ... not trusted`, breaking session lookup and `login_hint` for that
page load. `zitadel.home.arpa` stays on the core route above for Terraform and break-glass access.

### Resource limits

The `login` block's cpu limit was halved on 2026-07-11 (500m → 250m; 24h peak 14.5m per
VictoriaMetrics). Do **not** apply the same reasoning to the main `zitadel.resources` block — its
24h peak is 998.5m against a 1000m limit, so halving it would throttle Zitadel immediately.

### `initJob`

```yaml
initJob:
  enabled: true
  command: ""
```

Runs `zitadel init` with the Admin credentials to create the database, user and grants. Leave
`command: ""` for a full init; it is idempotent across upgrades.

### Security gap: `/system` and `/debug` are publicly reachable

Gateway-level `pathGuards` on `helmcharts/istio/istio-gateway` are intentionally empty while that Gateway
also terminates Postgres/NATS TCP — a DENY `AuthorizationPolicy` carrying HTTP matchers becomes
deny-all on the TCP listeners (2026-07-11). The intent was for Cloudflare to block `/system` and
`/debug` on the public hostname in the meantime.

**Verified 2026-07-27: it does not.** These reach Zitadel through Cloudflare today:

```console
$ curl -s -o /dev/null -w '%{http_code}\n' https://zitadel.jrclabs.xyz/debug/metrics
200        # Prometheus metrics, publicly readable
$ curl -s -o /dev/null -w '%{http_code}\n' https://zitadel.jrclabs.xyz/debug/ready
200
$ curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' -d '{}' \
    https://zitadel.jrclabs.xyz/system/v1/instances/_search
401        # auth-gated, but the endpoint is exposed
```

A Cloudflare block returns a `403` HTML page; these return Zitadel's own responses, so nothing is
filtering them. `/system` is at least credential-gated, but `/debug/metrics` is an unauthenticated
information leak. Closing this needs HTTPRoute-scoped AuthZ, split HTTP/TCP gateways, or an actual
Cloudflare rule — none of which are in place yet.

## Notes

- TLS terminates at the gateway; Zitadel runs `ExternalSecure: true` + `TLS.Enabled: false` (h2c). gRPC clients need HTTP/2 — the Service advertises `appProtocol: kubernetes.io/h2c`.
- DB connections use `sslmode=require` end-to-end (the TCPRoute is L4 passthrough to CNPG's own TLS). For `verify-full`, mount the CNPG CA via `zitadel.dbSslCaCrtSecret`.
- The upstream chart is Helm-hook heavy (init/setup Jobs as `pre-install/pre-upgrade`); ArgoCD maps these to PreSync hooks automatically.
- Namespace enforces PSS `baseline` (warn/audit `restricted`); pod/container security contexts are hardened in `values.yaml`.

---

## Two HTTPRoutes, deliberately

`values.yaml` configures the **public** hostname only. The LAN hostname is served by a separate
route, `templates/httproute-zitadel-lan.yaml`.

**They cannot share one route.** Filters are per-rule, and `HTTPRouteMatch` has **no hostname
matcher** — so a single route cannot apply the LAN-only `x-zitadel-public-host` header without
also rewriting the OIDC issuer for public traffic. That would break `alarmify-ui`, JWKS
verification in ingest/incident, and Kiali.

Matching on the Host header instead is not an option either: Gateway API's header-name pattern
**forbids `:`**, so `:authority` is invalid, and Envoy exposes the Host only as that
pseudo-header.

No filters are needed on the public route — the inbound Host already *is* the registered
instance domain.

> 🔗 This is why [`kiali`](../kiali/README.md) must use `https://zitadel.jrclabs.xyz` as its
> `issuer_uri` rather than the LAN name.
