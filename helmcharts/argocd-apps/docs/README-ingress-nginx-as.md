# NGINX Ingress Controller ApplicationSet

This ApplicationSet automatically deploys the NGINX Ingress Controller to multiple Kubernetes clusters using ArgoCD. It uses the local helm chart from `helmcharts/ingress-nginx` and supports cluster-specific configurations through value files or parameters.

## Overview

The ApplicationSet supports two deployment modes:

1. **Cluster Generator (Default)**: Automatically discovers and deploys to clusters registered in ArgoCD with the label `ingress-nginx: "true"`
2. **List Generator**: Explicitly defines clusters and their configurations

## Architecture

```
ArgoCD ApplicationSet
    ↓
helmcharts/ingress-nginx (local helm chart)
    ├── values.yaml (default values)
    └── values/
        ├── production/values.yaml (production overrides)
        ├── staging/values.yaml (staging overrides)
        ├── <cluster-name>/values.yaml (cluster-specific overrides)
        └── aws/values.yaml (cloud-specific overrides)
```

## Quick Start

### Method 1: Cluster Generator (Automatic Discovery)

#### 1. Label Your Clusters

```bash
# List clusters
argocd cluster list

# Add label to enable ingress-nginx deployment
argocd cluster set <cluster-url> --label ingress-nginx=true

# Or via kubectl (for cluster secrets)
kubectl label secret -n argocd <cluster-secret-name> ingress-nginx=true
```

#### 2. Apply the ApplicationSet

```bash
kubectl apply -f helmcharts/argocd-apps/templates/applicationsets/ingress-nginx-as.yaml
```

The ApplicationSet will automatically:
- Discover all labeled clusters
- Deploy ingress-nginx using the local helm chart
- Use the default `values.yaml` from `helmcharts/ingress-nginx`
- Auto-sync and self-heal

### Method 2: List Generator (Explicit Clusters)

Edit `ingress-nginx-as.yaml` and switch to list generator:

```yaml
generators:
  # Comment out cluster generator
  # - clusters:
  #     selector:
  #       matchLabels:
  #         ingress-nginx: "true"
  
  # Use list generator
  - list:
      elements:
        - cluster: production
          url: https://kubernetes.default.svc
        - cluster: staging
          url: https://staging-cluster.example.com
        - cluster: development
          url: https://dev-cluster.example.com
```

## Configuration Methods

### Option 1: Cluster-Specific Value Files (Recommended)

Create separate value files for each cluster or environment:

```bash
# Create directory structure
mkdir -p helmcharts/ingress-nginx/values/{production,staging,development}

# Create cluster-specific values
cat > helmcharts/ingress-nginx/values/production/values.yaml <<EOF
ingress-nginx:
  controller:
    replicaCount: 5
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    resources:
      limits:
        cpu: 2000m
        memory: 1Gi
EOF
```

Enable in ApplicationSet:

```yaml
helm:
  valueFiles:
    - values.yaml
    - "values/{{.cluster}}/values.yaml"  # Add this line
```

### Option 2: Helm Parameters (Simple Overrides)

For simple value overrides without creating files:

```yaml
generators:
  - list:
      elements:
        - cluster: production
          url: https://kubernetes.default.svc
          replicas: "5"
          serviceType: LoadBalancer

template:
  spec:
    source:
      helm:
        valueFiles:
          - values.yaml
        parameters:
          - name: "ingress-nginx.controller.replicaCount"
            value: "{{.replicas}}"
          - name: "ingress-nginx.controller.service.type"
            value: "{{.serviceType}}"
```

### Option 3: Environment-Based Value Files

Organize by environment:

```bash
# Directory structure
helmcharts/ingress-nginx/values/
├── production/values.yaml
├── staging/values.yaml
└── development/values.yaml
```

```yaml
generators:
  - list:
      elements:
        - cluster: prod-cluster-1
          url: https://prod1.example.com
          environment: production

template:
  spec:
    source:
      helm:
        valueFiles:
          - values.yaml
          - "values/{{.environment}}/values.yaml"
```

## Value File Examples

### Production Values
```yaml
# helmcharts/ingress-nginx/values/production/values.yaml
ingress-nginx:
  controller:
    replicaCount: 5
    
    autoscaling:
      enabled: true
      minReplicas: 5
      maxReplicas: 20
      targetCPUUtilizationPercentage: 60
    
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
        service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
    
    resources:
      requests:
        cpu: 500m
        memory: 512Mi
      limits:
        cpu: 2000m
        memory: 2Gi
    
    config:
      worker-processes: "auto"
      max-worker-connections: "32768"
    
    ingressClassResource:
      default: true
```

### Staging Values
```yaml
# helmcharts/ingress-nginx/values/staging/values.yaml
ingress-nginx:
  controller:
    replicaCount: 3
    
    autoscaling:
      enabled: true
      minReplicas: 3
      maxReplicas: 10
    
    service:
      type: LoadBalancer
    
    ingressClassResource:
      default: false
```

### Development Values
```yaml
# helmcharts/ingress-nginx/values/development/values.yaml
ingress-nginx:
  controller:
    replicaCount: 2
    
    autoscaling:
      enabled: false
    
    service:
      type: NodePort
      nodePorts:
        http: 30080
        https: 30443
```

### AWS-Specific Values
```yaml
# helmcharts/ingress-nginx/values/aws/values.yaml
ingress-nginx:
  controller:
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
        service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "tcp"
        service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
```

### GCP-Specific Values
```yaml
# helmcharts/ingress-nginx/values/gcp/values.yaml
ingress-nginx:
  controller:
    service:
      type: LoadBalancer
      annotations:
        cloud.google.com/load-balancer-type: "External"
```

## ApplicationSet Configuration Examples

This section provides complete ApplicationSet examples for different deployment scenarios. Copy and adapt these examples to your needs.

### Example 1: Basic Cluster Generator (Automatic Discovery)

Automatically deploy to all clusters labeled with `ingress-nginx=true`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-auto
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - clusters:
        selector:
          matchLabels:
            ingress-nginx: "true"

  template:
    metadata:
      name: "{{.name}}-ingress-nginx"
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
      destination:
        server: "{{.server}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 2: List Generator with Explicit Clusters

Explicitly define which clusters to deploy to:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-list
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - cluster: production
            url: https://kubernetes.default.svc
          - cluster: staging
            url: https://staging-cluster.example.com
          - cluster: development
            url: https://dev-cluster.example.com

  template:
    metadata:
      name: "{{.cluster}}-ingress-nginx"
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
      destination:
        server: "{{.url}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 3: Multi-Environment Deployment

Use environment-specific value files:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-env
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - cluster: production
            url: https://kubernetes.default.svc
            environment: production
          - cluster: staging
            url: https://staging.example.com
            environment: staging
          - cluster: development
            url: https://dev.example.com
            environment: development

  template:
    metadata:
      name: "{{.cluster}}-ingress-nginx"
      namespace: argocd
      labels:
        environment: "{{.environment}}"
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
            - "values/{{.environment}}/values.yaml"
      destination:
        server: "{{.url}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 4: Multi-Cloud Deployment (AWS, GCP, Azure)

Deploy across different cloud providers:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-multicloud
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          # AWS Clusters
          - cluster: aws-prod
            url: https://aws-prod.example.com
            environment: production
            cloud: aws
            region: us-east-1
          
          # GCP Clusters
          - cluster: gcp-prod
            url: https://gcp-prod.example.com
            environment: production
            cloud: gcp
            region: us-central1
          
          # Azure Clusters
          - cluster: azure-prod
            url: https://azure-prod.example.com
            environment: production
            cloud: azure
            region: eastus

  template:
    metadata:
      name: "{{.cluster}}-ingress-nginx"
      namespace: argocd
      labels:
        cloud: "{{.cloud}}"
        region: "{{.region}}"
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
            - "values/production/values.yaml"
            - "values/{{.cloud}}/values.yaml"
      destination:
        server: "{{.url}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 5: AWS Multi-Region Deployment

Deploy to multiple AWS regions:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-aws
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - cluster: aws-us-east-1
            url: https://api.us-east-1.example.com
            environment: production
            region: us-east-1
          - cluster: aws-us-west-2
            url: https://api.us-west-2.example.com
            environment: production
            region: us-west-2
          - cluster: aws-eu-west-1
            url: https://api.eu-west-1.example.com
            environment: production
            region: eu-west-1

  template:
    metadata:
      name: "{{.cluster}}-ingress-nginx"
      namespace: argocd
      labels:
        region: "{{.region}}"
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
            - values/production/values.yaml
            - values/aws/values.yaml
      destination:
        server: "{{.url}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 6: Edge Clusters (Bare Metal/On-Premise)

Deploy to edge locations with NodePort:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-edge
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - cluster: edge-eu-1
            url: https://edge-eu-1.example.com
            environment: edge
            location: eu-west-1
          - cluster: edge-us-1
            url: https://edge-us-1.example.com
            environment: edge
            location: us-east-1
          - cluster: edge-ap-1
            url: https://edge-ap-1.example.com
            environment: edge
            location: ap-south-1

  template:
    metadata:
      name: "{{.cluster}}-ingress-nginx"
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
            - values/development/values.yaml  # Use NodePort config
      destination:
        server: "{{.url}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 7: Using Helm Parameters for Simple Overrides

Override specific values without creating separate files:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-params
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - cluster: production
            url: https://kubernetes.default.svc
            replicas: "5"
            serviceType: LoadBalancer
          - cluster: staging
            url: https://staging-cluster.example.com
            replicas: "3"
            serviceType: LoadBalancer
          - cluster: development
            url: https://dev-cluster.example.com
            replicas: "2"
            serviceType: NodePort

  template:
    metadata:
      name: "{{.cluster}}-ingress-nginx"
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
          parameters:
            - name: "ingress-nginx.controller.replicaCount"
              value: "{{.replicas}}"
            - name: "ingress-nginx.controller.service.type"
              value: "{{.serviceType}}"
      destination:
        server: "{{.url}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 8: Cluster Generator with Label Filtering

Deploy only to specific environments using label expressions:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-filtered
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - clusters:
        selector:
          matchLabels:
            ingress-nginx: "true"
          matchExpressions:
            - key: environment
              operator: In
              values: [production, staging]

  template:
    metadata:
      name: "{{.name}}-ingress-nginx"
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
      destination:
        server: "{{.server}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 9: Git File Generator

Store cluster configurations in separate JSON files:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-git
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - git:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        revision: HEAD
        files:
          - path: "cluster-configs/*/ingress-nginx.json"

  template:
    metadata:
      name: "{{.cluster.name}}-ingress-nginx"
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
          parameters:
            - name: "ingress-nginx.controller.replicaCount"
              value: "{{.cluster.replicas}}"
            - name: "ingress-nginx.controller.service.type"
              value: "{{.cluster.serviceType}}"
      destination:
        server: "{{.cluster.server}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

Example JSON file (`cluster-configs/production/ingress-nginx.json`):
```json
{
  "cluster": {
    "name": "production",
    "server": "https://kubernetes.default.svc",
    "replicas": "5",
    "serviceType": "LoadBalancer"
  }
}
```

### Example 10: Matrix Generator

Combine cluster discovery with configuration variants:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-matrix
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - clusters:
              selector:
                matchLabels:
                  ingress-nginx: "true"
          - list:
              elements:
                - tier: standard
                - tier: high-availability

  template:
    metadata:
      name: "{{.name}}-{{.tier}}-ingress-nginx"
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
            - "values/{{.tier}}/values.yaml"
      destination:
        server: "{{.server}}"
        namespace: ingress-nginx-{{.tier}}
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 11: Progressive Rollout Strategy

Deploy in stages (canary → staging → production):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-progressive
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          # Stage 1: Canary
          - cluster: canary-1
            url: https://canary1.example.com
            stage: "1"
          # Stage 2: Staging
          - cluster: staging-1
            url: https://staging1.example.com
            stage: "2"
          # Stage 3: Production
          - cluster: production-1
            url: https://prod1.example.com
            stage: "3"

  template:
    metadata:
      name: "{{.cluster}}-ingress-nginx"
      namespace: argocd
      annotations:
        rollout-stage: "{{.stage}}"
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
            - "values/stage-{{.stage}}/values.yaml"
      destination:
        server: "{{.url}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### Example 12: High-Performance Production

Production cluster with optimized resources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: ingress-nginx-high-perf
  namespace: argocd
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - cluster: production-ha
            url: https://kubernetes.default.svc
            environment: production

  template:
    metadata:
      name: "{{.cluster}}-ingress-nginx"
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: git@github.com:defyjoy/argocd-google-cloud.git
        targetRevision: HEAD
        path: helmcharts/ingress-nginx
        helm:
          valueFiles:
            - values.yaml
            - values/production/values.yaml
          # Additional performance tuning via parameters
          parameters:
            - name: "ingress-nginx.controller.config.worker-processes"
              value: "auto"
            - name: "ingress-nginx.controller.config.max-worker-connections"
              value: "32768"
            - name: "ingress-nginx.controller.autoscaling.maxReplicas"
              value: "20"
            - name: "ingress-nginx.controller.autoscaling.targetCPUUtilizationPercentage"
              value: "60"
      destination:
        server: "{{.url}}"
        namespace: ingress-nginx
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

## Monitoring Deployments

### Check ApplicationSet Status

```bash
# View ApplicationSet
kubectl get applicationset -n argocd ingress-nginx

# Describe ApplicationSet
kubectl describe applicationset -n argocd ingress-nginx

# View generated Applications
kubectl get applications -n argocd -l cluster
```

### Check Application Sync Status

```bash
# List all applications
argocd app list | grep ingress-nginx

# Get specific application
argocd app get <cluster-name>-ingress-nginx

# Sync application
argocd app sync <cluster-name>-ingress-nginx

# View application diff
argocd app diff <cluster-name>-ingress-nginx
```

### Verify Deployment in Target Cluster

```bash
# Switch to target cluster
kubectl config use-context <cluster-context>

# Check pods
kubectl get pods -n ingress-nginx

# Check service
kubectl get svc -n ingress-nginx ingress-nginx-controller

# View controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -f
```

## Registering Clusters

### Add Cluster to ArgoCD

```bash
# View available contexts
kubectl config get-contexts

# Add cluster
argocd cluster add <context-name> --name <cluster-name>

# Label for ingress-nginx deployment
argocd cluster set <cluster-url> --label ingress-nginx=true
argocd cluster set <cluster-url> --label environment=production
```

### Via Kubernetes Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: cluster-production
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    ingress-nginx: "true"
    environment: production
type: Opaque
stringData:
  name: production
  server: https://production.example.com
  config: |
    {
      "bearerToken": "<token>",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "<base64-ca-cert>"
      }
    }
```

## Troubleshooting

### ApplicationSet Not Creating Applications

1. **Check ApplicationSet controller logs:**
```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller
```

2. **Verify cluster labels:**
```bash
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=cluster --show-labels
```

3. **Check generator configuration:**
```bash
kubectl get applicationset -n argocd ingress-nginx -o yaml
```

### Application Sync Failures

1. **Check application status:**
```bash
argocd app get <cluster-name>-ingress-nginx
```

2. **View sync errors:**
```bash
kubectl get application -n argocd <cluster-name>-ingress-nginx -o jsonpath='{.status.conditions}'
```

3. **Manual sync with force:**
```bash
argocd app sync <cluster-name>-ingress-nginx --force
```

### Value File Not Found

If using cluster-specific value files:

```bash
# Verify file exists
ls -la helmcharts/ingress-nginx/values/<cluster-name>/

# Check ApplicationSet template
kubectl get applicationset -n argocd ingress-nginx -o yaml | grep valueFiles -A 5

# Temporarily disable cluster-specific values
# Comment out the value file in the ApplicationSet
```

### Webhook Configuration Issues

```bash
# Delete and recreate webhooks
kubectl delete validatingwebhookconfiguration ingress-nginx-admission
kubectl delete mutatingwebhookconfiguration ingress-nginx-admission

# Trigger sync
argocd app sync <cluster-name>-ingress-nginx
```

## Advanced Patterns

### Progressive Rollout

Deploy to canary → staging → production:

```yaml
generators:
  - list:
      elements:
        - cluster: canary
          url: https://canary.example.com
          stage: "1"
        - cluster: staging
          url: https://staging.example.com
          stage: "2"
        - cluster: production
          url: https://production.example.com
          stage: "3"

template:
  metadata:
    annotations:
      rollout-stage: "{{.stage}}"
  spec:
    source:
      helm:
        valueFiles:
          - values.yaml
          - "values/stage-{{.stage}}/values.yaml"
```

### Matrix Generator

Combine clusters with configuration variants:

```yaml
generators:
  - matrix:
      generators:
        - clusters:
            selector:
              matchLabels:
                ingress-nginx: "true"
        - list:
            elements:
              - tier: standard
              - tier: high-availability

template:
  metadata:
    name: "{{.name}}-{{.tier}}-ingress-nginx"
  spec:
    source:
      helm:
        valueFiles:
          - values.yaml
          - "values/{{.tier}}/values.yaml"
    destination:
      namespace: ingress-nginx-{{.tier}}
```

### Git File Generator

Store cluster configs in Git files:

```yaml
generators:
  - git:
      repoURL: git@github.com:defyjoy/argocd-google-cloud.git
      revision: HEAD
      files:
        - path: "cluster-configs/*/ingress-nginx.json"

# cluster-configs/production/ingress-nginx.json
{
  "cluster": "production",
  "server": "https://kubernetes.default.svc",
  "replicas": 5
}
```

## Best Practices

1. **Use Value Files**: Prefer cluster-specific value files over inline parameters
2. **Version Control**: Keep all value files in Git
3. **Environment Hierarchy**: `values.yaml` → `values/environment/` → `values/cluster/`
4. **Naming Convention**: Use consistent cluster naming (env-cloud-region pattern)
5. **Label Strategy**: Use meaningful labels for filtering (environment, cloud, region)
6. **Auto-Sync**: Enable for non-production, consider manual for production
7. **Testing**: Test with one cluster before rolling out to all
8. **Documentation**: Document cluster-specific customizations
9. **Secrets**: Use external secrets operators, not inline values
10. **Monitoring**: Set up alerts for sync failures

## Migration Guide

### From Manual Helm Deployments

1. Create value files for each cluster in `helmcharts/ingress-nginx/values/<cluster>/`
2. Test ApplicationSet with one cluster first
3. Apply ApplicationSet
4. Verify sync
5. Gradually onboard more clusters
6. Remove manual deployments

### From Individual ArgoCD Applications

1. Export existing application values
2. Create corresponding value files
3. Apply ApplicationSet
4. Verify generated applications match existing ones
5. Delete old individual applications

## Security Considerations

1. **RBAC**: Ensure ArgoCD service account has proper permissions
2. **Secrets**: Never commit secrets in value files
3. **Network Policies**: Configure for ingress-nginx namespace
4. **TLS**: Use TLS for all cluster communications
5. **Admission Webhooks**: Validate configurations

## See Also

- [ApplicationSet Examples](./ingress-nginx-as-examples.yaml) - More configuration examples
- [Helm Chart README](../../ingress-nginx/README.md) - Detailed helm chart documentation
- [ArgoCD ApplicationSet](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)
- [Cluster Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/)
