# ArgoCD - GitOps Continuous Delivery

This Helm chart deploys ArgoCD, a declarative GitOps continuous delivery tool for Kubernetes.

## Table of Contents

- [Overview](#overview)
- [Bootstrap Installation](#bootstrap-installation)
- [Self-Managed ArgoCD](#self-managed-argocd)
- [Configuration](#configuration)
- [Access ArgoCD](#access-argocd)
- [Common Workflows](#common-workflows)
- [Troubleshooting](#troubleshooting)
- [References](#references)

## Overview

ArgoCD follows the GitOps pattern where:
- Git is the single source of truth for your infrastructure
- Changes are made via pull requests
- ArgoCD automatically syncs the desired state from Git to the cluster
- ArgoCD can manage itself after the initial bootstrap

## Bootstrap Installation

The initial installation is done manually using Helm. After this, ArgoCD will manage itself.

**Task runner (recommended):** From the **repository root**, run `task bootstrap` using [`Taskfile.yml`](../../Taskfile.yml) and [`scripts/`](../../scripts/) (see also [`helmcharts/argocd/bootstrap/README.md`](bootstrap/README.md)).

### Prerequisites

- Kubernetes cluster (v1.22+)
- Helm 3.x installed
- kubectl configured
- Git repository access

### Step 1: Install ArgoCD

```bash
# Navigate to ArgoCD chart directory
cd helmcharts/argocd

# Update Helm dependencies
helm dependency update

# Install ArgoCD
helm install argocd . -n argocd --create-namespace
```

### Step 2: Get Initial Admin Password

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

### Step 3: Access ArgoCD UI

```bash
# Port forward to access UI (if not using ingress)
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Access UI at: https://localhost:8080
# Username: admin
# Password: (from step 2)
```

### Step 4: Login via CLI

```bash
# Install ArgoCD CLI
brew install argocd  # macOS
# or download from: https://github.com/argoproj/argo-cd/releases

# Login
argocd login localhost:8080 --username admin --password <password> --insecure

# Change admin password
argocd account update-password
```

## Self-Managed ArgoCD

After the initial bootstrap, configure ArgoCD to manage itself from Git. This is the GitOps way!

### Method 1: Using ArgoCD UI

1. **Login to ArgoCD UI**
2. **Create Application** → New App
3. **Configure Application:**
   ```yaml
   Application Name: argocd
   Project: default
   
   Source:
     Repository URL: git@github.com:defyjoy/argocd-google-cloud.git
     Revision: HEAD
     Path: helmcharts/argocd
   
   Destination:
     Cluster: https://kubernetes.default.svc
     Namespace: argocd
   
   Sync Policy:
     - Auto-Create Namespace: ✓
     - Prune Resources: ✓
     - Self Heal: ✓
   ```
4. **Click Create**

### Method 2: Using ArgoCD CLI

```bash
argocd app create argocd \
  --repo git@github.com:defyjoy/argocd-google-cloud.git \
  --path helmcharts/argocd \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace argocd \
  --sync-policy automated \
  --self-heal \
  --auto-prune
```

### Method 3: Using kubectl (Declarative)

Create an Application manifest:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  
  source:
    repoURL: git@github.com:defyjoy/argocd-google-cloud.git
    targetRevision: HEAD
    path: helmcharts/argocd
    helm:
      valueFiles:
        - values.yaml
  
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
```

### Verify Self-Management

```bash
# Check if ArgoCD Application exists
kubectl get application -n argocd argocd

# Check sync status
argocd app get argocd

# View in UI
# Applications → argocd → should show "Synced" and "Healthy"
```

### Sync ordering: the dev-cluster ExternalSecret

`templates/cluster/dev-cluster-secret.yaml` renders an `external-secrets.io/v1` ExternalSecret,
but the self-managed `argocd` Application syncs at sync-wave `-30` — first of everything. Its
three prerequisites all land much later:

| Needs | Provided by | Wave |
|---|---|---|
| ExternalSecret CRD + ESO controller | `external-secrets-operator-as.yaml` | 4 |
| `ClusterSecretStore/vault-secretstore` | `helmcharts/external-secrets` | 4 |
| Vault, unsealed, with `argocd/dev-cluster` populated | `hashicorp-vault-as.yaml` | 3 |

On a freshly rebuilt cluster the CRD therefore does not exist when this app first syncs. That is
not a cosmetic "one resource is red" problem: a missing CRD fails gitops-engine's **pre-apply
dry-run**, and a dry-run failure aborts the *whole* sync operation before a single object is
applied. The 2026-08-05 management rebuild sat with all 73 resources `OutOfSync` and a
`syncResult` containing exactly one entry:

```
Application/argocd  OutOfSync / Healthy   phase: Running, retryCount: 4
  message: "one or more synchronization tasks are not valid"
  ExternalSecret argocd/dev-cluster  SyncFailed
    "The Kubernetes API could not find external-secrets.io/ExternalSecret …"
```

The self-managed app was applying **nothing** — not the argo-cd chart, not the CoreDNS ConfigMap,
and critically not `Secret/local`, the cluster Secret every ApplicationSet gates on. Argo CD kept
running only because the bootstrap `helm install` had put it there.

The fix is to exempt that one resource from the dry-run:

```yaml
metadata:
  name: dev-cluster
  annotations:
    argocd.argoproj.io/managed: "true"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

The other 72 resources now apply on the very first sync. The ExternalSecret itself still reports
`SyncFailed` until wave 4 installs the CRD, then self-heals to `Synced`/`Healthy` on the next
reconcile (`timeout.reconciliation: 180s`). A red `argocd` app for the first few minutes of a
rebuild is expected; a red `argocd` app *after* `local-external-secrets-operator` is Healthy is
not — check `kubectl get externalsecret -n argocd dev-cluster` and the Vault path
`argocd/dev-cluster` at that point.

`values-bootstrap.yaml` sidesteps all of this with `devCluster.enabled: false`, which is why the
Helm bootstrap install never hit it — the deadlock only appears once GitOps takes over with
`values.yaml`'s `devCluster.enabled: true`.

### dev-cluster component labels

The `target.template.metadata.labels` block on the dev-cluster Secret is what every
ApplicationSet's `cluster-generator` selector matches against — `matchExpressions` on
`"true"` / `"false"`, AND'ed with `environment In [dev, local]` (see
`helmcharts/argocd-apps/templates/applicationsets/istio/istio-base-as.yaml`). Adding a label
here is what deploys a component to dev; there is no other switch.

```yaml
        labels:
          argocd.argoproj.io/secret-type: cluster
          environment: dev
          istio-network: network-dev
          cilium: "true"
          istio-base: "true"
```

`istio-network` is not a selector — it is dev's Istio network identity, matching
`global.network` in `helmcharts/istio/istiod/values/dev.yaml`. `istio-base-as.yaml` and
`istiod-as.yaml` read it via `managedNamespaceMetadata` to stamp
`topology.istio.io/network` onto `istio-system`.

**Three labels have a manual Vault prerequisite.** Each one's ExternalSecret fails to resolve
if the path is empty, so populate Vault *before* pushing the label:

| Label | Requires in Vault |
|---|---|
| `istio-remote-secrets` | `kv/istio/remote-secret-management` |
| `istio-cacerts` | `kv/istio/cacerts-dev` |
| `victoria-metrics` | `kv/victoria-metrics/remote-write-token`, plus management's `values/local.yaml` vmauth/vminsert exposure already live — otherwise remote-writes fail closed against a proxy with no valid token |

Labels were added one at a time, each verified Synced/Healthy before the next
(ADR-006, `docs/istio/istio-ambient-multicluster-management-dev-plan.md`), mirroring the
discipline in `docs/istio/istio-kiali-rollout-runbook.md`. Notes on individual components:

- **`cilium`** — enabled 2026-07-23 once Talos `cni: none` / `proxy.disabled` was applied. It
  installed Cilium alongside the then-still-running Flannel/kube-proxy; the datapath cutover
  was a separate manual step.
- **`istio-gateway`** — dev's own gateway at `.155`, HTTPS via cert-manager's `stepca-acme`
  ClusterIssuer. `helmcharts/cert-manager/values/dev.yaml` is already environment-gated, so
  that chart needs no label of its own.
- **`kiali`** — RBAC-only on dev (`deployment.remote_cluster_resources_only=true` in
  `values/dev.yaml`), no server pod. Safe to push standalone: it creates no Vault dependency
  and no cross-cluster secret. The `kiali.io/multiCluster` secret on management is a later,
  separate step — it needs a token minted *from* the ServiceAccount this label creates.
- **`postgresql-global-service`** — native ambient multicluster needs the plain Kubernetes
  Service present in every source cluster for DNS, while global endpoint discovery supplies
  management's real CNPG endpoint through the east-west gateway.
- **`pg-egress-bridge`** — retained for rollback only. Management renders no socat Deployment;
  this keeps the endpoint-less dev facade available during the first native cutover.

Two labels are deliberately commented out:

- **`gateway-api-crds`** — the CRDs are now vendored in git (`helmcharts/gateway-api-crds`,
  experimental channel v1.5.1) rather than applied out-of-band, and management has been
  adopted. Leave it off until dev's *live* CRD inventory is confirmed against the vendored
  bundle (procedure in that chart's README). Do not trust git for dev's current version — an
  earlier comment in this template claimed v1.4.1 while management was really on v1.5.1.
- **`ollama`** — not yet deployed to dev (`docs/migration/proxmox-migration.md` Phase 7).

### Permanently OutOfSync: VMServiceScrape mirrors

`victoria-metrics-operator` mirrors every `ServiceMonitor` into a `VMServiceScrape`
(`selectAllByDefault: true`) and copies the parent's labels and annotations **verbatim** — including
Argo's `argocd.argoproj.io/tracking-id` and `app.kubernetes.io/instance`. With
`application.resourceTrackingMethod: annotation+label` the result is a resource that claims to
belong to an Application but appears in no manifest:

```
VMServiceScrape/argocd-repo-server
  argocd.argoproj.io/tracking-id: argocd:monitoring.coreos.com/ServiceMonitor:argocd/argocd-repo-server
  app.kubernetes.io/instance: argocd
  ownerReferences: (none)
```

The tracking-id names `ServiceMonitor` while sitting on a `VMServiceScrape`, so Argo can never
reconcile it against anything, and there is no ownerReference to garbage-collect it. Argo flags it
as extra, the operator immediately recreates it, and the Application never leaves `OutOfSync`. On
2026-08-05 this pinned `argocd`, `local-cert-manager` and `local-kyverno` simultaneously.

The fix excludes the mirrored kind from Argo's view entirely:

```yaml
  configs:
    cm:
      resource.exclusions: |
        - apiGroups: ["operator.victoriametrics.com"]
          kinds: ["VMServiceScrape"]
          clusters: ["*"]
```

This is safe only because **no chart in this repo declares a `VMServiceScrape` directly** — verify
with `grep -rn "kind: VMServiceScrape" helmcharts/` before relying on it. It covers every chart that
ships a `ServiceMonitor`: `argocd`, `cert-manager`, `kyverno`, `zitadel` and `kube-prometheus-stack`
all produced phantoms of this exact shape.

`VMPodScrape` is deliberately **not** excluded, because `istio-eastwest`, `istio-gateway`, `ztunnel`
and the six `alarmify-*` charts declare theirs in git and Argo must keep managing them. That leaves
`PodMonitor` mirrors unprotected, so any chart shipping one has to declare a `VMPodScrape` directly
instead — `nats` was the only such chart and was converted (see `helmcharts/nats/README.md`).

**When adding a chart:** a `ServiceMonitor` is safe (the exclusion absorbs its mirror), but never
ship a `PodMonitor` — write the `VMPodScrape` yourself.

### Why `redisSecretInit` is disabled

The upstream chart's `redis-secret-init` Job carries `helm.sh/hook: pre-install,pre-upgrade`, which
Argo maps to **PreSync on every sync**. Its delete policy is `before-hook-creation` only, so the
ServiceAccount/Role/RoleBinding persist afterwards — outside the regular manifest set, which means
`prune: true` wants them gone. Prune, recreate as a PreSync hook, prune again: the sync never gets
past PreSync, and `Job/argocd-redis-secret-init` reports `serverside-applied` while never existing
in the cluster.

```yaml
argo-cd:
  redisSecretInit:
    enabled: false
```

The `argocd-redis` Secret still has to exist, so `values-bootstrap.yaml` re-enables the hook for the
first Helm install only:

```yaml
argo-cd:
  redisSecretInit:
    enabled: true
```

Bootstrap layers that overlay *on top of* `values.yaml` (`helm upgrade --install ... -f
values-bootstrap.yaml`), so without the re-enable the Secret would never be created on a fresh
cluster and redis would fail to authenticate.

## Configuration

### Update ArgoCD Version

Edit `Chart.yaml`:
```yaml
dependencies:
  - name: argo-cd
    version: 8.6.0  # Update to desired version
    repository: https://argoproj.github.io/argo-helm
```

Then sync via ArgoCD or upgrade via Helm:
```bash
helm dependency update
argocd app sync argocd
# or
helm upgrade argocd . -n argocd
# or
# install with the repository config directly with private key and repo
helm upgrade --install argocd . -n argocd --create-namespace --set-file argo-cd.configs.repositories.defyjoy-argocd.sshPrivateKey="$HOME/.ssh/github" --set argo-cd.configs.repositories.defyjoy-argocd.url='git@github.com:defyjoy/argocd-google-cloud.git'


```

### Custom Configuration

Edit `values.yaml` for custom settings:

```yaml
argo-cd:
  global:
    domain: argocd.example.com
  
  server:
    ingress:
      enabled: true
      ingressClassName: nginx
      hostname: argocd.example.com
      tls: true
  
  configs:
    params:
      server.insecure: false  # Enable TLS
    
    # argo-helm: `repositories` is a map (not a list). Each entry becomes Secret
    # `argocd-repo-<key>`; every field must be a plain string (chart runs b64enc).
    # Do not use sshPrivateKeySecret here — it is not supported and breaks Helm.
    # Safe default in Git: leave empty and register creds out-of-band (below).
    repositories: {}
    # Optional: Helm-managed repo (never commit sshPrivateKey; use CI --set-file):
    # my-git-repo:
    #   url: git@github.com:yourorg/repo.git
    #   sshPrivateKey: |
    #     -----BEGIN OPENSSH PRIVATE KEY-----
    #     ...
  
  # Redis HA for production
  redis-ha:
    enabled: true
  
  # Controller replicas for HA
  controller:
    replicas: 3
  
  # Server replicas for HA
  server:
    replicas: 3
  
  # Repo server replicas for HA
  repoServer:
    replicas: 3
```

After updating `values.yaml`, commit to Git and ArgoCD will auto-sync.

### Git credentials and Git safety

- **argo-helm `configs.repositories`**: only a **map** of string fields (`url`, `sshPrivateKey`, `username`, `password`, …). The chart template base64-encodes each value; nested objects (for example `sshPrivateKeySecret`) cause `wrong type for value; expected string; got map`.
- **Nothing sensitive belongs in Git**: keep `repositories: {}` in `values.yaml` and supply keys via `kubectl`, ESO, Sealed Secrets, `argocd repo add`, or **`helm upgrade ... --set-file argo-cd.configs.repositories.<repoKey>.sshPrivateKey=/path/to/key`** together with `url` in values.

### Using `configs.repositories` for an SSH Git repo (Helm)

argo-helm turns each **top-level key** under `repositories` into a Secret named `argocd-repo-<that-key>`. Every value under that key must be a **string** (the chart base64-encodes them). For SSH Git, use at least `url` and `sshPrivateKey`.

**1. All in `values.yaml` (local / throwaway only — do not commit the key)**

```yaml
argo-cd:
  configs:
    repositories:
      defyjoy-argocd:
        url: git@github.com:defyjoy/argocd-google-cloud.git
        sshPrivateKey: |
          -----BEGIN OPENSSH PRIVATE KEY-----
          ...
          -----END OPENSSH PRIVATE KEY-----
```

The repo key (`defyjoy-argocd`) is arbitrary; it only affects the Secret name (`argocd-repo-defyjoy-argocd`).

**2. `url` in Git, key from disk at install time (recommended for Helm without committing secrets)**

Put only the URL in `values.yaml` under `argo-cd.configs.repositories.<repoKey>`, then pass the key file when you run Helm (paths are relative to the **parent** chart; your wrapper uses the `argo-cd` subchart key):

```bash
helm upgrade --install argocd . -n argocd --create-namespace \
  --set-file argo-cd.configs.repositories.defyjoy-argocd.sshPrivateKey="$HOME/.ssh/id_rsa" \
  --set argo-cd.configs.repositories.defyjoy-argocd.url='git@github.com:defyjoy/argocd-google-cloud.git'
```

Or keep both entries in a small local override file (still not committed) and use `-f values.local.yaml` where that file contains the `sshPrivateKey` block.

**3. Skip `repositories` in Helm**

Use an out-of-band repository Secret (previous section). Argo CD does not require the repo to be listed in `configs.repositories` if a valid labeled Secret already exists.

### Add Git repository Secret (out-of-band, not in Git)

Argo CD discovers Secrets labeled `argocd.argoproj.io/secret-type: repository`. Example:

```bash
kubectl create secret generic argocd-repo-defyjoy-argocd \
  -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:defyjoy/argocd-google-cloud.git \
  --from-file=sshPrivateKey=$HOME/.ssh/id_rsa
kubectl label secret argocd-repo-defyjoy-argocd -n argocd \
  argocd.argoproj.io/secret-type=repository --overwrite
```

Or apply a manifest with `stringData` and the same label (see [declarative setup](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/)).

```bash
# Optional: known_hosts for ssh
kubectl create secret generic github-known-hosts \
  -n argocd \
  --from-file=ssh_known_hosts=$HOME/.ssh/known_hosts
```

## Access ArgoCD

### Via Ingress (Recommended for Production)

Configure ingress in `values.yaml`:
```yaml
argo-cd:
  server:
    ingress:
      enabled: true
      ingressClassName: nginx
      hostname: argocd.example.com
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-prod
      tls: true
```

Access at: `https://argocd.example.com`

### Via Port Forward (Development)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Access at: `https://localhost:8080`

### Via NodePort

```yaml
argo-cd:
  server:
    service:
      type: NodePort
      nodePortHttp: 30080
      nodePortHttps: 30443
```

Access at: `https://<node-ip>:30443`

### Via LoadBalancer

```yaml
argo-cd:
  server:
    service:
      type: LoadBalancer
```

Get external IP:
```bash
kubectl get svc argocd-server -n argocd
```

## Common Workflows

### Deploy the App-of-Apps Pattern

Deploy `argocd-apps` to manage all other applications:

```bash
argocd app create argocd-apps \
  --repo git@github.com:defyjoy/argocd-google-cloud.git \
  --path helmcharts/argocd-apps \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace argocd \
  --sync-policy automated \
  --self-heal
```

Or use the Application manifest in the argocd-apps chart.

### Add a New Cluster

```bash
# List available contexts
kubectl config get-contexts

# Add cluster to ArgoCD
argocd cluster add <context-name>

# Verify
argocd cluster list
```

### Create a New Application

```bash
argocd app create <app-name> \
  --repo <git-repo-url> \
  --path <path-to-chart> \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace <namespace> \
  --sync-policy automated
```

### Sync an Application

```bash
# Manual sync
argocd app sync <app-name>

# Sync with prune
argocd app sync <app-name> --prune

# Hard refresh (force)
argocd app sync <app-name> --force
```

### Rollback an Application

```bash
# View history
argocd app history <app-name>

# Rollback to specific revision
argocd app rollback <app-name> <revision-id>
```

### Delete an Application

```bash
# Delete without cascade (keeps resources)
argocd app delete <app-name> --cascade=false

# Delete with cascade (removes resources)
argocd app delete <app-name> --cascade=true
```

## Troubleshooting

### ArgoCD UI Not Accessible

```bash
# Check server pod status
kubectl get pods -n argocd -l app.kubernetes.io/component=server

# Check server logs
kubectl logs -n argocd -l app.kubernetes.io/component=server

# Check ingress
kubectl get ingress -n argocd
kubectl describe ingress argocd-server -n argocd
```

### Applications Not Syncing

```bash
# Check application status
argocd app get <app-name>

# View sync status
kubectl describe application <app-name> -n argocd

# Check application controller logs
kubectl logs -n argocd -l app.kubernetes.io/component=application-controller
```

### Repository Connection Issues

```bash
# Test repository connection
argocd repo list

# Add repository
argocd repo add <repo-url> --ssh-private-key-path ~/.ssh/id_rsa

# Check repo server logs
kubectl logs -n argocd -l app.kubernetes.io/component=repo-server
```

### Reset Admin Password

```bash
# Method 1: Via kubectl
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"admin.password": "'$(htpasswd -bnBC 10 "" <new-password> | tr -d ':\n' | sed 's/$2y/$2a/')'"}}'

# Method 2: Delete and recreate
kubectl -n argocd delete secret argocd-initial-admin-secret
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Self-Managed ArgoCD Issues

If ArgoCD cannot sync itself:

```bash
# Check application status
kubectl get application argocd -n argocd -o yaml

# Manually update via Helm
helm upgrade argocd . -n argocd

# Force refresh
argocd app get argocd --refresh
argocd app sync argocd --force
```

### CRD Update Issues

```bash
# Update CRDs manually if needed
kubectl apply -k "https://github.com/argoproj/argo-cd/manifests/crds?ref=v2.9.0"

# Or from local chart
kubectl apply -f charts/argo-cd/crds/
```

## Production Recommendations

### 1. High Availability

```yaml
argo-cd:
  controller:
    replicas: 3
  
  server:
    replicas: 3
    autoscaling:
      enabled: true
      minReplicas: 3
      maxReplicas: 5
  
  repoServer:
    replicas: 3
    autoscaling:
      enabled: true
      minReplicas: 3
      maxReplicas: 5
  
  redis-ha:
    enabled: true
    haproxy:
      enabled: true
```

### 2. Resource Limits

**The controller and repo-server carry no CPU limit. This is deliberate — do not add one back.**

```yaml
argo-cd:
  controller:
    resources:
      requests:
        cpu: 1000m
        memory: 2048Mi
      limits:
        memory: 4096Mi

  repoServer:
    replicas: 3
    resources:
      requests:
        cpu: 500m
        memory: 256Mi
      limits:
        memory: 1024Mi
```

This is the one place in the repo that breaks the "limits are 2× requests" convention, because on
2026-08-06 that convention made Argo CD nearly unusable.

The controller was capped at `limits.cpu: 200m` against a `100m` request. Measured on
`argocd-application-controller-0` mid-bootstrap, it was throttled in **129 of 129** CFS periods over
a 13-second window — 3293/3300 cumulative, **99.8%** — while consuming 66 CPU-seconds in ~300s of
wall time, i.e. pinned flat against the 0.2-core ceiling with a full run queue behind it. Syncs took
minutes to converge and the self-heal retry queue never drained.

Nothing on the cluster was actually short of CPU: all six nodes report `3950m` allocatable and were
largely idle. The cap was pure self-harm.

A CPU limit is the wrong tool here because the controller's load is **spiky, not steady**. It is
near-idle while everything is Synced, then needs multiple cores in short bursts to diff and normalize
large resources — `istio-base` alone ships 15 CRDs with very large OpenAPI schemas, and schema
normalization is the hottest path in the controller. A limit sized for the idle case throttles the
burst; a limit sized for the burst reserves cores that sit unused. The `requests` value is what
actually matters, since it is what the scheduler reserves and what protects the pod under contention.
Leaving CPU unlimited lets the burst finish in seconds using idle capacity, and the request keeps it
protected when the node is busy.

**Memory limits are kept.** CPU is compressible — exceeding it throttles — but memory is not, and an
unbounded controller leak would trigger node-level pressure and evict unrelated pods. The controller's
memory was raised from `1024Mi`/`2048Mi` to `2048Mi`/`4096Mi` in the same change: it was measured at a
**992 MiB working set against a 1024 MiB request**, i.e. sitting on 97% of its request, which risks
eviction under node memory pressure.

If sync latency regresses again, check throttling before assuming the controller is undersized:

```bash
kubectl get --raw "/api/v1/nodes/<node>/proxy/metrics/cadvisor" \
  | grep -E "container_cpu_cfs_(throttled_)?periods_total" \
  | grep application-controller
```

Two samples a few seconds apart; if `throttled_periods` climbs at the same rate as `periods`,
something has reintroduced a CPU limit.

### 3. Security

```yaml
argo-cd:
  configs:
    params:
      server.insecure: false
    
    # RBAC configuration
    rbac:
      policy.default: role:readonly
      policy.csv: |
        p, role:org-admin, applications, *, */*, allow
        p, role:org-admin, clusters, get, *, allow
        p, role:org-admin, repositories, *, *, allow
        g, your-org:devops, role:org-admin
    
    # SSO configuration
    cm:
      url: https://argocd.example.com
      dex.config: |
        connectors:
          - type: github
            id: github
            name: GitHub
            config:
              clientID: $github-oauth-client-id
              clientSecret: $github-oauth-client-secret
              orgs:
              - name: your-org
```

### 4. Monitoring

```yaml
argo-cd:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
  
  notifications:
    enabled: true
    notifiers:
      service.slack: |
        token: $slack-token
    subscriptions:
      - recipients:
          - slack:argocd-notifications
        triggers:
          - on-deployed
          - on-health-degraded
          - on-sync-failed
```

### 5. Backup

```bash
# Backup all ArgoCD applications
kubectl get applications -n argocd -o yaml > argocd-apps-backup.yaml

# Backup ArgoCD configuration
kubectl get configmap argocd-cm -n argocd -o yaml > argocd-cm-backup.yaml
kubectl get secret argocd-secret -n argocd -o yaml > argocd-secret-backup.yaml

# Backup to Git (recommended)
# Commit values.yaml and all Application manifests to Git
```

## References

- [ArgoCD Official Documentation](https://argo-cd.readthedocs.io/)
- [ArgoCD Helm Chart](https://github.com/argoproj/argo-helm/tree/main/charts/argo-cd)
- [GitOps Best Practices](https://www.gitops.tech/)
- [App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [ArgoCD ApplicationSet](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)

## Quick Reference

```bash
# Check ArgoCD status
kubectl get pods -n argocd
argocd app list

# Sync all apps
argocd app sync --all

# Get app details
argocd app get <app-name>

# View app diff
argocd app diff <app-name>

# Set app parameter
argocd app set <app-name> --parameter key=value

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# Port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

## Bootstrap to Self-Managed Flow

```
┌─────────────────────────────────────────────────────────┐
│  Step 1: Initial Bootstrap (Manual)                    │
│  helm install argocd . -n argocd --create-namespace     │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  Step 2: Create Self-Management Application            │
│  kubectl apply -f argocd-application.yaml               │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  Step 3: ArgoCD Manages Itself from Git                │
│  All changes via Git → Auto-sync to cluster             │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│  Step 4: Deploy App-of-Apps                             │
│  Manage all applications via ApplicationSets            │
└─────────────────────────────────────────────────────────┘
```

## License

This Helm chart is based on the official ArgoCD Helm chart and follows the same Apache 2.0 license.

---

## Bootstrap overlay — `values-bootstrap.yaml`

Passed as an **extra `-f`** on the very first `helm install argocd` on a fresh cluster
(`taskfiles/argocd.yaml` → `install-argocd-chart`, `ARGOCD_BOOTSTRAP=true`).

On a brand-new cluster only Cilium and Argo CD exist, and three of this chart's resources
cannot be created by a plain `helm install` — either their CRDs are missing, or the object
already exists and Helm refuses to adopt it:

| Resource | Why it fails |
|---|---|
| `devCluster` ExternalSecret | needs `external-secrets.io` CRDs |
| `argocd-server` HTTPRoute | needs `gateway.networking.k8s.io` CRDs |
| `kube-system/coredns` ConfigMap | already created by Talos — Helm will not adopt a resource lacking its ownership metadata |

The ConfigMap failure looks like:

```
invalid ownership metadata; missing key app.kubernetes.io/managed-by
```

> 📌 The ServiceMonitors don't fail, because the upstream argo-cd chart guards them behind a
> `.Capabilities` check. These three resources are not guarded, so they are disabled here
> instead.

**This overlay is used only for the initial bootstrap install — it is not what Argo CD
renders.** The self-managed `argocd` Application always syncs the plain `values.yaml` (all
enabled) from git. Once the app-of-apps ApplicationSets install external-secrets-operator and
the Gateway API CRDs, Argo CD self-heals the ExternalSecret and HTTPRoute; and **unlike Helm,
Argo CD natively adopts** the pre-existing `kube-system/coredns` ConfigMap, applying over it and
stamping its tracking annotation. All three land automatically with nothing to undo by hand.
