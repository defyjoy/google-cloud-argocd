# Runbook: Register the `dev` Cluster with Management Argo CD

Command-oriented procedure to stand up the `dev` cluster and register it as a managed
target of the Argo CD instance running in `management`.

- **`task bootstrap` is for `management` only.** `dev` is **not** bootstrapped that way — it
  never runs its own Argo CD. It is registered as a *remote* cluster that `management`'s Argo CD
  deploys into. Follow this runbook instead.
- **Trust model / rationale:** [`alarmify-docs` ADR-005 — Argo CD Cross-Cluster Trust Model](https://github.com/Alarmify/alarmify-docs/blob/main/docs/istio/ambient/adrs/adr-005-argocd-cross-cluster-trust-model.md).
  The credential is an ordinary ServiceAccount bearer token, valid **only** against `dev` — no
  mesh, no shared root of trust, one-directional (`management` → `dev`).

| Fact | Value |
|---|---|
| dev API server | `https://192.168.4.10:6443` |
| dev kubeconfig | `~/.kube/talos-dev.yaml` |
| Vault path | `kv/argocd/dev-cluster` (KV v2, `kv` mount) — fields `bearerToken`, `caData`, `server` |
| Terraform (infra) | `defyjoy/proxmox-talos`, `terraform/envs/dev` |
| Bootstrap RBAC | `helmcharts/argocd/bootstrap/dev-cluster-serviceaccount.yaml` |
| Cluster ExternalSecret | `helmcharts/argocd/templates/cluster/dev-cluster-secret.yaml` |

---

## Prerequisites

- `kubectl`, `helm`, `task`, `yq` (`mikefarah/yq`), `vault` CLI.
- Access to the `defyjoy/proxmox-talos` repo (local path `../proxmox-talos`).
- A Vault root/operator token (**Step 5 is run by a human** — see ADR-005 Consequences).

---

## 1. Provision the `dev` cluster (Terraform)

Run from the **`proxmox-talos`** repo. `ACTION` defaults to `plan`; set `apply` to build it.

```bash
cd ../proxmox-talos

ACTION=apply task dev            # terraform apply — terraform/envs/dev
task kubeconfig-dev              # writes ~/.kube/talos-dev.yaml
```

## 2. Install Cilium CNI on `dev` (first workload)

Talos ships `cni:none`/`proxy.disabled`, so `dev`'s nodes stay `NotReady` until Cilium is
installed. Run from **this** repo against `dev`, using the **dev** LB pool (`values/dev.yaml`).
The Cilium subchart is vendored in `charts/`, so no `helm dependency update` is needed.

```bash
export KUBECONFIG=~/.kube/talos-dev.yaml
cd helmcharts/cilium

helm upgrade --install cilium . \
  --namespace kube-system \
  --create-namespace \
  --values values.yaml \
  --values values/dev.yaml \
  --wait \
  --timeout 15m
```

Verify the datapath before continuing:

```bash
kubectl --kubeconfig ~/.kube/talos-dev.yaml get nodes           # all Ready
kubectl --kubeconfig ~/.kube/talos-dev.yaml get pods -n kube-system -l k8s-app=cilium
cilium status --wait                                            # optional: cilium CLI
```

## 3. Apply the bootstrap RBAC to `dev`

Chicken-and-egg exception: applied **manually, once, directly on `dev`** — Argo CD needs the
`argocd-manager` ServiceAccount to exist before it can reach `dev`. Not synced by Argo CD.

```bash
kubectl apply -f helmcharts/argocd/bootstrap/dev-cluster-serviceaccount.yaml \
  --kubeconfig ~/.kube/talos-dev.yaml
```

Creates `ServiceAccount/argocd-manager` (ns `kube-system`), `ClusterRole/argocd-manager-role`,
`ClusterRoleBinding/argocd-manager-role-binding` — all inside `dev` only.

## 4. Mint the bearer token and extract the CA data

```bash
BEARER_TOKEN=$(kubectl create token argocd-manager -n kube-system \
  --kubeconfig ~/.kube/talos-dev.yaml --duration=87600h)

CA_DATA=$(yq '.clusters[0].cluster.certificate-authority-data' ~/.kube/talos-dev.yaml)
```

`--duration=87600h` = 10 years (deliberate simplicity trade-off for a non-critical cluster;
Kubernetes 1.24+ no longer auto-creates long-lived SA token Secrets). `CA_DATA` is `dev`'s own
CA cert — public, stored alongside the token only so one ExternalSecret can fetch both.

## 5. Write both values to Vault  ⚠️ human step

Run by a human with a Vault root/operator token — kept out of any automation/agent.

```bash
export VAULT_ADDR="https://vault.workquark.org"
vault login <root-or-operator-token>

vault kv put kv/argocd/dev-cluster \
  bearerToken="$BEARER_TOKEN" \
  caData="$CA_DATA" \
  server="https://192.168.4.10:6443"
```

Mount is `kv` (not `secret`) — matches `helmcharts/external-secrets/values.yaml`
(`vaultClusterSecretStore.vault.path: "kv"`). Never paste the token/CA by hand — use the
`$BEARER_TOKEN`/`$CA_DATA` variables from Step 4.

## 6. Ensure the chart wiring is committed, then let Argo CD self-heal

The declarative half (already in git for `dev`; needed once per new cluster):

- `helmcharts/argocd/values.yaml` → `devCluster` block (`enabled`, `server`, `name`, `vaultPath`)
- `helmcharts/argocd/templates/cluster/dev-cluster-secret.yaml` (the `ExternalSecret`)
- `helmcharts/argocd/bootstrap/dev-cluster-serviceaccount.yaml` (tracked for reproducibility)

If you changed any of them:

```bash
git add helmcharts/argocd/values.yaml \
        helmcharts/argocd/templates/cluster/dev-cluster-secret.yaml \
        helmcharts/argocd/bootstrap/dev-cluster-serviceaccount.yaml
git commit -m "feat(argocd): register dev cluster via Vault-backed ExternalSecret"
git push origin main
```

Argo CD's self-managed `argocd` Application (`selfHeal: true`) picks it up on the next
reconcile. Force it sooner:

```bash
kubectl patch application argocd -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## 7. Verify

```bash
kubectl get externalsecret dev-cluster -n argocd -o jsonpath='{.status.conditions}'; echo
kubectl get secret dev-cluster -n argocd -o jsonpath='{.metadata.labels}'; echo
kubectl get secret dev-cluster -n argocd \
  -o jsonpath='{.metadata.labels.cluster-name}'; echo   # expect: dev
```

Expect `status.conditions[].reason: SecretSynced` and a `Secret/dev-cluster` labeled
`argocd.argoproj.io/secret-type: cluster`, `cluster-name: dev`. Live connectivity is exercised
once the first `Application` targets `dev`.

---

## Rebuild note (if `dev` is destroyed)

Steps 3–5 are the non-GitOps, manual half. If `dev` is ever rebuilt (`terraform destroy && apply`),
its ServiceAccount signing key is regenerated, so the old token is dead. **Re-run Steps 1–5**
(reapply RBAC, mint a fresh token, rewrite Vault); the `ExternalSecret` refreshes and Argo CD
reconnects. See ADR-005 Consequences.
