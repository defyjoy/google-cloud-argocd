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
(`jrclabs.xyz`). That check exists because this chart's failure mode is quiet: with a
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
    - jrclabs.xyz

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
    - example.jrclabs.xyz  # External-DNS will automatically create DNS record
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
    external-dns.alpha.kubernetes.io/hostname: gateway.jrclabs.xyz
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
    external-dns.alpha.kubernetes.io/hostname: service.jrclabs.xyz
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
  - dnsName: "api.jrclabs.xyz"
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

The `cloudflared/` path segment is historical: it originally sat alongside the Cloudflare Tunnel's
own credentials, seeded by the same task. The tunnel (`helmcharts/cloudflared`) was removed
2026-08-09 — public traffic now goes through `helmcharts/gke-gateway`'s `gateway-external` — but
this token path was left as-is rather than rewriting `vaultPath` here and re-seeding both
clusters' Vaults for a rename with no functional benefit. Seed it with `task
provision-vault-secrets` (see [Installation](#1-store-cloudflare-api-token-in-vault)).

> 🔁 This is the dependency that makes [`external-secrets`](../external-secrets/README.md)'s
> Vault address matter — external-dns needs Vault to get this token, so Vault must not be
> reachable only through Cloudflare.

### Per-cluster TXT registry owner

Both `local` and `dev` manage the **same `jrclabs.xyz` zone**. Each cluster uses a distinct
TXT registry owner ID so dev's external-dns does not fight the management instance over
ownership of the same records.

`values/local.yaml` has no overrides today — management's config is exactly the shared defaults.

> 📉 CPU limit halved on 2026-07-11: 24h peak usage 2.0m, per VictoriaMetrics.

### Incident timeline: getting `grafana.jrclabs.xyz` reachable end to end

Full chronological record of one debugging session that touched routing, health checks, TLS,
VPN DNS, and finally this chart. Kept as one sequence because each event's fix is what exposed
the next event's bug — none of these were independent.

**Event 1 — external-dns never created `grafana.jrclabs.xyz` at all**

Only one external-dns release existed at the time: `local-external-dns`, Cloudflare provider,
`--cloudflare-proxied`. It matched grafana's route (`class: cloudflare` was the only option
back then) and tried to create a **proxied** public record pointing at the internal gateway's
private IP:

```
level=error msg="fallback: individual CREATE failed: POST .../dns_records: 400 Bad Request
{\"errors\":[{\"code\":9003,\"message\":\"Target 10.40.0.14 is not allowed for a proxied record.\"}]}"
action=CREATE content=10.40.0.14 record=grafana.jrclabs.xyz
```

Cloudflare rejects proxied (orange-cloud) records pointing at RFC1918 addresses. This retried
and failed on every `--interval=1m` reconcile, forever. Fix: deploy the `local-external-dns-google`
release (`values/google.yaml`, this chart) targeting `jrclabs-xyz-private` instead.

**Event 2 — the new Google release still didn't pick up grafana**

Deploying the release wasn't enough: `local-external-dns-google`'s `annotationFilter` was
`class=google` at the time, but grafana's HTTPRoute annotation still said `class: cloudflare`
— leftover from Event 1, before the Google release existed to target instead:

```yaml
# kube-prometheus-stack's HTTPRoute — before
annotations:
  external-dns.alpha.kubernetes.io/class: cloudflare   # wrong release now
```

Fix: `class: cloudflare` → `class: google` on grafana's route (and `tempo-otlp`, `vminsert` —
same internal-gateway pattern). The private-zone record finally got created.

**Event 3 — record existed, `curl` still failed with `no healthy upstream`**

```console
$ curl --resolve grafana.jrclabs.xyz:80:10.40.0.14 http://grafana.jrclabs.xyz
HTTP/1.1 503 Service Unavailable
no healthy upstream
```

The pod was `Running`/`3/3 Ready` with a healthy Kubernetes endpoint — but the GCP-level load
balancer health check (`HealthCheckPolicy` in `helmcharts/gke-gateway`) was checking the wrong
port:

```yaml
# helmcharts/gke-gateway/values/local.yaml — before
- name: grafana
  targetService: kube-prometheus-stack-grafana
  namespace: kube-prometheus-stack
  port: 80          # the Service's port — nothing listens here on the pod
  requestPath: "/api/health"
```

Grafana's Service exposes `80` but forwards to container port `3000`; GKE Gateway health
checks hit the pod's actual port directly, not the Service port (confirmed against the two
correct sibling entries in the same file — `vault-ui` and `harbor-core` both already used
their real container ports). Fix:

```yaml
# after
    port: 3000
```

**Event 4 — `curl https://` returned `fault filter abort`**

```console
$ curl -k --resolve grafana.jrclabs.xyz:443:10.40.0.14 https://grafana.jrclabs.xyz
HTTP/2 404
fault filter abort
```

```console
$ kubectl get gateway gateway -n gateway-system -o jsonpath='{range .status.listeners[*]}{.name}: {.attachedRoutes}{"\n"}{end}'
http: 3
https: 0
```

TLS terminated fine (a valid `*.jrclabs.xyz` cert was served) but the `https` listener had
**zero** attached routes — grafana's `parentRefs` only listed `sectionName: http`. `fault
filter abort` is GKE Gateway's response when TLS succeeds but nothing in the URL map matches.
Fix: add a second `parentRefs` entry with `sectionName: https` (kube-prometheus-stack,
tempo-otlp, vminsert). No new certificate needed — `gateway-wildcard-tls` already covered
`*.jrclabs.xyz` and issues via a Cloudflare DNS-01 solver, which never needed to reach the
internal endpoint at all:

```yaml
solvers:
- dns01:
    cloudflare:
      apiTokenSecretRef: {name: cloudflare-api-token, key: api-token}
```

**Event 5 — the record existed, but nothing on the laptop could even ask for it**

Separately: `curl https://grafana.jrclabs.xyz` failed to resolve at all, VPN connected or not.
The private zone only answers queries from inside the VPC (a VM's metadata-server resolver);
routing a VPN client into the VPC's CIDRs doesn't grant it DNS resolution. Fixed on the
terraform side — Cloud DNS **inbound forwarding**, a reserved resolver IP inside the routed
subnet:

```hcl
# modules/dns — new resource
resource "google_dns_policy" "inbound_forwarding" {
  for_each                  = toset(var.inbound_forwarding_networks)
  enable_inbound_forwarding = true
  networks { network_url = data.google_compute_network.private_visibility[each.value].self_link }
}
```

```console
$ gcloud compute addresses list --filter="purpose=DNS_RESOLVER"
10.40.0.15   yeti-hub-us-central1 (nodes)   <- already in Pritunl's routed CIDRs
```

**Event 6 — reserving the IP did nothing until two more layers were fixed**

Pritunl had to be told to push it (`Servers → Settings → DNS Server: 10.40.0.15`,
`DNS Search Domain: jrclabs.xyz`, manual admin-UI step — self-hosted CE has no API). Even
then, the client (Tunnelblick, not the official Pritunl app — confirmed via `ps aux | grep
openvpn`) silently half-applied it:

```
Retrieved from OpenVPN: name server(s) [ 10.40.0.15 ], ... search domain(s) [ jrclabs.xyz ]
Did not change DNS ServerAddresses setting of '192.168.1.100' (but re-set it)
DNS servers '192.168.1.100' were set manually
```

Tunnelblick treats a manually-configured local DNS server as intentional and won't override
it — only the search domain got applied. Fix, per Tunnelblick config: **Advanced →
"Connecting & Disconnecting" → check "Allow changes to manually-set network settings."**
After reconnecting:

```console
$ dig grafana.jrclabs.xyz +short
10.40.0.14
$ curl -sk https://grafana.jrclabs.xyz -o /dev/null -w "%{http_code}\n"
200
```

Grafana was reachable, end to end, for the first time.

**Event 7 — fixing Event 5/6 broke `argocd`, `vault`, `harbor`**

The moment a VPN client actually started querying `jrclabs-xyz-private` (Event 6), every
public-only hostname in that same domain broke, because the zone is authoritative:

```console
$ dig argocd.jrclabs.xyz @10.40.0.15
;; ->>HEADER<<- status: NXDOMAIN, flags: qr aa rd
;; AUTHORITY SECTION:
jrclabs.xyz. 300 IN SOA ns-gcp-private.googleapis.com. ...
```

This was Event 2's `annotationFilter: class=google` again, from the other side: `argocd`,
`vault`, `harbor` only ever carried `class: cloudflare`, so the Google release had never
mirrored them into the private zone, and nothing had ever queried that zone for them until
now. Rejected fix: static `private_recordsets` in Terraform (drifts from the real LB IP,
breaks the "everything is sourced from the actual object state" pattern every other record in
this system follows). Actual fix — detailed below — clear `annotationFilter` entirely so this
release mirrors every `jrclabs.xyz` HTTPRoute, not just the ones someone remembered to tag.

### Two releases per cluster: Cloudflare (public) + Google (private zone)

This chart is deployed **twice per cluster**:

| Release | Values | Provider | Zone | Annotation it watches |
|---|---|---|---|---|
| `local-external-dns` / `dev-external-dns` | `values.yaml` (defaults, this README) | `cloudflare` | Cloudflare's public `jrclabs.xyz` | `class: cloudflare` |
| `local-external-dns-google` / `dev-external-dns-google` | `values/google.yaml` + `values/{local,dev}-google.yaml` | `google` | `jrclabs-xyz-private` (Cloud DNS, VPC-internal — see terraform repo's `modules/dns`) | *none* — see below |

Both watch the same `domainFilters: [jrclabs.xyz]`; what differs is which zone each one
writes to (`--zone-id-filter=jrclabs-xyz-private` pins the Google release) and which
Kubernetes objects each one is allowed to act on.

#### The bug: `class=google` silently starved the private zone

`values/google.yaml` originally filtered like this, mirroring the Cloudflare release's
pattern:

```yaml
# values/google.yaml — BEFORE
external-dns:
  annotationFilter: external-dns.alpha.kubernetes.io/class=google
```

That looks symmetric with the Cloudflare release, but it isn't the same kind of filter. The
Cloudflare release is the *only* thing that can ever write to the public zone, so its filter
just decides *if* a host gets a public record at all. The Google release's filter decides
whether a host gets a **private-zone mirror** — and every host was implicitly assumed to want
one, per the design already documented in the terraform repo:

```
# live/dns/terraform.tfvars.example
# The private zone shadows the public one inside the VPCs, so anything above that must
# still resolve in-VPC has to be repeated here — pointing at internal addresses.
```

`argocd`, `vault`, and `harbor` only ever carried `class: cloudflare`:

```yaml
# a real HTTPRoute in this cluster, unchanged by this fix
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: argocd.jrclabs.xyz
    external-dns.alpha.kubernetes.io/class: cloudflare   # never matched class=google
```

— so with the old filter, the Google release skipped them entirely. `jrclabs-xyz-private` is
an **authoritative** zone, so a client resolving through it for one of these hosts didn't get
a fallback to the public internet, it got a hard, authoritative NXDOMAIN:

```console
$ dig argocd.jrclabs.xyz @10.40.0.15

;; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 61635
;; flags: qr aa rd; QUERY: 1, ANSWER: 0, AUTHORITY: 1, ADDITIONAL: 1

;; AUTHORITY SECTION:
jrclabs.xyz.   300  IN  SOA  ns-gcp-private.googleapis.com. cloud-dns-hostmaster.google.com. ...
```

The `aa` flag is the tell — that's Cloud DNS itself saying "no such name," not a timeout or a
wrong resolver. This sat broken from the day the Google release was added; it had **zero**
live impact until something actually started querying `jrclabs-xyz-private` from outside the
VPC — which is exactly what the terraform repo's `docs/vpn-runbook.md` ("DNS resolution for
VPN clients") work did, by standing up Cloud DNS inbound forwarding for VPN clients.

#### The fix

```yaml
# values/google.yaml — AFTER
external-dns:
  annotationFilter: ""   # domainFilters (jrclabs.xyz) is what scopes this release now
```

`--zone-id-filter=jrclabs-xyz-private` and `--google-zone-visibility=private` (still in
`extraArgs`, unchanged) keep this release confined to the private zone regardless — clearing
`annotationFilter` only changes *which HTTPRoutes it's allowed to read*, not *where it's
allowed to write*. With no annotation filter, every `jrclabs.xyz` HTTPRoute — Cloudflare-only
ones included — gets mirrored into the private zone on the next reconcile (`interval: 1m`,
`triggerLoopOnEvent: true`, from the base `values.yaml`):

```console
$ kubectl logs -n external-dns deploy/local-external-dns-google | grep argocd
time="..." level=info msg="Changing record." action=CREATE record=argocd.jrclabs.xyz ttl=300 type=A zone=jrclabs-xyz-private

$ dig argocd.jrclabs.xyz @10.40.0.15 +short
35.209.80.67
```

#### Diagnosing this class of bug in general

```bash
# Find the inbound forwarding IP (terraform repo's live/dns):
gcloud compute addresses list --filter="purpose=DNS_RESOLVER"

# Query the private zone directly, bypassing whatever the client's default resolver is doing:
dig <host>.jrclabs.xyz @<forwarder-ip>
```

`flags: aa` + `NXDOMAIN` + a `SOA jrclabs.xyz.` in `AUTHORITY` → the private zone itself has
no record for that name. Check this release's `annotationFilter` and its logs
(`kubectl logs -n external-dns deploy/local-external-dns-google`) before assuming a routing,
firewall, or client DNS-config problem — those all fail differently (timeouts, `SERVFAIL`,
wrong IPs), not a clean authoritative NXDOMAIN.

See the terraform repo's `docs/vpn-runbook.md` ("DNS resolution for VPN clients") for the
other half of this story — reserving and pushing the forwarding IP, and the client-side
gotchas (Pritunl client, Tunnelblick) that determine whether a VPN client even queries this
release's zone at all.
