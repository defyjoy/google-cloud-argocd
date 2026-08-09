# staypingo-admin-ui

Staypingo admin ui, deployed from Harbor.

- Image: `harbor.jrclabs.xyz/staypingo/staypingo-admin-ui:v0.0.10`
- Container port `3000`, Service port `80`

---

## Configuration

### Image and scale

```yaml
image:
  repository: harbor.jrclabs.xyz/staypingo/staypingo-admin-ui
  tag: v0.0.10
  pullPolicy: IfNotPresent
replicas: 1
containerPort: 3000
environment: prod
```

### Backend URLs

```yaml
config:
  NEXT_PUBLIC_ADMIN_API_URL: "http://admin.staypingo.home.arpa"
  IDENTITY_API_URL: "http://admin.staypingo.home.arpa"
  ADMIN_API_URL: "http://admin.staypingo.home.arpa"
  MASTERDATA_API_URL: "http://admin.staypingo.home.arpa"
  PG_LISTING_API_URL: "http://admin.staypingo.home.arpa"
  PHOTO_API_URL: "http://admin.staypingo.home.arpa"
  LOCATION_API_URL: "http://admin.staypingo.home.arpa"
```

Every backend URL currently points at the **same host** —
[`staypingo-admin-api`](../staypingo-admin-api/README.md). They are separate keys so individual
services can be split onto their own hostnames later without a code change.

`NEXT_PUBLIC_`-prefixed values are baked into the browser bundle at build time by Next.js and
are therefore public; the others are read server-side only.


### Registry credentials

```yaml
imagePullSecrets:
  - name: staypingo-admin-ui-registry

externalSecrets:
  secretStore: vault-secretstore
  registryCredentialKey: harbor/staypingo-registry-credential
```

Both staypingo charts share **one** Vault object for the Harbor pull credential, so rotating it
affects both.

### App secrets are not wired up

The chart supports an `envFromSecrets` list for injecting application secrets:

```yaml
envFromSecrets:
  - staypingo-admin-ui-vars
```

It is **not set today** — the deployment runs with config values only, no secret env. Add the
list here once a corresponding Vault-backed Secret exists.

### Routing

```yaml
httproute:
  hostname: admin-ui.staypingo.home.arpa
  path: /
  gatewayName: gateway
  gatewayNamespace: gateway-system
  gatewayListener: http
```

Attached to the shared `istio-gateway` — **Phase 2 batch 2 (staypingo)** of the Envoy Gateway →
Istio Gateway migration, see
[alarmify-docs / istio](https://github.com/Alarmify/alarmify-docs/blob/main/docs/istio/index.md).

### Resources

```yaml
resources:
  requests: { cpu: 100m, memory: 128Mi }
  limits:   { cpu: "200m", memory: 256Mi }
```
