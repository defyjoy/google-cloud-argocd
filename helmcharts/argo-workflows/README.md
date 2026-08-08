# Argo Workflows Helm Chart

A Helm chart for Argo Workflows - Container-native workflow engine for Kubernetes.

## Overview

Argo Workflows is an open-source container-native workflow engine for orchestrating parallel jobs on Kubernetes. This chart deploys Argo Workflows with GitHub OAuth authentication and Gateway API HTTPRoute support.

## Features

- **GitHub OAuth SSO**: Secure authentication using GitHub OAuth
- **Gateway API HTTPRoute**: Modern ingress using Kubernetes Gateway API
- **Workflow Templates**: Example workflows included
- **Security Compliant**: Configured with proper security contexts
- **Production Ready**: Resource limits and high availability configurations
- **GitOps Ready**: Designed for ArgoCD deployment

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- ArgoCD (for GitOps deployment)
- Envoy Gateway (for HTTPRoute support)
- GitHub OAuth App (for SSO authentication)

## Installation

### Using Helm

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argo-workflows ./helmcharts/argo-workflows
```

### Using ArgoCD

1. Label your cluster: `kubectl label cluster <cluster-name> argo-workflows=true`
2. Deploy the ApplicationSet
3. Configure GitHub OAuth (see below)

## Configuration

### GitHub OAuth Setup

#### 1. Create GitHub OAuth App

1. Go to [GitHub Settings → Developer settings → OAuth Apps](https://github.com/settings/developers)
2. Click "New OAuth App"
3. Fill in the details:
   - **Application name**: Argo Workflows
   - **Homepage URL**: `https://argo-workflows.workquark.org`
   - **Authorization callback URL**: `https://argo-workflows.workquark.org/oauth2/callback`
4. Click "Register application"
5. Copy the **Client ID** and generate a **Client Secret**

#### 2. Create Kubernetes Secret

**Option A: Using kubectl**

```bash
kubectl create secret generic argo-server-sso \
  -n argo-workflows \
  --from-literal=client-id='YOUR_GITHUB_CLIENT_ID' \
  --from-literal=client-secret='YOUR_GITHUB_CLIENT_SECRET'
```

**Option B: Using External Secrets Operator**

Create an ExternalSecret to sync from Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: argo-server-sso
  namespace: argo-workflows
spec:
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: argo-server-sso
    creationPolicy: Owner
  data:
    - secretKey: client-id
      remoteRef:
        key: secret/data/argo-workflows
        property: github-client-id
    - secretKey: client-secret
      remoteRef:
        key: secret/data/argo-workflows
        property: github-client-secret
```

### HTTPRoute Configuration

The chart is configured to use Gateway API HTTPRoute for ingress. The HTTPRoute is automatically created and points to:

- **Hostname**: `argo-workflows.workquark.org`
- **Gateway**: `default` in `envoy-gateway-system` namespace
- **Service**: Argo Workflows server service on port `2746`

### Workflow Templates

Example workflows are included in the `templates/` directory:

- **suspend-template.yaml**: Demonstrates suspend templates for manual approval workflows

To submit a workflow:

```bash
# Using kubectl
kubectl apply -f templates/suspend-template.yaml

# Using Argo CLI
argo submit templates/suspend-template.yaml -n argo-workflows
```

## Usage

### Accessing the UI

Once deployed, access the Argo Workflows UI at:

```
https://argo-workflows.workquark.org
```

You will be redirected to GitHub for authentication.

### Submitting Workflows

```bash
# Submit a workflow
argo submit workflows/my-workflow.yaml -n argo-workflows

# List workflows
argo list -n argo-workflows

# Get workflow status
argo get <workflow-name> -n argo-workflows

# Resume a suspended workflow
argo resume <workflow-name> -n argo-workflows
```

### Example: Suspend Template Workflow

The suspend template workflow demonstrates:

1. **Build step**: Runs a hello-world container
2. **Approve step**: Suspends and waits for manual approval
3. **Delay step**: Automatically resumes after 20 seconds
4. **Release step**: Runs another hello-world container

To use it:

```bash
# Submit the workflow
argo submit templates/suspend-template.yaml -n argo-workflows

# Wait for it to reach the approve step (it will suspend)
# Resume it manually
argo resume suspend-template-<random-suffix> -n argo-workflows
```

## Configuration Reference

### Server Configuration

- **HTTPRoute**: Enabled with hostname `argo-workflows.workquark.org`
- **SSO**: Enabled with GitHub OAuth
- **Auth Modes**: `sso` (GitHub OAuth)

### Security

All components are configured with:
- PodSecurity restricted policy compliance
- Non-root user execution
- Seccomp profiles
- Dropped capabilities

## Troubleshooting

### SSO Not Working

1. Verify the secret exists:
   ```bash
   kubectl get secret argo-server-sso -n argo-workflows
   ```

2. Check the server logs:
   ```bash
   kubectl logs -n argo-workflows deployment/argo-workflows-server
   ```

3. Verify the callback URL matches GitHub OAuth App configuration

### HTTPRoute Not Working

1. Check if Gateway exists:
   ```bash
   kubectl get gateway -n envoy-gateway-system
   ```

2. Check HTTPRoute status:
   ```bash
   kubectl get httproute -n argo-workflows
   kubectl describe httproute -n argo-workflows
   ```

3. Verify DNS is pointing to the Gateway IP

## References

- [Argo Workflows Documentation](https://argoproj.github.io/argo-workflows/)
- [Argo Workflows SSO Configuration](https://argoproj.github.io/argo-workflows/argo-server-sso/)
- [GitHub OAuth Apps](https://docs.github.com/en/developers/apps/building-oauth-apps/creating-an-oauth-app)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)

---

## This deployment's configuration

Dependency chart 1.0.13, app version v4.0.5. Satisfies the `argo-workflows.enabled` condition in
`Chart.yaml`. Upstream reference:
<https://github.com/argoproj/argo-helm/blob/main/charts/argo-workflows/values.yaml>.

### Security contexts are required

Both pod- and container-level security contexts are set explicitly — they are **required for
`restricted` PodSecurity**, and the chart does not supply them.

### Routing via HTTPRoute

The chart's Ingress is disabled in favour of a Gateway API `HTTPRoute`.

> ⚠️ **Gateway API support in this chart is EXPERIMENTAL**, and behaviour depends on the Gateway
> controller implementation. See
> <https://gateway-api.sigs.k8s.io/implementations/> for controller-specific detail.
