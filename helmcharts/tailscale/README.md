# Tailscale Kubernetes Operator Helm Chart

A Helm chart wrapper for deploying the official [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator) in Kubernetes.

## Overview

This chart deploys the official Tailscale Kubernetes Operator, which provides:

- **API Server Proxy** - Access Kubernetes control plane via Tailscale
- **Cluster Egress** - Expose tailnet services to your Kubernetes cluster
- **Cluster Ingress** - Expose cluster workloads to your tailnet
- **Cross-Cluster Connectivity** - Connect workloads across clusters
- **Cloud Service Exposure** - Expose cloud services to your tailnet
- **Exit Nodes & Subnet Routers** - Deploy exit nodes and subnet routers
- **App Connector** - Deploy app connector
- **Multi-Cluster Support** - Manage multi-cluster deployments with ArgoCD

## Prerequisites

- Kubernetes cluster v1.23.0+
- Tailscale account with admin access
- OAuth client credentials (created in Tailscale admin console)

## Setting Up OAuth Client Credentials

Before deploying the operator, you need to create OAuth client credentials:

1. **Access Tailscale Admin Console:**
   - Go to https://login.tailscale.com/admin/settings/oauth_clients
   - Log in with an admin account

2. **Create OAuth Client:**
   - Click "Create OAuth client"
   - Grant scopes: **Devices Core** and **Auth Keys** (write access)
   - Note the **Client ID** (e.g., `k123456CNTRL`)
   - Note the **Client Secret** (e.g., `tskey-client-k123456CNTRL-abcdef`)
   - **Important**: The client secret is case-sensitive and must be quoted

3. **Configure Tailnet Policy:**

   Update your tailnet policy file to include operator tags:

   ```json
   {
     "tagOwners": {
       "tag:k8s-operator": [],
       "tag:k8s": ["tag:k8s-operator"]
     }
   }
   ```

4. **Store Credentials Securely:**
   - Use External Secrets Operator with Vault (recommended)
   - Or create Kubernetes secret manually
   - **Never commit secrets to Git**

## Installation

### Via ArgoCD ApplicationSet

The Tailscale operator is managed via ArgoCD ApplicationSet. To enable deployment on a cluster:

```bash
# Label your cluster secret in ArgoCD
kubectl label secret -n argocd <cluster-secret-name> tailscale=true

# For the local cluster
kubectl label secret -n argocd in-cluster tailscale=true
```

### Using External Secrets (Recommended)

1. **Store OAuth credentials in Vault:**

```bash
# Store OAuth credentials in Vault
vault kv put secret/tailscale \
  oauth-client-id="k123456CNTRL" \
  oauth-client-secret="tskey-client-k123456CNTRL-abcdef"
```

2. **Apply ExternalSecret manifest:**

```bash
# Apply the ExternalSecret to create the secret from Vault
kubectl apply -f manifests/external-secrets/tailscale-oauth-externalsecret.yaml
```

3. **Create values file with secrets:**

For ArgoCD, create a values file that reads from the secret or use Sealed Secrets. Alternatively, pass values via ApplicationSet overrides.

### Manual Installation

1. **Update Helm dependencies:**

```bash
cd helmcharts/tailscale
helm dependency update
```

2. **Create OAuth Secret (if not using External Secrets):**

```bash
kubectl create secret generic tailscale-oauth-credentials \
  --from-literal=oauthClientId='k123456CNTRL' \
  --from-literal=oauthClientSecret='tskey-client-k123456CNTRL-abcdef' \
  -n tailscale
```

3. **Extract values and deploy:**

```bash
# Extract values from secret (if using External Secrets)
CLIENT_ID=$(kubectl get secret -n tailscale tailscale-oauth-credentials -o jsonpath='{.data.oauthClientId}' | base64 -d)
CLIENT_SECRET=$(kubectl get secret -n tailscale tailscale-oauth-credentials -o jsonpath='{.data.oauthClientSecret}' | base64 -d)

# Deploy with Helm
helm upgrade --install tailscale ./helmcharts/tailscale \
  --set-string tailscale-operator.oauth.clientId="$CLIENT_ID" \
  --set-string tailscale-operator.oauth.clientSecret="$CLIENT_SECRET" \
  -n tailscale --create-namespace \
  --wait
```

## Configuration

### Basic Configuration

The official Tailscale operator chart expects OAuth credentials in the `oauth` section. Our wrapper chart passes these through:

```yaml
enabled: true

tailscale-operator:
  enabled: true
  oauth:
    clientId: ""      # Set via helm --set or values file
    clientSecret: ""  # Set via helm --set or values file
  hostname: tailscale-operator
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

### ProxyGroup Configuration (High Availability)

For production deployments, create ProxyGroups for high availability:

1. **Create ProxyGroup manifest:**

```yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyGroup
metadata:
  name: ts-proxies
  namespace: tailscale
spec:
  type: egress  # or "ingress"
  replicas: 3
```

2. **Apply ProxyGroup:**

```bash
kubectl apply -f proxygroup.yaml

# Wait for ProxyGroup to become ready
kubectl wait proxygroup ts-proxies -n tailscale --for=condition=ProxyGroupReady=true
```

See the [official Tailscale operator documentation](https://tailscale.com/kb/1236/kubernetes-operator#optional-pre-creating-a-proxygroup) for details.

## Verification

### Check Operator Status

```bash
# Check operator pod
kubectl get pods -n tailscale -l app.kubernetes.io/name=tailscale-operator

# Check operator logs
kubectl logs -n tailscale -l app.kubernetes.io/name=tailscale-operator --tail=100

# Verify operator has joined tailnet
# Check Tailscale admin console > Machines
# Look for node named "tailscale-operator" tagged with "tag:k8s-operator"
```

### Verify OAuth Connection

```bash
# Check for OAuth-related errors
kubectl logs -n tailscale -l app.kubernetes.io/name=tailscale-operator | grep -i oauth

# Verify operator can access Tailscale API
kubectl get events -n tailscale --sort-by='.lastTimestamp' | grep tailscale
```

## Using the Operator

Once the operator is deployed, you can use it to:

### 1. Expose Cluster Ingress

```yaml
apiVersion: tailscale.com/v1alpha1
kind: Ingress
metadata:
  name: my-app-ingress
  namespace: default
spec:
  service:
    name: my-app
    port:
      number: 80
```

### 2. Configure Cluster Egress

```yaml
apiVersion: tailscale.com/v1alpha1
kind: Service
metadata:
  name: my-tailnet-service
  namespace: default
spec:
  service:
    name: tailnet-service
    port:
      number: 443
```

### 3. Create ProxyGroup for HA

```yaml
apiVersion: tailscale.com/v1alpha1
kind: ProxyGroup
metadata:
  name: ts-proxies
  namespace: tailscale
spec:
  type: egress
  replicas: 3
```

See the [official Tailscale Kubernetes Operator documentation](https://tailscale.com/kb/1236/kubernetes-operator) for detailed usage examples.

## Ingress IP Restriction

Once the Tailscale operator is deployed, configure ingress IP restrictions to only allow traffic from Tailscale subnet:

### Global Configuration

Edit `helmcharts/ingress-nginx/values.yaml`:

```yaml
ingress-nginx:
  controller:
    config:
      whitelist-source-range: "100.64.0.0/10"  # Tailscale default subnet
```

### Per-Ingress Configuration

Add annotation to individual Ingress resources:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: "100.64.0.0/10"
```

See [Ingress IP Restriction Documentation](https://github.com/Alarmify/alarmify-docs/blob/main/docs/envoy-gateway/security/INGRESS-IP-RESTRICTION.md) for detailed configuration.

## Troubleshooting

### Operator Not Joining Tailnet

1. **Check OAuth credentials:**
   ```bash
   # Verify secret exists
   kubectl get secret -n tailscale tailscale-oauth-credentials
   
   # Check OAuth values in operator values
   helm get values tailscale -n tailscale | grep oauth
   
   # Check operator logs for OAuth errors
   kubectl logs -n tailscale -l app.kubernetes.io/name=tailscale-operator | grep -i oauth
   ```

2. **Verify credentials in Tailscale admin console:**
   - Check OAuth client is active
   - Verify client ID and secret match
   - Ensure OAuth client has correct scopes (Devices Core, Auth Keys)

3. **Check operator logs:**
   ```bash
   kubectl logs -n tailscale -l app.kubernetes.io/name=tailscale-operator --tail=100
   ```

4. **Verify Tailnet policy:**
   - Ensure policy includes `tag:k8s-operator` and `tag:k8s` tags
   - Check policy allows operator to create devices

### Proxies Not Starting

1. **Check ProxyGroup status:**
   ```bash
   kubectl get proxygroup -A
   kubectl describe proxygroup <name> -n <namespace>
   ```

2. **Check StatefulSet status:**
   ```bash
   kubectl get statefulset -n tailscale
   kubectl describe statefulset <name> -n tailscale
   ```

3. **Check proxy pods:**
   ```bash
   kubectl get pods -n tailscale
   kubectl logs -n tailscale <proxy-pod-name>
   ```

### Common Issues

- **OAuth credentials incorrect**: Verify in Tailscale admin console
- **Network policies blocking**: Check if NetworkPolicy restricts operator communication
- **Resource limits**: Increase CPU/memory limits if operator is OOM killed
- **Tailnet policy missing**: Update policy file with operator tags

## Upgrading

```bash
# Update dependencies first
helm dependency update helmcharts/tailscale

# Upgrade
helm upgrade tailscale ./helmcharts/tailscale \
  -n tailscale \
  -f values.yaml \
  --set-string tailscale-operator.oauth.clientId="<CLIENT_ID>" \
  --set-string tailscale-operator.oauth.clientSecret="<CLIENT_SECRET>"
```

## Uninstallation

```bash
# Via ArgoCD - remove label
kubectl label secret -n argocd <cluster-secret-name> tailscale-

# Manual uninstall
helm uninstall tailscale -n tailscale

# Clean up namespace (be careful - this removes all Tailscale resources)
kubectl delete namespace tailscale
```

**Note**: Uninstalling the operator will disconnect all Tailscale ingress/egress services from your tailnet. Ensure you have alternative access methods before uninstalling.

## References

- [Tailscale Kubernetes Operator Documentation](https://tailscale.com/kb/1236/kubernetes-operator)
- [Tailscale Admin Console](https://login.tailscale.com/admin)
- [Ingress IP Restriction Documentation](https://github.com/Alarmify/alarmify-docs/blob/main/docs/envoy-gateway/security/INGRESS-IP-RESTRICTION.md)
- [Tailscale Operator GitHub](https://github.com/tailscale/tailscale)

---

## This deployment's configuration

Official Tailscale Kubernetes Operator chart
(<https://pkgs.tailscale.com/helmcharts>). Reference:
<https://tailscale.com/kb/1236/kubernetes-operator>.

### OAuth credentials are required

```yaml
oauth:
  clientId: ""        # e.g. "k123456CNTRL"
  clientSecret: ""    # e.g. "tskey-client-k123456CNTRL-abcdef"
```

The operator uses OAuth client credentials to manage devices via the Tailscale API. Create them
in the [Tailscale admin console](https://login.tailscale.com/admin/settings/oauth_clients).

> 🔐 **Store these in Vault and deliver via External Secrets** — do not commit them. They can
> also be supplied with `helm --set` or a values override.
>
> ⚠️ The client secret is **case-sensitive and must be quoted**.

The operator registers itself in the tailnet under `hostname` (default
`tailscale-operator`).
