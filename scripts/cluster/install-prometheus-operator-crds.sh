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
# So the CRDs are installed imperatively here, and the chart stays where it is.
#
# Source is the SUBCHART, never a hand-picked URL: whatever CRD version Argo CD is about to
# deploy is the version installed here, by construction. The subchart is normally already
# vendored in charts/; if it is not (a fresh clone — .gitignore excludes charts/*.tgz) it is
# fetched from the committed Chart.lock, which preserves that guarantee.

: "${REPO_ROOT:?}"

PARENT_DIR="${REPO_ROOT}/helmcharts/kube-prometheus-stack"
CHART_DIR="${PARENT_DIR}/charts"
TGZ=$(ls "${CHART_DIR}"/kube-prometheus-stack-*.tgz 2>/dev/null | head -1)

# .gitignore excludes helmcharts/**/charts/*.tgz, so a fresh clone has NO vendored subchart and
# this script used to exit 1 here — aborting bootstrap before Argo CD was ever installed. Fetch
# it instead.
#
# `dependency build`, not `update`: build resolves from the committed Chart.lock (78.5.0), so the
# CRD version is pinned and reproducible. `update` would re-resolve the range and could pull a
# newer chart than the one Argo CD is about to deploy — reintroducing the version skew this
# script exists to avoid.
if [[ -z "$TGZ" ]]; then
  echo "📦 No vendored kube-prometheus-stack chart in ${CHART_DIR} — fetching from Chart.lock..."
  if ! helm dependency build "$PARENT_DIR"; then
    echo "❌ helm dependency build failed for ${PARENT_DIR}"
    echo "   Needs network access to https://prometheus-community.github.io/helm-charts"
    exit 1
  fi
  TGZ=$(ls "${CHART_DIR}"/kube-prometheus-stack-*.tgz 2>/dev/null | head -1)
fi

if [[ -z "$TGZ" ]]; then
  echo "❌ Still no kube-prometheus-stack chart in ${CHART_DIR} after dependency build"
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
