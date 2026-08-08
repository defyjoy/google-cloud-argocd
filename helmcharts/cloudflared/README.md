# Cloudflared Helm Chart

This Helm chart deploys Cloudflare Tunnel (cloudflared) to your Kubernetes cluster. Cloudflare Tunnel provides secure connectivity between your Kubernetes cluster and Cloudflare's network without exposing public IPs.

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- A Cloudflare account with a configured tunnel
- Tunnel credentials (certificate PEM file and/or credentials JSON file)

## Installation

### 1. Update Dependencies

Before installing the chart, update the dependencies:

```bash
helm dependency update
```

This will download the cloudflared chart (v2.2.1) from the community-charts repository.

### 2. Configure Your Tunnel

You need to configure tunnel credentials and ingress rules. Edit `values.yaml`:

#### Option A: Using Existing Kubernetes Secrets (Recommended)

First, generate tunnel credentials using the cloudflared CLI:

```bash
# Install cloudflared CLI (if not already installed)
# macOS: brew install cloudflared
# Linux: wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && sudo dpkg -i cloudflared-linux-amd64.deb

# Login to Cloudflare (this will open a browser for authentication)
cloudflared tunnel login

# Create a new tunnel (replace 'my-tunnel' with your desired tunnel name)
cloudflared tunnel create my-tunnel

# This will generate two files in ~/.cloudflared/:
# - <tunnel-id>.json (credentials file)
# - cert.pem (certificate file)
```

Then create the Kubernetes secret with the generated files:

```bash
cd ~/.cloudflared
# Create single secret with both files as keys
kubectl create secret generic cloudflared-credentials \
  --from-file=cert.pem=cert.pem \
  --from-file=credentials.json=<tunnel-id>.json
```

Then update `values.yaml`:

```yaml
cloudflared:
  tunnelSecrets:
    existingPemFileSecret:
      name: "cloudflared-credentials"
      key: "cert.pem"
    existingConfigJsonFileSecret:
      name: "cloudflared-credentials"
      key: "credentials.json"
  
  tunnelConfig:
    name: "my-tunnel"  # Update this to match your tunnel name
  
  ingress:
    - hostname: myapp.example.com
      service: http://myapp-service.default.svc.cluster.local:80
    - service: http_status:404
```

#### Option B: Using Base64 Encoded Files (Not Recommended for Production)

```yaml
cloudflared:
  tunnelSecrets:
    base64EncodedPemFile: "<base64-encoded-pem-content>"
    base64EncodedConfigJsonFile: "<base64-encoded-json-content>"
```

#### Option C: Using Vault with External Secrets (Recommended for Production)

This option uses HashiCorp Vault to store tunnel credentials securely and automatically syncs them to Kubernetes using External Secrets Operator.

**Prerequisites:**
- Vault server running and accessible
- External Secrets Operator installed
- Vault ClusterSecretStore configured

**Step 1: Generate Tunnel Credentials**

```bash
# Install cloudflared CLI (if not already installed)
# macOS: brew install cloudflared
# Linux: wget https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && sudo dpkg -i cloudflared-linux-amd64.deb

# Login to Cloudflare (this will open a browser for authentication)
cloudflared tunnel login

# Create a new tunnel (replace 'my-tunnel' with your desired tunnel name)
cloudflared tunnel create my-tunnel

# This will generate two files in ~/.cloudflared/:
# - <tunnel-id>.json (credentials file)
# - cert.pem (certificate file)
```

**Step 2: Store Credentials in Vault**

Create the secret in Vault KV v2 store:

```bash
# Method 1: Using Vault CLI with file content
vault kv put secret/cloudflared/credentials \
  cert="$(cat ~/.cloudflared/cert.pem)" \
  credentials="$(cat ~/.cloudflared/<tunnel-id>.json)"

# Method 2: Using file references
vault kv put secret/cloudflared/credentials \
  cert=@~/.cloudflared/cert.pem \
  credentials=@~/.cloudflared/<tunnel-id>.json

# Method 3: Using kubectl exec (if Vault is running in Kubernetes)
kubectl exec -n vault local-vault-0 -- vault kv put secret/cloudflared/credentials \
  cert="$(cat /tmp/cert.pem)" \
  credentials="$(cat /tmp/credentials.json)"
```

**Step 3: Verify Vault Secret**

```bash
# List the secret
vault kv list secret/cloudflared/

# Read the secret
vault kv get secret/cloudflared/credentials

# Get specific fields
vault kv get -field=cert secret/cloudflared/credentials
vault kv get -field=credentials secret/cloudflared/credentials
```

**Step 4: Configure values.yaml**

The chart automatically includes an ExternalSecret that will sync the Vault secret to Kubernetes. No additional configuration is needed in `values.yaml` - the ExternalSecret is already configured to:

- Read from Vault path: `secret/cloudflared/credentials`
- Extract properties: `cert` and `credentials`
- Create Kubernetes secret: `cloudflared-credentials`
- Target namespace: `cloudflared`

The ExternalSecret configuration:
```yaml
# This is automatically included in the chart
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cloudflared-credentials
  namespace: cloudflared
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-secretstore
    kind: ClusterSecretStore
  target:
    name: cloudflared-credentials
  data:
    - secretKey: cert.pem
      remoteRef:
        key: cloudflared/credentials
        property: cert
    - secretKey: credentials.json
      remoteRef:
        key: cloudflared/credentials
        property: credentials
```

**Benefits of Vault Integration:**
- ✅ Centralized secret management
- ✅ Automatic secret rotation
- ✅ Audit logging
- ✅ Fine-grained access control
- ✅ No secrets stored in Git repositories
- ✅ Automatic synchronization to Kubernetes

### 3. Install the Chart

```bash
helm install cloudflared . -f values.yaml
```

Or with custom namespace:

```bash
helm install cloudflared . -f values.yaml -n cloudflare --create-namespace
```

## Configuration

### Key Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `enabled` | Enable/disable the chart | `true` |
| `cloudflared.replica.allNodes` | Deploy as DaemonSet on all nodes | `false` |
| `cloudflared.replica.count` | Number of replicas (if not DaemonSet) | `2` |
| `cloudflared.image.repository` | Image repository | `cloudflare/cloudflared` |
| `cloudflared.image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `cloudflared.tunnelConfig.name` | Tunnel name | `""` |
| `cloudflared.tunnelConfig.protocol` | Connection protocol (auto, http2, h2mux, quic) | `auto` |
| `cloudflared.tunnelConfig.logLevel` | Log level (info, warn, error, fatal, panic) | `info` |
| `cloudflared.resources` | Resource limits and requests | See values.yaml |

### Tunnel Configuration

The tunnel configuration follows Cloudflare's official documentation. Key settings:

- **protocol**: Connection protocol (auto, http2, h2mux, quic)
- **logLevel**: Logging verbosity (info, warn, error, fatal, panic)
- **retries**: Number of retries for failed connections
- **warpRouting**: Enable WARP routing

### Ingress Rules

Define how traffic is routed through the tunnel:

```yaml
cloudflared:
  ingress:
    # Route specific hostname
    - hostname: app1.example.com
      service: http://app1-service.default.svc.cluster.local:80
    
    # Route with path
    - hostname: app2.example.com
      path: /api
      service: http://app2-service.default.svc.cluster.local:8080
    
    # Wildcard hostname
    - hostname: "*.example.com"
      service: http://wildcard-service.default.svc.cluster.local:80
    
    # Catch-all rule (required - must be last)
    - service: http_status:404
```

#### This Chart's Live Ingress Rules

`values.yaml` routes `*.workquark.org` to `istio-gateway`'s auto-provisioned Service (the
data plane) rather than to individual app Services — `alarmify-ui`/harbor/vault/zitadel's
HTTPRoutes all moved together onto this Gateway during the Envoy Gateway → Istio Gateway
migration (see `alarmify-docs/docs/istio/index.md`). The Service name follows the pattern
`<gateway-name>-<gatewayclass-name>`, auto-provisioned by istiod's gateway-controller for
the `helmcharts/istio/istio-gateway` Gateway object; find the current one with:

```bash
kubectl get svc -n istio-system -l gateway.networking.k8s.io/gateway-name=istio-gateway
```

`zitadel.workquark.org` has its own rule ahead of the wildcard (ingress rules are
first-match-wins) so it can set `originRequest.http2Origin: true` — there is no
`http2://` URL scheme; the `service` field only accepts `http://`/`https://`/`tcp://`/
`unix://`/`ssh://` (confirmed via `cloudflared tunnel ingress validate`, which happily
accepts a bogus scheme as syntactically valid but doesn't act on it — an earlier version
of this rule used `http2://` and silently broke discovery/login for every request to this
hostname, 200 status with an empty body, since cloudflared didn't recognize the scheme).
`http2Origin` is the documented mechanism (equivalent to the cloudflared CLI's
`--http2-origin` / `TUNNEL_ORIGIN_ENABLE_HTTP2`, see `cloudflared tunnel run --help`):

```yaml
ingress:
  - hostname: "zitadel.workquark.org"
    service: http://istio-gateway-istio.istio-system.svc.cluster.local:80
    originRequest:
      http2Origin: true
  - hostname: "*.workquark.org"
    service: http://istio-gateway-istio.istio-system.svc.cluster.local:80
  - service: http_status:404
```

This is required for Terraform's native Zitadel gRPC provider (`Content-Type:
application/grpc`) to reach the instance: over the wildcard rule's plain `http://` origin
(no `http2Origin`), cloudflared/Cloudflare's edge reject gRPC requests outright with a
generic 403 `text/html` page before they ever reach Zitadel (observed 2026-07-27). Envoy
(istio-gateway) auto-detects HTTP/1.1 vs HTTP/2 per connection on the same listener, so
this doesn't change how other paths on that hostname are served.

### Environment-Specific Tunnels

Each environment points `externalSecrets.vaultPath` at its own Vault path and its own
Cloudflare Tunnel resource/credentials — dev and local don't share (or fight over) the
prod tunnel. Cloudflare load-balances a single tunnel's traffic across whichever connected
replica it picks, without host-pinning, so sharing one tunnel across clusters risks (e.g.)
a `harbor.workquark.org` request landing on the wrong cluster's replica and 404ing even
though the intended cluster's replica is healthy. A dedicated tunnel per environment means
Cloudflare's DNS layer — not tunnel-connector selection — deterministically decides which
cluster serves which hostname.

| Environment | Values file | Vault path | Tunnel name |
|---|---|---|---|
| local (management) | `values/local.yaml` | `alarmify/local/cloudflared/credentials` | `management` (tunnel ID `9da192fd-9481-44a4-a379-f205b66549b7`) |
| dev | `values/dev.yaml` | `alarmify/dev/cloudflared/credentials` | `dev` (tunnel ID `64478596-9fd7-4d58-a792-ae3b95d3ea98`, created and Vault-seeded 2026-07-19) |

The base `values.yaml` deliberately leaves `externalSecrets.vaultPath` empty — there is no
prod environment, and Vault's env segment is the cluster name (`vault kv list kv/alarmify`
returns only `dev/`, `local/`, `management/`). A `alarmify/prod/...` path resolves to nothing
and fails the whole ExternalSecret.

Seed either path with `task provision-vault-secrets` (`VAULT_ENV=dev` for dev) rather than by
hand — it runs `vault kv put` inside the Vault pod, so it works before cloudflared is up and
`vault.workquark.org` resolves, and it refuses to write credentials whose `TunnelID` belongs
to the other cluster. See `helmcharts/vault/README.md`.

The right file is selected per-cluster by
`helmcharts/argocd-apps/templates/applicationsets/cloudflared-as.yaml`'s generator
branches, matched against the target cluster Secret's `environment` label (e.g.
`helmcharts/argocd/templates/cluster/dev-cluster-secret.yaml`).

## Deployment Modes

### DaemonSet Mode (All Nodes)

Deploy cloudflared on every node in the cluster:

```yaml
cloudflared:
  replica:
    allNodes: true
```

### Deployment Mode (Specific Count)

Deploy a specific number of cloudflared instances:

```yaml
cloudflared:
  replica:
    allNodes: false
    count: 3
```

## Creating a Cloudflare Tunnel

If you don't have a tunnel yet, create one using the cloudflared CLI:

```bash
# Login to Cloudflare
cloudflared tunnel login

# Create a new tunnel
cloudflared tunnel create my-tunnel

# This will generate:
# - A tunnel UUID
# - A credentials file (~/.cloudflared/<tunnel-id>.json)
# - A cert.pem file (~/.cloudflared/cert.pem)

# Route DNS to your tunnel
cloudflared tunnel route dns my-tunnel myapp.example.com
```

## Monitoring

The chart includes metrics configuration:

```yaml
cloudflared:
  tunnelConfig:
    metricsUpdateFrequency: 5s
```

Metrics are available at `http://localhost:2000/metrics` inside the pod.

## Upgrading

```bash
helm upgrade cloudflared . -f values.yaml
```

## Uninstall

```bash
helm uninstall cloudflared
```

## Dependencies

This chart depends on the community cloudflared Helm chart:
- **Repository**: https://community-charts.github.io/helm-charts
- **Chart**: cloudflared
- **Version**: 2.2.1

## Troubleshooting

### Check Pod Logs

```bash
kubectl logs -l app.kubernetes.io/name=cloudflared
```

### Verify Tunnel Connection

```bash
kubectl exec -it deployment/cloudflared -- cloudflared tunnel info
```

### Common Issues

1. **Tunnel not connecting**: Verify credentials are correct and tunnel exists in Cloudflare dashboard
2. **DNS not resolving**: Ensure DNS records point to your tunnel
3. **Service not accessible**: Check ingress rules and service endpoints

## Resources

- [Cloudflare Tunnel Documentation](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Cloudflared Configuration](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/configuration/arguments/)
- [Community Charts Repository](https://github.com/community-charts/helm-charts)

---

## 🚨 Hostnames are per-environment — never share a wildcard

```yaml
# values.yaml — no hostnames here, only the catch-all
```

This file **used to carry a shared `*.workquark.org -> istio-gateway` rule**. Both clusters run
their own tunnel off this same chart (`local` → "management", `dev` → "dev"), so that wildcard
made **both tunnels claim every `workquark.org` hostname**.

A request landing on the tunnel whose cluster has no matching HTTPRoute got an **empty-body
404** from that cluster's proxy instead of being served — and nothing in either cluster looked
unhealthy, because each side was individually correct.

Each environment now lists only the hostnames it actually serves an HTTPRoute for, so which
tunnel answers a hostname is deterministic and greppable.

> ⚠️ **Helm replaces lists wholesale rather than merging them.** `values/<environment>.yaml`'s
> `ingress` fully overrides this file's, so **every environment must repeat the trailing
> catch-all rule**.

The catch-all alone is the safe default: a cluster with no overlay serves nothing, rather than
silently stealing another cluster's hostnames.

`alarmify-ui` is the only dev workload with public exposure today (Option D cutover).
