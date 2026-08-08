#!/usr/bin/env bash
set -euo pipefail

# Installs Cilium (CNI + kube-proxy replacement + LoadBalancer) — but only if the cluster does not
# already have a working one.
#
# Why the guard: `task bootstrap` is re-run on clusters that are already up (to pick up a new step,
# to recover Argo CD, or just by reflex). Once Argo CD has adopted the cilium chart it owns the
# DaemonSet's fields, and a plain `helm upgrade` loses a server-side-apply fight with it:
#
#   Upgrade "cilium" failed: conflict occurred while applying object kube-system/cilium
#   apps/v1, Kind=DaemonSet: Apply failed with 3 conflicts: conflicts with "argocd-controller"
#
# That leaves the Helm release in `failed` state and aborts bootstrap before any later step runs,
# on a cluster whose datapath was perfectly healthy. So: if Cilium is already serving, skip.
#
# Set CILIUM_FORCE_INSTALL=true to run Helm anyway (initial bring-up quirks, ArgoCD-down recovery).

: "${CILIUM_CHART_DIR:?}"
: "${CILIUM_RELEASE_NAME:?}"
: "${CILIUM_NAMESPACE:?}"
: "${CILIUM_VALUES:?}"

FORCE="${CILIUM_FORCE_INSTALL:-false}"

# The real question is "is the datapath live", not "does a Helm release exist" — Argo CD may own
# Cilium with no usable release record, and a `failed` release can sit atop a healthy DaemonSet.
cilium_is_serving() {
  local desired ready
  desired=$(kubectl -n "$CILIUM_NAMESPACE" get daemonset cilium \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "")
  ready=$(kubectl -n "$CILIUM_NAMESPACE" get daemonset cilium \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "")

  [[ -n "$desired" && -n "$ready" && "$desired" -gt 0 && "$ready" -eq "$desired" ]]
}

if [[ "$FORCE" != "true" ]] && cilium_is_serving; then
  ready=$(kubectl -n "$CILIUM_NAMESPACE" get daemonset cilium -o jsonpath='{.status.numberReady}')
  echo "⏭️  Cilium already serving (daemonset/cilium ${ready}/${ready} Ready in ${CILIUM_NAMESPACE}) — skipping Helm install."

  if helm status "$CILIUM_RELEASE_NAME" -n "$CILIUM_NAMESPACE" >/dev/null 2>&1; then
    status=$(helm status "$CILIUM_RELEASE_NAME" -n "$CILIUM_NAMESPACE" -o json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null || echo "unknown")
    echo "   Helm release '${CILIUM_RELEASE_NAME}' status: ${status}"
    if [[ "$status" != "deployed" ]]; then
      echo "   ℹ️  A non-deployed release record on a healthy datapath is expected once Argo CD"
      echo "      owns the chart. Argo CD is the reconciler now; the release record is inert."
    fi
  else
    echo "   No Helm release found — Cilium is managed by Argo CD alone."
  fi

  echo "   Re-run with CILIUM_FORCE_INSTALL=true to install over it anyway."
  exit 0
fi

if [[ "$FORCE" == "true" ]]; then
  echo "⚠️  CILIUM_FORCE_INSTALL=true — running Helm even though Cilium may already be serving."
  echo "   If Argo CD owns the DaemonSet this can fail with argocd-controller field conflicts."
fi

echo "🔷 Installing Cilium (${CILIUM_VALUES})..."
helm upgrade --install "$CILIUM_RELEASE_NAME" "$CILIUM_CHART_DIR" \
  --namespace "$CILIUM_NAMESPACE" --create-namespace \
  --values "${CILIUM_CHART_DIR}/values.yaml" \
  --values "${CILIUM_CHART_DIR}/${CILIUM_VALUES}" \
  --wait --timeout 15m

echo "✅ Cilium release applied"
