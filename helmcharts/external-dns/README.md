# External DNS Helm Chart

A production-ready Helm chart for External DNS with Cloudflare provider integration.

## Overview

External DNS automatically manages DNS records for Kubernetes services and ingresses. This chart provides a complete solution with:

- 🔐 **Secure credential management** via External Secrets Operator
- ☁️ **Cloudflare integration** with API token authentication
- 📊 **Monitoring** with Prometheus metrics
- 🔒 **Security** with Pod Security Standards
- 🚀 **Production-ready** configuration

## Features

### Core Functionality
- **Automatic DNS Management**: Creates/updates/deletes DNS records based on Kubernetes resources
- **Cloudflare Provider**: Full integration with Cloudflare DNS API
- **Multiple Sources**: Supports Gateway API, Service, and CRD sources
- **Gateway API Support**: Automatically extracts hostnames from HTTPRoute resources
- **Wildcard Support**: Handles wildcard domains and subdomains

### Security
- **External Secrets Integration**: Secure API token management via Vault
- **Pod Security Standards**: Restricted security context
- **RBAC**: Minimal required permissions
- **Non-root execution**: Runs as non-root user

### Monitoring & Observability
- **Prometheus Metrics**: Built-in metrics endpoint
- **ServiceMonitor**: Automatic Prometheus scraping
- **Health Checks**: Liveness, readiness, and startup probes
- **Structured Logging**: JSON-formatted logs

### Production Features
- **High Availability**: Pod disruption budget
- **Resource Management**: CPU and memory limits
- **Rolling Updates**: Zero-downtime deployments
- **Leader Election**: Prevents conflicts in multi-replica setups

## Prerequisites

- Kubernetes 1.22+
- External Secrets Operator
- Vault with Cloudflare API token stored
- Cloudflare account with API token

## Installation

### 1. Store Cloudflare API Token in Vault

Put the token in `.env` at the repo root (gitignored — copy `.env.example`) and seed it
with the bootstrap task, which writes it from inside the Vault pod:

```bash
# .env
CLOUDFLARE_API_TOKEN=your-cloudflare-api-token-here
```

```bash
task provision-vault-secrets              # -> kv/alarmify/local/cloudflared/token
task provision-vault-secrets VAULT_ENV=dev  # -> kv/alarmify/dev/cloudflared/token
```

Before writing, the task checks the token by listing the zone in `domainFilters`
(`workquark.org`). That check exists because this chart's failure mode is quiet: with a
bad token external-dns keeps running and reporting healthy while DNS records silently
stop being reconciled. Listing the zone also proves the token actually carries `Zone:Read`
for the zone in question, not merely that it exists.

> ⚠️ Do **not** switch that check to `/user/tokens/verify`. That endpoint only validates
> **user-owned** tokens and answers `code 1000 Invalid API Token` for a perfectly valid
> **account-owned** one (created under Account → API Tokens rather than My Profile → API
> Tokens) — a false negative that blocks the bootstrap on a working token. Hit 2026-08-06.

Override the zone with `CLOUDFLARE_ZONE=...`, or skip the check with
`CLOUDFLARE_TOKEN_VERIFY=false`.

The Vault path is `<mount>/alarmify/<env>/cloudflared/<...>` — the env segment is the
**Argo CD cluster name** (`local` = management, `dev`), not a deployment stage. An older
`secret/cloudflare/api-token` path appears in some docs; it is not what this chart reads.

### 2. Deploy External DNS

```bash
# Add the chart repository
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/

# Update dependencies
helm dependency update

# Install External DNS
helm upgrade --install external-dns . \
  --namespace external-dns \
  --create-namespace \
  --values values.yaml
```

### 3. Verify Installation

```bash
# Check pod status
kubectl get pods -n external-dns

# Check logs
kubectl logs -n external-dns deployment/external-dns

# Check DNS records (after creating an ingress)
kubectl get ingress -A
```

## Configuration

### Basic Configuration

Values under `external-dns:` are passed to the **upstream** [kubernetes-sigs/external-dns](https://github.com/kubernetes-sigs/external-dns) Helm chart. Use that chart’s keys (flat `sources`, `provider.name`, `env`, etc.); nested keys such as `externalDns` are **not** read by the dependency and are ignored.

```yaml
external-dns:
  provider:
    name: cloudflare

  env:
    - name: CF_API_TOKEN
      valueFrom:
        secretKeyRef:
          name: cloudflare-api-token
          key: api-token

  extraArgs:
    - --cloudflare-proxied

  domainFilters:
    - workquark.org

  annotationFilter: external-dns.alpha.kubernetes.io/class=cloudflare

  sources:
    - gateway-httproute   # HTTPRoute objects (not the legacy name "gateway")
    - service
    - crd

  policy: upsert-only
  registry: txt
  txtOwnerId: external-dns
  txtPrefix: external-dns
```

### Advanced Configuration

```yaml
external-dns:
  resources:
    limits:
      cpu: 100m
      memory: 128Mi
    requests:
      cpu: 50m
      memory: 64Mi

  podSecurityContext:
    runAsNonRoot: true
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault

  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    capabilities:
      drop: ["ALL"]

  serviceMonitor:
    enabled: false
```

## Usage

### 1. Gateway API with External DNS

External-DNS reads hostnames from `spec.hostnames`. This repo sets `annotationFilter` to `external-dns.alpha.kubernetes.io/class=cloudflare`, so **HTTPRoutes must include that annotation** (and usually a tunnel `target` when using Cloudflare Tunnel). Example:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: example-httproute
  namespace: default
  annotations:
    external-dns.alpha.kubernetes.io/class: cloudflare
spec:
  parentRefs:
    - name: default
      namespace: envoy-gateway-system
  hostnames:
    - example.workquark.org  # External-DNS will automatically create DNS record
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: example-service
          port: 80
```

For Gateway resources, use the hostname annotation:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: example-gateway
  namespace: envoy-gateway-system
  annotations:
    external-dns.alpha.kubernetes.io/hostname: gateway.workquark.org
    external-dns.alpha.kubernetes.io/class: cloudflare
spec:
  gatewayClassName: envoy
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

### 2. Service with External DNS

```yaml
apiVersion: v1
kind: Service
metadata:
  name: example-service
  namespace: default
  annotations:
    external-dns.alpha.kubernetes.io/hostname: service.workquark.org
    external-dns.alpha.kubernetes.io/class: cloudflare
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: example
```

### 3. DNSEndpoint CRD

```yaml
apiVersion: external-dns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: example-dnsendpoint
  namespace: default
spec:
  endpoints:
  - dnsName: "api.workquark.org"
    recordTTL: 300
    recordType: "A"
    targets:
    - "192.168.1.100"
```

## Monitoring

### Prometheus Metrics

External DNS exposes metrics on port 7979:

```bash
# Port forward to access metrics
kubectl port-forward -n external-dns svc/external-dns 7979:7979

# View metrics
curl http://localhost:7979/metrics
```

### Key Metrics

- `external_dns_controller_errors_total`: Total number of errors
- `external_dns_controller_processed_records_total`: Total processed records
- `external_dns_controller_sync_duration_seconds`: Sync duration
- `external_dns_controller_instances`: Number of controller instances

### Grafana Dashboard

A Grafana dashboard is available for monitoring External DNS performance and health.

## Troubleshooting

### Common Issues

#### 1. API Token Issues

```bash
# Check if the secret exists
kubectl get secret -n external-dns cloudflare-api-token

# Check the secret content
kubectl get secret -n external-dns cloudflare-api-token -o yaml
```

#### 2. DNS Records Not Created

```bash
# Check External DNS logs
kubectl logs -n external-dns deployment/external-dns

# Check for annotation filters
kubectl get ingress -A --show-labels
```

#### 3. Permission Issues

```bash
# Check RBAC permissions
kubectl auth can-i get ingresses --as=system:serviceaccount:external-dns:external-dns

# Check cluster role
kubectl describe clusterrole external-dns
```

### Debug Mode

Enable debug logging:

```yaml
external-dns:
  logLevel: "debug"
  extraArgs:
    - "--log-format=json"
```

### Dry Run Mode

Test without making changes:

```yaml
external-dns:
  cloudflare:
    dryRun: true
```

## Security Considerations

### API Token Security

- Store API token in Vault using External Secrets
- Use least-privilege API token with only DNS permissions
- Rotate API tokens regularly

### Network Security

- Use network policies to restrict traffic
- Enable TLS for metrics endpoint
- Use service mesh for additional security

### Pod Security

- Runs as non-root user (65534)
- Read-only root filesystem
- No privileged capabilities
- Seccomp profile enabled

## Production Checklist

- [ ] API token stored securely in Vault
- [ ] External Secrets Operator configured
- [ ] Monitoring and alerting set up
- [ ] Resource limits configured
- [ ] Pod disruption budget enabled
- [ ] Network policies applied
- [ ] Backup and disaster recovery plan
- [ ] Regular security updates

## Support

For issues and questions:

1. Check the [External DNS documentation](https://github.com/kubernetes-sigs/external-dns)
2. Review the [Cloudflare provider docs](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/cloudflare.md)
3. Check Kubernetes logs and events
4. Verify Vault and External Secrets configuration

## License

This chart is licensed under the Apache 2.0 License.

---

## This deployment's configuration

### Use the upstream schema

```yaml
external-dns:
  # kubernetes-sigs/external-dns subchart values
```

> ⚠️ Values **must** use the upstream chart's schema. Nested keys like `externalDns` are
> silently ignored, which previously meant only the default sources (`service`, `ingress`) were
> applied — HTTPRoute records were never created.

### Reconcile on events, not just the timer

Configured to reconcile soon after HTTPRoute / Service / CRD changes rather than waiting for the
interval timer.

### Cloudflare token

Delivered by `templates/cloudflare-api-token-secret.yaml` via External Secrets, which reads
the single property `token` from the per-cluster path:

```yaml
cloudflareApiToken:
  vaultPath: alarmify/local/cloudflared/token
```

It shares the `cloudflared/` prefix with the tunnel credentials but is a **separate object**,
so `spec.data[]` hands external-dns only the API token and never the tunnel's `cert` — and
rotating the token does not touch the tunnel. Seed it with `task provision-vault-secrets`
(see [Installation](#1-store-cloudflare-api-token-in-vault)).

> 🔁 This is the dependency that makes [`external-secrets`](../external-secrets/README.md)'s
> Vault address matter — external-dns needs Vault to get this token, so Vault must not be
> reachable only through Cloudflare.

### Per-cluster TXT registry owner

Both `local` and `dev` manage the **same `workquark.org` zone**. Each cluster uses a distinct
TXT registry owner ID so dev's external-dns does not fight the management instance over
ownership of the same records.

`values/local.yaml` has no overrides today — management's config is exactly the shared defaults.

> 📉 CPU limit halved on 2026-07-11: 24h peak usage 2.0m, per VictoriaMetrics.
