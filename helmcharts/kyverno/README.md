# Kyverno Helm Chart

This chart deploys [Kyverno](https://kyverno.io) v1.18.1 (chart 3.8.1), a Kubernetes-native policy
engine used to validate, mutate, generate, and clean up resources via admission control and
background scans — no new language to learn, policies are plain Kubernetes resources.

It is a thin wrapper around the upstream `kyverno/kyverno` chart: `values.yaml` only overrides
settings that diverge from upstream defaults (replica counts, resources, PodDisruptionBudget,
ServiceMonitor). Anything not listed falls back to the subchart's own defaults — run
`helm show values kyverno/kyverno --version 3.8.1` to see the full schema.

## Components

Kyverno ships four independently-scaled controllers, all enabled by default:

| Controller | Purpose | Replicas | On the request path? |
|---|---|---|---|
| `admissionController` | Validating/mutating webhook server | 2 (+ PDB) | Yes — every cluster write |
| `backgroundController` | Background scans, generate/mutate-existing | 1 | No |
| `cleanupController` | Runs scheduled `CleanupPolicy` jobs | 1 | No |
| `reportsController` | Aggregates `PolicyReport`/`ClusterPolicyReport` | 1 | No |

The admission controller runs 2 replicas with a PodDisruptionBudget because it sits in the
admission path for every API write in the cluster — losing all replicas during a node drain
would (depending on `failurePolicy`) either block or silently skip policy enforcement.

## Prerequisites

- Kubernetes cluster (1.24+)
- Helm 3.x
- ArgoCD (for GitOps deployment)
- Cluster labeled `kyverno: "true"` (see ApplicationSet selector below)

## Installation

### Via ArgoCD ApplicationSet (Recommended)

This chart is deployed via ArgoCD using the ApplicationSet pattern. The applicationset is located at:

```
helmcharts/argocd-apps/templates/applicationsets/kyverno.yaml
```

It targets any cluster labeled `kyverno: "true"` and deploys into the `kyverno` namespace
(created automatically, with `restricted` Pod Security Standard labels).

### Manual Installation

```bash
helm repo add kyverno https://kyverno.github.io/kyverno
helm repo update

helm dependency update helmcharts/kyverno
helm upgrade --install kyverno helmcharts/kyverno \
  --namespace kyverno --create-namespace
```

## Configuration

### Key Configuration Options

| Parameter | Description | Default |
|-----------|-------------|---------|
| `enabled` | Render the kyverno subchart | `true` |
| `kyverno.crds.install` | Install Kyverno CRDs via Helm | `true` |
| `kyverno.admissionController.replicas` | Admission webhook replica count | `2` |
| `kyverno.admissionController.podDisruptionBudget.enabled` | PDB for the admission controller | `true` |
| `kyverno.*.serviceMonitor.enabled` | Prometheus Operator `ServiceMonitor` per controller | `true` |
| `kyverno.features.policyExceptions.enabled` | Allow `PolicyException` resources | `false` |

To change any other upstream setting, add it under the `kyverno:` key in `values.yaml` using the
same path as the upstream chart's own `values.yaml`.

### Monitoring

Each controller exposes Prometheus metrics on port `8000` and a matching `ServiceMonitor` is
created (requires the Prometheus Operator CRDs — see `helmcharts/kube-prometheus-stack`). If your
Prometheus install uses `serviceMonitorSelector` with custom label matching instead of
`serviceMonitorSelectorNilUsesHelmValues: true`, add the required labels under
`kyverno.<controller>.serviceMonitor.additionalLabels`.

### Policies

This chart only installs the Kyverno engine, not policies. Add `ClusterPolicy` /
`ValidatingPolicy` / `MutatingPolicy` resources separately (e.g. from the
[kyverno-policies](https://github.com/kyverno/policies) library or your own GitOps source).

Example baseline policy (audit-only, safe to start with):

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged-containers
spec:
  validationFailureAction: Audit
  background: true
  rules:
    - name: privileged-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Privileged containers are not allowed."
        pattern:
          spec:
            =(ephemeralContainers):
              - =(securityContext):
                  =(privileged): "false"
            =(initContainers):
              - =(securityContext):
                  =(privileged): "false"
            containers:
              - =(securityContext):
                  =(privileged): "false"
```

## Troubleshooting

```bash
# Check controller pods
kubectl get pods -n kyverno

# Check webhook registration
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -l webhook.kyverno.io/managed-by=kyverno

# Check policy reports
kubectl get policyreports,clusterpolicyreports -A

# Controller logs
kubectl logs -n kyverno -l app.kubernetes.io/component=admission-controller
kubectl logs -n kyverno -l app.kubernetes.io/component=background-controller
kubectl logs -n kyverno -l app.kubernetes.io/component=cleanup-controller
kubectl logs -n kyverno -l app.kubernetes.io/component=reports-controller
```

### Common Issues

1. **Deploys hang / API writes blocked cluster-wide**: a misconfigured policy with
   `failurePolicy: Fail` can block unrelated admission requests if the admission controller is
   unavailable. Start new policies with `validationFailureAction: Audit` before enforcing.
2. **Webhook TLS errors after upgrade**: Kyverno manages its own webhook certificates by default
   (`createSelfSignedCert: false` uses Kyverno's built-in cert rotation, not ad-hoc self-signing).
   Restart the admission controller pods if certs appear stale.
3. **CRDs not installed**: ensure `kyverno.crds.install: true` (this chart's default) — ArgoCD's
   `ServerSideApply=true` sync option (already set in the ApplicationSet) is required for the CRDs
   to apply cleanly given their size.

## Upgrading

### Via ArgoCD

Bump `dependencies[0].version` and `appVersion` in `Chart.yaml`, run
`helm dependency update helmcharts/kyverno` to refresh `Chart.lock`, then commit both. ArgoCD
will sync the change.

### Manual Upgrade

```bash
helm dependency update helmcharts/kyverno
helm upgrade kyverno helmcharts/kyverno --namespace kyverno
```

## Uninstalling

Removing the ApplicationSet (or unlabeling the cluster) deletes the release. Note: Kyverno CRDs
are **not** removed automatically when Helm-installed CRDs are pruned by default policy — existing
`ClusterPolicy`/`PolicyException` resources should be deleted first to avoid orphaned admission
webhooks blocking API requests during teardown.

```bash
helm uninstall kyverno -n kyverno
kubectl delete namespace kyverno
```

## Additional Resources

- [Kyverno Documentation](https://kyverno.io/docs/)
- [Kyverno Policy Library](https://kyverno.io/policies/)
- [Kyverno GitHub](https://github.com/kyverno/kyverno)
- [Kyverno Helm Chart Values Reference](https://github.com/kyverno/kyverno/blob/main/charts/kyverno/README.md)

---

## This deployment's configuration

```yaml
enabled: true          # renders the upstream kyverno/kyverno subchart at all

kyverno:
  # values passed straight through; schema:
  #   helm show values kyverno/kyverno --version 3.8.1
```

**Only settings that diverge from upstream defaults are listed explicitly** — everything else
falls back to the subchart's own defaults. CRD installation is part of this release and is
required.

### Admission controller runs HA

The admission controller is the core webhook server that validates and mutates incoming API
requests. It runs with **2 replicas plus a PodDisruptionBudget**, because it sits on the
admission path for **every cluster write** — a single-replica outage would block writes
cluster-wide.
