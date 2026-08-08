# ArgoCD Bootstrap

This directory holds **bootstrap documentation** and the default working directory for **Vault init state** (`hashicorp-vault-init.json`, gitignored). The **Task** runner lives at the **repository root**: `Taskfile.yml` and `scripts/`.

## Quick Start

### Option 1: Automated Bootstrap with Task (Recommended)

Install Task runner if you haven't already:
```bash
# macOS
brew install go-task

# Linux
sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b ~/.local/bin

# Or download from: https://github.com/go-task/task/releases
```

Run the bootstrap task **from the repository root**:

```bash
cd /path/to/ArgoCD   # repository root
task bootstrap
```

This will:
1. ✅ Check prerequisites (kubectl, helm, cluster access)
2. ✅ Install ArgoCD via Helm
3. ✅ Wait for ArgoCD to be ready
4. ✅ Display admin credentials
5. ✅ Configure ArgoCD self-management
6. ✅ Configure App-of-Apps pattern

**Available Tasks:**
```bash
task --list              # List all available tasks
task bootstrap           # Complete bootstrap (recommended)
task install-only        # Install without self-management
task status              # Check ArgoCD status
task port-forward        # Access UI via port forward
task upgrade             # Upgrade ArgoCD
task uninstall           # Remove ArgoCD
```

### Option 2: Manual Bootstrap

#### Step 1: Install ArgoCD

```bash
cd helmcharts/argocd
helm dependency update
helm install argocd . -n argocd --create-namespace
```

#### Step 2: Get Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

#### Step 3: Access ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open: https://localhost:8080

#### Step 4: Configure Self-Management

```bash
kubectl apply -f ../argocd-apps/templates/applications/argocd.yaml
```

#### Step 5: Configure App-of-Apps

```bash
kubectl apply -f ../argocd-apps/templates/applications/argocd-apps.yaml
```

## Repository layout

### `Taskfile.yml` and `scripts/` (repository root)

Task runner configuration and shell scripts for ArgoCD bootstrap and cluster helpers. Run all `task` commands from the repo root.

**Key Tasks:**
```bash
# Full bootstrap
task bootstrap

# Install only (no self-management)
task install-only

# Individual tasks
task install              # Install ArgoCD via Helm
task self-manage          # Configure self-management
task app-of-apps          # Configure app-of-apps pattern
task status               # Check ArgoCD status
task port-forward         # Access ArgoCD UI
task upgrade              # Upgrade ArgoCD
task restart              # Restart ArgoCD components
task uninstall            # Remove ArgoCD

# List all available tasks
task --list
```

**Why Taskfile?**
- ✓ Better documentation (each task has desc and summary)
- ✓ Cross-platform (works on macOS, Linux, Windows)
- ✓ Easier to maintain than shell scripts
- ✓ Built-in dependency management
- ✓ Clear task descriptions with `task --list`

### Application Manifests

The bootstrap Applications are now located in the `argocd-apps` chart for better organization:

**`../argocd-apps/templates/applications/argocd.yaml`**
- ArgoCD self-management Application
- Configures ArgoCD to manage itself from Git
- Points to `helmcharts/argocd` in your Git repo
- Enables automated sync with self-healing

**Apply manually:**
```bash
kubectl apply -f ../argocd-apps/templates/applications/argocd.yaml
```

**`../argocd-apps/templates/applications/argocd-apps.yaml`**
- App-of-Apps pattern Application
- Points to `helmcharts/argocd-apps` in your Git repo
- Manages all ApplicationSets from Git
- Enables automated deployment of new ApplicationSets

**Apply manually:**
```bash
kubectl apply -f ../argocd-apps/templates/applications/argocd-apps.yaml
```

## Bootstrap Flow

```
┌──────────────────────────────────────────────────────────┐
│  1. Initial Bootstrap (Manual/Script)                   │
│  helm install argocd . -n argocd                         │
└──────────────────────────────────────────────────────────┘
                           ↓
┌──────────────────────────────────────────────────────────┐
│  2. ArgoCD Self-Management                               │
│  kubectl apply -f argocd-apps/templates/applications/    │
│                   argocd.yaml                            │
│  → ArgoCD manages itself from Git                        │
└──────────────────────────────────────────────────────────┘
                           ↓
┌──────────────────────────────────────────────────────────┐
│  3. App-of-Apps Pattern                                  │
│  kubectl apply -f argocd-apps/templates/applications/    │
│                   argocd-apps.yaml                       │
│  → ArgoCD manages ApplicationSets from Git               │
└──────────────────────────────────────────────────────────┘
                           ↓
┌──────────────────────────────────────────────────────────┐
│  4. ApplicationSets Deploy Applications                  │
│  → Label clusters to enable apps                         │
│  → Apps auto-deploy based on labels                      │
└──────────────────────────────────────────────────────────┘
```

## Verification

### Check ArgoCD Installation

```bash
# Using Task
task status

# Or manually
kubectl get pods -n argocd
kubectl get applications -n argocd

# Expected applications:
# - argocd (self-management)
# - argocd-apps (app-of-apps)
```

### Check Self-Management

```bash
# View ArgoCD application
kubectl get application argocd -n argocd -o yaml

# Check sync status
kubectl get application argocd -n argocd \
  -o jsonpath='{.status.sync.status}' && echo
# Should show: Synced
```

### Check App-of-Apps

```bash
# View argocd-apps application
kubectl get application argocd-apps -n argocd -o yaml

# Check ApplicationSets
kubectl get applicationsets -n argocd
```

## Troubleshooting

### ArgoCD Not Starting

```bash
# Check pod status
kubectl get pods -n argocd

# Check pod logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server

# Describe problematic pods
kubectl describe pod -n argocd <pod-name>
```

### Self-Management Not Working

```bash
# Check application status
kubectl describe application argocd -n argocd

# Check for sync errors
kubectl get application argocd -n argocd \
  -o jsonpath='{.status.conditions}' | jq

# Force refresh
kubectl patch application argocd -n argocd \
  --type merge -p '{"operation":{"initiatedBy":{"automated":true}}}'
```

### Cannot Access UI

```bash
# Verify service
kubectl get svc argocd-server -n argocd

# Check ingress (if configured)
kubectl get ingress -n argocd

# Port forward
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

### Repository Connection Issues

```bash
# Check if repository is accessible
kubectl get secret -n argocd

# Add SSH key if needed
kubectl create secret generic github-ssh-key \
  -n argocd \
  --from-file=sshPrivateKey=$HOME/.ssh/id_rsa
```

## Customization

### Update Repository URL

Edit the Application manifests in `argocd-apps/templates/applications/` to use your repository:

```yaml
# In argocd.yaml and argocd-apps.yaml
source:
  repoURL: git@github.com:YOUR-ORG/YOUR-REPO.git  # Update this
```

### Use Different Branch

```yaml
source:
  targetRevision: main  # or develop, staging, etc.
```

### Add Custom Values

```yaml
source:
  helm:
    values: |
      argo-cd:
        global:
          domain: argocd.example.com
```

## Next Steps After Bootstrap

### 1. Change Admin Password

```bash
# Via CLI
argocd login localhost:8080 --username admin --insecure
argocd account update-password

# Via kubectl
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"admin.password": "'$(htpasswd -bnBC 10 "" <password> | tr -d ':\n' | sed 's/$2y/$2a/')'"}}'
```

### 2. Configure SSO (Optional)

Edit `values.yaml`:
```yaml
argo-cd:
  configs:
    cm:
      dex.config: |
        connectors:
          - type: github
            id: github
            name: GitHub
            config:
              clientID: $github-oauth-client-id
              clientSecret: $github-oauth-client-secret
```

### 3. Add Git Repositories

```bash
argocd repo add git@github.com:yourorg/repo.git \
  --ssh-private-key-path ~/.ssh/id_rsa
```

### 4. Add Clusters

```bash
# List contexts
kubectl config get-contexts

# Add cluster
argocd cluster add <context-name>
```

### 5. Label Clusters for ApplicationSets

```bash
# Enable Cilium (CNI + kube-proxy replacement + LoadBalancer) on cluster
kubectl label secret -n argocd cluster-<name> cilium=true

# Enable other apps
kubectl label secret -n argocd cluster-<name> ingress-nginx=true
```

### 6. Deploy Applications

ApplicationSets will automatically create Applications for labeled clusters.

```bash
# View ApplicationSets
kubectl get applicationsets -n argocd

# View generated Applications
kubectl get applications -n argocd
```

## Clean Up (Development Only)

⚠️ **Warning**: This will delete ArgoCD and all managed applications!

```bash
# Using Task (recommended)
task uninstall

# Or manually
kubectl delete application --all -n argocd
helm uninstall argocd -n argocd
kubectl delete namespace argocd
```

## Task Runner Reference

### Installation

```bash
# macOS
brew install go-task

# Linux (bash)
sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b ~/.local/bin

# Windows (PowerShell as Administrator)
choco install go-task

# Or download binary from:
# https://github.com/go-task/task/releases
```

### Usage

Run these from the **repository root** (where `Taskfile.yml` lives).

```bash
# List all available tasks with descriptions
task --list

# Run a specific task
task <task-name>

# Get detailed help for a task
task <task-name> --summary

# Run with verbose output
task <task-name> --verbose

# Dry run (show what would be executed)
task <task-name> --dry
```

### Common Workflows

```bash
# (from repository root)

# Complete bootstrap
task bootstrap

# Check status
task status

# Access UI
task port-forward

# Upgrade ArgoCD
task upgrade

# View logs
task logs

# Restart components
task restart

# Uninstall (with confirmation)
task uninstall
```

### Task Features Used

- **`desc`**: Short description shown in `task --list`
- **`summary`**: Detailed help shown in `task <name> --summary`
- **`deps`**: Task dependencies (run before main task)
- **`preconditions`**: Check conditions before running
- **`prompt`**: Ask for confirmation before destructive operations
- **`silent`**: Suppress command echo for cleaner output
- **`dir`**: Change directory for task execution

## References

- [Main ArgoCD README](../README.md)
- [Task Documentation](https://taskfile.dev/)
- [ArgoCD Official Docs](https://argo-cd.readthedocs.io/)
- [App of Apps Pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [ArgoCD Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)

