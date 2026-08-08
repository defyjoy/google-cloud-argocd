# Backstage - Developer Portal Platform

This Helm chart deploys [Backstage](https://backstage.io/), an open platform for building developer portals. Backstage unifies all your infrastructure tooling, services, and documentation to create a streamlined development environment.

## Overview

Backstage is a developer portal platform that provides:

- **Service Catalog**: Centralized view of all software components, services, and resources
- **Software Templates**: Standardized project scaffolding and best practices
- **TechDocs**: Documentation as code, built into the developer workflow
- **Kubernetes Plugin**: View and manage Kubernetes resources
- **Search**: Unified search across all your tools and documentation
- **Extensible**: Plugin architecture for custom integrations

## Features

### Core Capabilities

- **Service Catalog**: Track ownership, metadata, and dependencies
- **Software Templates**: Create new projects from templates
- **TechDocs**: Documentation powered by MkDocs
- **Search**: Find services, docs, and resources quickly
- **Plugins**: Extend with 100+ community plugins

### Integrations

- **Source Control**: GitHub, GitLab, Bitbucket
- **CI/CD**: Jenkins, CircleCI, GitHub Actions
- **Cloud Providers**: AWS, GCP, Azure
- **Monitoring**: Prometheus, Grafana, Datadog
- **Kubernetes**: View pods, deployments, and services

## Prerequisites

- Kubernetes 1.19+
- Helm 3.0+
- ArgoCD (for GitOps deployment)
- Ingress controller (NGINX recommended)
- cert-manager (for TLS certificates)

## Installation

### Using Helm

```bash
# Add the Backstage Helm repository
helm repo add backstage https://backstage.github.io/charts
helm repo update

# Install Backstage
helm install backstage ./helmcharts/backstage \
  --namespace backstage \
  --create-namespace
```

### Using ArgoCD

1. **Label your cluster**:
   ```bash
   kubectl label secret -n argocd cluster-local backstage=true
   ```

2. **Deploy the ApplicationSet**:
   The ApplicationSet will automatically deploy Backstage to labeled clusters.

3. **Verify deployment**:
   ```bash
   kubectl get pods -n backstage
   kubectl get ingress -n backstage
   ```

## Configuration

### Basic Configuration

The chart uses the official Backstage Helm chart as a dependency. Key configuration options:

```yaml
backstage:
  enabled: true

  ingress:
    enabled: true
    className: "nginx"
    host: "backstage.workquark.org"
    # TLS disabled as using Cloudflare tunnel
    tls:
      enabled: false
  
  backstage:
    replicas: 1
    resources:
      limits:
        cpu: 1000m
        memory: 1Gi
      requests:
        cpu: 250m
        memory: 512Mi
```

### Ingress Configuration

The ingress is configured to use Cloudflare tunnel. TLS is handled by Cloudflare:

```yaml
backstage:
  ingress:
    enabled: true
    className: "nginx"
    annotations:
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
      external-dns.alpha.kubernetes.io/hostname: backstage.workquark.org
      external-dns.alpha.kubernetes.io/target: d4172297-9b0d-4d45-a447-d22cff68546d.cfargotunnel.com
    host: "backstage.workquark.org"
    # TLS disabled as using Cloudflare tunnel
    tls:
      enabled: false
      # secretName: "backstage-tls"
```

### Application Configuration

Backstage is configured via the `appConfig` section in `values.yaml`:

```yaml
backstage:
  backstage:
    appConfig:
      app:
        title: My Company Developer Portal
        baseUrl: https://backstage.workquark.org

      organization:
        name: My Company

      backend:
        baseUrl: https://backstage.workquark.org
        database:
          client: better-sqlite3
          connection: ':memory:'
      
      integrations:
        github:
          - host: github.com
            token: ${GITHUB_TOKEN}
```

### Database Configuration

By default, Backstage uses an in-memory SQLite database. For production, use PostgreSQL:

```yaml
backstage:
  backstage:
    appConfig:
      backend:
        database:
          client: pg
          connection:
            host: ${POSTGRES_HOST}
            port: ${POSTGRES_PORT}
            user: ${POSTGRES_USER}
            password: ${POSTGRES_PASSWORD}
  
  postgresql:
    enabled: true
    auth:
      username: backstage
      password: backstage
      database: backstage
```

### GitHub Integration

To integrate with GitHub:

1. **Create a GitHub OAuth App**:
   - Go to GitHub Settings → Developer settings → OAuth Apps
   - Set Authorization callback URL: `https://backstage.workquark.org/api/auth/github/handler/frame`

2. **Create a GitHub Personal Access Token**:
   - Go to GitHub Settings → Developer settings → Personal access tokens
   - Required scopes: `repo`, `workflow`, `read:org`, `read:user`, `user:email`

3. **Configure in values.yaml**:
   ```yaml
   backstage:
     backstage:
       extraEnvVars:
         - name: GITHUB_TOKEN
           valueFrom:
             secretKeyRef:
               name: backstage-secrets
               key: github-token
       
       appConfig:
         integrations:
           github:
             - host: github.com
               token: ${GITHUB_TOKEN}
         
         auth:
           environment: production
           providers:
             github:
               development:
                 clientId: ${GITHUB_CLIENT_ID}
                 clientSecret: ${GITHUB_CLIENT_SECRET}
   ```

4. **Create the secret**:
   ```bash
   kubectl create secret generic backstage-secrets \
     -n backstage \
     --from-literal=github-token=ghp_your_token_here \
     --from-literal=github-client-id=your_client_id \
     --from-literal=github-client-secret=your_client_secret
   ```

### Kubernetes Plugin

To enable the Kubernetes plugin:

```yaml
backstage:
  backstage:
    appConfig:
      kubernetes:
        serviceLocatorMethod:
          type: 'multiTenant'
        clusterLocatorMethods:
          - type: 'config'
            clusters:
              - url: https://kubernetes.default.svc
                name: local
                authProvider: 'serviceAccount'
                skipTLSVerify: false
                skipMetricsLookup: false
  
  serviceAccount:
    create: true
    automountServiceAccountToken: true
```

## Usage

### Accessing Backstage

Once deployed, access Backstage at: `https://backstage.workquark.org`

### Creating a Service Catalog Entry

Create a `catalog-info.yaml` in your repository:

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: my-service
  description: My awesome service
  annotations:
    github.com/project-slug: myorg/my-service
spec:
  type: service
  lifecycle: production
  owner: team-a
  system: my-system
```

### Using Software Templates

Software templates allow you to scaffold new projects:

1. Navigate to "Create" in Backstage
2. Select a template
3. Fill in the parameters
4. Backstage will create a new repository with the scaffolded code

## Monitoring

### Health Checks

Backstage exposes health check endpoints:

- Liveness: `/healthcheck`
- Readiness: `/healthcheck`

### Metrics

Enable Prometheus metrics:

```yaml
backstage:
  metrics:
    serviceMonitor:
      enabled: true
      interval: 30s
      path: /metrics
```

## Troubleshooting

### Pod Not Starting

Check pod logs:
```bash
kubectl logs -n backstage -l app.kubernetes.io/name=backstage
```

### Ingress Not Working

Verify ingress configuration:
```bash
kubectl get ingress -n backstage
kubectl describe ingress -n backstage backstage
```

### Database Connection Issues

Check database connectivity:
```bash
kubectl exec -it -n backstage deployment/backstage -- sh
# Test database connection
```

## Security

### Security Context

The chart uses restricted security contexts:

```yaml
backstage:
  backstage:
    podSecurityContext:
      runAsNonRoot: true
      runAsUser: 1000
      fsGroup: 1000
    
    containerSecurityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
      readOnlyRootFilesystem: false
```

### Secrets Management

Use Kubernetes secrets or External Secrets Operator for sensitive data:

```bash
kubectl create secret generic backstage-secrets \
  -n backstage \
  --from-literal=github-token=your_token \
  --from-literal=postgres-password=your_password
```

## Resources

- [Official Documentation](https://backstage.io/docs)
- [Backstage GitHub](https://github.com/backstage/backstage)
- [Helm Chart Repository](https://github.com/backstage/charts)
- [Plugin Marketplace](https://backstage.io/plugins)
- [Community Discord](https://discord.gg/backstage-687207715902193673)

## License

Backstage is licensed under the Apache License 2.0.

---

## This deployment's configuration

### Routing

The chart's Ingress is disabled in favour of a Gateway API `HTTPRoute`. TLS is **not**
configured here — it terminates at the Cloudflare tunnel, so the `backstage-tls` secret
reference in the disabled Ingress block is inert.

### App config

Backstage's main configuration is supplied as **inline YAML** in `values.yaml` rather than a
separate ConfigMap.

> 🔐 The GitHub integration block is present but commented out upstream. If enabled, supply
> `token` from a Secret (e.g. `${GITHUB_TOKEN}` via External Secrets) rather than inline.

### Availability

A PodDisruptionBudget and autoscaling settings are present; both pod- and container-level
security contexts are set for `restricted` PodSecurity.
