#!/usr/bin/env bash
set -euo pipefail

# Installs the prometheus-operator CRDs (monitoring.coreos.com) ahead of Argo CD.
#
# kube-prometheus-stack is the chart that supplies these CRDs, but it cannot be the first thing
# to sync: its own templates carry ExternalSecrets (grafana-oidc, alarmify-oauth, pagerduty) that
# resolve against Vault, which lands much later (vault wave 3, external-secrets wave 4). Pulling
# the whole stack forward to fix a CRD ordering problem just trades it for a secrets ordering
# problem — and below cilium its pods cannot schedule at all.
#
# So the CRDs are installed imperatively here, exactly like the Gateway API ones, and the chart
# stays where it is.
#
# Source is the VENDORED subchart, not the network: whatever CRD version Argo CD is about to
# deploy is the version installed here, by construction.

: "${REPO_ROOT:?}"

CHART_DIR="${REPO_ROOT}/helmcharts/kube-prometheus-stack/charts"
TGZ=$(ls "${CHART_DIR}"/kube-prometheus-stack-*.tgz 2>/dev/null | head -1)

if [[ -z "$TGZ" ]]; then
  echo "❌ No vendored kube-prometheus-stack chart found in ${CHART_DIR}"
  echo "   Run: helm dependency update ${REPO_ROOT}/helmcharts/kube-prometheus-stack"
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

tar -xzf "$TGZ" -C "$TMP"
CRD_DIR="${TMP}/kube-prometheus-stack/charts/crds/crds"

if [[ ! -d "$CRD_DIR" ]]; then
  echo "❌ Vendored chart has no charts/crds/crds directory: $TGZ"
  exit 1
fi

OPERATOR_VERSION=$(grep -m1 '^appVersion:' "${TMP}/kube-prometheus-stack/Chart.yaml" | awk '{print $2}' | tr -d '"')
echo "🔭 Installing prometheus-operator CRDs (${OPERATOR_VERSION}, from $(basename "$TGZ"))"

# --server-side is REQUIRED. Six of these ten CRDs are 590 KB - 815 KB (prometheuses,
# alertmanagerconfigs, scrapeconfigs, prometheusagents, alertmanagers, thanosrulers) and a
# client-side apply would try to stash each one in the last-applied-configuration annotation,
# which the API server caps at 262144 bytes.
kubectl apply --server-side --force-conflicts -f "$CRD_DIR"

# Established means the API server is serving the type. Without this a chart syncing in the gap
# still fails with "could not find monitoring.coreos.com/ServiceMonitor".
echo "⏳ Waiting for CRDs to become Established..."
for crd in \
  servicemonitors \
  podmonitors \
  prometheusrules \
  alertmanagerconfigs \
  probes; do
  kubectl wait --for=condition=Established --timeout=60s \
    "crd/${crd}.monitoring.coreos.com"
done

echo "✅ prometheus-operator CRDs ready:"
kubectl get crd -o name \
  | grep 'monitoring\.coreos\.com' \
  | sed 's|customresourcedefinition.apiextensions.k8s.io/|   - |'
