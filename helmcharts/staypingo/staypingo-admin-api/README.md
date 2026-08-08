# staypingo-admin-api

Staypingo admin api, deployed from Harbor.

- Image: `harbor.workquark.org/staypingo/staypingo-admin-api:v0.0.2`
- Container port `8080`, Service port `80`

---

## Configuration

### Image and scale

```yaml
image:
  repository: harbor.workquark.org/staypingo/staypingo-admin-api
  tag: v0.0.2
  pullPolicy: IfNotPresent
replicas: 1
containerPort: 8080
environment: prod
```

This is the backend that [`staypingo-admin-ui`](../staypingo-admin-ui/README.md) points all of its API URLs at.

### Registry credentials

```yaml
imagePullSecrets:
  - name: staypingo-admin-api-registry

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
  - staypingo-admin-api-vars
```

It is **not set today** — the deployment runs with config values only, no secret env. Add the
list here once a corresponding Vault-backed Secret exists.

### Routing

```yaml
httproute:
  hostname: admin.staypingo.home.arpa
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
