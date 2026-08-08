#!/usr/bin/env bash
set -euo pipefail

# Tear down everything `task app-of-apps` brought up: the root argocd-apps Application, every
# ApplicationSet it renders, every Application those generate, and the workloads behind them.
#
# Argo CD itself is deliberately left running — it is the controller that performs the deletion.
# Remove it afterwards with `task uninstall`.

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:?}"
DRY_RUN="${DRY_RUN:-false}"
DELETE_TIMEOUT="${DELETE_TIMEOUT:-900}"
FORCE_FINALIZERS="${FORCE_FINALIZERS:-false}"
DELETE_NAMESPACES="${DELETE_NAMESPACES:-false}"
KEEP_APPS_EXTRA="${KEEP_APPS_EXTRA:-}"

# Applications that must survive the teardown. `argocd` is the self-management Application: deleting
# it removes the controller mid-cascade, and every remaining Application then hangs on its finalizer
# with nothing left to finalize it. `argocd-apps` is the root, handled separately in step 1.
# KEEP_APPS_EXTRA adds to this — typically `local-cilium` to keep the CNI out of scope.
KEEP_APPS=("argocd" "argocd-apps")
if [[ -n "$KEEP_APPS_EXTRA" ]]; then
  # Guarded rather than unconditional: bash 3.2 (macOS /bin/bash) treats an empty array as unset
  # under `set -u`, so expanding one would abort the script.
  read -r -a keep_extra <<<"$KEEP_APPS_EXTRA"
  KEEP_APPS+=("${keep_extra[@]}")
fi
# Namespaces never considered for the optional DELETE_NAMESPACES sweep.
PROTECTED_NAMESPACES=("argocd" "default" "kube-node-lease" "kube-public" "kube-system")

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "   [dry-run] $*"
    return 0
  fi
  "$@"
}

in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# Applications in the argocd namespace, minus KEEP_APPS.
target_apps() {
  local app
  for app in $(kubectl get applications -n "$ARGOCD_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    in_list "$app" "${KEEP_APPS[@]}" || echo "$app"
  done
}

echo "🔍 Target cluster: $(kubectl config current-context)"
kubectl get namespace "$ARGOCD_NAMESPACE" >/dev/null
[[ "$DRY_RUN" == "true" ]] && echo "🧪 DRY_RUN=true — no changes will be made"

echo ""
echo "📊 Current state:"
echo "   ApplicationSets: $(kubectl get applicationsets -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "   Applications:    $(kubectl get applications -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "   Preserved:       ${KEEP_APPS[*]}"

# Cilium is the CNI and the LoadBalancer implementation, and an ordinary app-of-apps Application --
# a full teardown takes the cluster's datapath with it. Say so before anything is deleted.
for critical in cilium; do
  for app in $(kubectl get applications -n "$ARGOCD_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    if [[ "$app" == *"$critical" ]] && ! in_list "$app" "${KEEP_APPS[@]}"; then
      echo "   ⚠️  $app is IN SCOPE — deleting it destroys the cluster's network datapath."
      echo "       Exclude it with: KEEP_APPS_EXTRA=\"$app\""
    fi
  done
done

# 1. Drop the root Application first, WITHOUT its resources-finalizer. It manages the `argocd`
#    self-management Application too, so a cascading delete here would take Argo CD down before it
#    could prune anything else. Removing it first also stops selfHeal from recreating the
#    ApplicationSets deleted in step 3.
echo ""
echo "🗑️  Step 1/5: releasing root Application argocd-apps (orphan, keeps Argo CD alive)..."
if kubectl get application argocd-apps -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  run kubectl patch application argocd-apps -n "$ARGOCD_NAMESPACE" \
    --type=merge -p '{"metadata":{"finalizers":[]}}'
  run kubectl delete application argocd-apps -n "$ARGOCD_NAMESPACE" --cascade=orphan --ignore-not-found=true
else
  echo "   argocd-apps not found — already removed"
fi

# 2. ApplicationSet templates here do not set resources-finalizer on the Applications they generate,
#    so deleting those Applications would leave every workload orphaned in the cluster. Add it.
echo ""
echo "🏷️  Step 2/5: adding resources-finalizer to generated Applications..."
apps="$(target_apps)"
if [[ -z "$apps" ]]; then
  echo "   No Applications to finalize"
else
  for app in $apps; do
    echo "   → $app"
    run kubectl patch application "$app" -n "$ARGOCD_NAMESPACE" \
      --type=merge -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
  done
fi

# 3. Deleting an ApplicationSet garbage-collects the Applications it owns (ownerReferences, and
#    preserveResourcesOnDeletion: false), which now cascade into their workloads via step 2.
echo ""
echo "🗑️  Step 3/5: deleting ApplicationSets..."
run kubectl delete applicationsets --all -n "$ARGOCD_NAMESPACE" --ignore-not-found=true --wait=false

# 4. The standalone Applications under templates/applications/ (kube-prometheus-stack, rancher,
#    portainer, victoria-metrics-vmauth) have no ApplicationSet owner — delete them directly.
echo ""
echo "🗑️  Step 4/5: deleting remaining Applications..."
for app in $(target_apps); do
  echo "   → $app"
  run kubectl delete application "$app" -n "$ARGOCD_NAMESPACE" --ignore-not-found=true --wait=false
done

# 5. Argo CD prunes each Application's resources before releasing its finalizer, so an Application
#    that is gone is a workload tree that is gone.
echo ""
echo "⏳ Step 5/5: waiting up to ${DELETE_TIMEOUT}s for Applications to finalize..."
if [[ "$DRY_RUN" == "true" ]]; then
  echo "   [dry-run] skipped"
else
  deadline=$(( $(date +%s) + DELETE_TIMEOUT ))
  while :; do
    remaining="$(target_apps)"
    [[ -z "$remaining" ]] && break
    if (( $(date +%s) >= deadline )); then
      echo ""
      echo "⚠️  Timed out with $(echo "$remaining" | wc -l | tr -d ' ') Application(s) still finalizing:"
      echo "$remaining" | sed 's/^/     /'
      if [[ "$FORCE_FINALIZERS" != "true" ]]; then
        echo ""
        echo "   These are usually blocked on a resource that will not delete (stuck PVC, webhook,"
        echo "   namespace terminating). Inspect with:"
        echo "     kubectl describe application <name> -n $ARGOCD_NAMESPACE"
        echo ""
        echo "   To strip the finalizers and give up on pruning their resources (leaves workloads"
        echo "   orphaned in the cluster), re-run with:"
        echo "     task destroy-app-of-apps FORCE_FINALIZERS=true"
        exit 1
      fi
      echo ""
      echo "🔨 FORCE_FINALIZERS=true — stripping finalizers; their resources are left orphaned"
      for app in $remaining; do
        echo "   → $app"
        kubectl patch application "$app" -n "$ARGOCD_NAMESPACE" \
          --type=merge -p '{"metadata":{"finalizers":[]}}' || true
      done
      break
    fi
    printf '.'
    sleep 5
  done
  echo ""
fi

# Namespaces created by CreateNamespace=true are not owned by any single Application, so they
# routinely outlive it — empty, but present.
echo ""
# The `if .metadata.annotations` guard is required: `index` on a namespace with no annotations at
# all (argocd itself) aborts the whole template with "index of untyped nil".
leftover_ns="$(kubectl get namespace -o go-template='{{range .items}}{{if .metadata.annotations}}{{if index .metadata.annotations "argocd.argoproj.io/managed"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}' 2>/dev/null || true)"
keep_ns=""
for ns in $leftover_ns; do
  in_list "$ns" "${PROTECTED_NAMESPACES[@]}" || keep_ns="$keep_ns $ns"
done
if [[ -n "${keep_ns// /}" ]]; then
  echo "📋 Argo-CD-managed namespaces still present:"
  for ns in $keep_ns; do echo "     $ns"; done
  if [[ "$DELETE_NAMESPACES" == "true" ]]; then
    echo "🗑️  DELETE_NAMESPACES=true — deleting them..."
    for ns in $keep_ns; do
      echo "   → $ns"
      run kubectl delete namespace "$ns" --ignore-not-found=true --wait=false
    done
  else
    echo "   Re-run with DELETE_NAMESPACES=true to remove them."
  fi
fi

echo ""
echo "✅ App-of-apps torn down"
echo "   Argo CD is still running and still self-managed (Applications: $(printf '%s ' "${KEEP_APPS[@]}"))."
echo "   Re-deploy with: task app-of-apps"
echo "   Remove Argo CD itself with: task uninstall"
