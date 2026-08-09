#!/usr/bin/env bash
set -euo pipefail

# Verifies that GKE's MANAGED Gateway API is enabled on the target cluster.
#
# This replaces the old install-gateway-api-crds.sh, which applied the UPSTREAM
# gateway-api v1.5.1 experimental manifest. On GKE that is actively wrong: GKE owns and versions
# the Gateway API CRDs itself, and refuses to install its own over pre-existing ones. Applying
# upstream CRDs on top of (or ahead of) a GKE cluster leaves the managed Gateway controller with
# CRDs it does not recognise, and no Gateway ever gets programmed.
#
# So this script INSTALLS NOTHING. It checks, and tells you the one gcloud command to run.
# Enabling Gateway API is a control-plane mutation and is deliberately left to the operator.

echo "🌉 Checking GKE managed Gateway API..."

missing=()
for crd in gatewayclasses gateways httproutes; do
  if ! kubectl get "crd/${crd}.gateway.networking.k8s.io" &>/dev/null; then
    missing+=("${crd}.gateway.networking.k8s.io")
  fi
done

if (( ${#missing[@]} > 0 )); then
  cat <<'EOF'
❌ Gateway API CRDs are not present — GKE's managed Gateway API is not enabled on this cluster.

   Nothing in this repo can install them: they are GKE-owned. Enable them with:

     gcloud container clusters update <CLUSTER> \
       --location <LOCATION> --project <PROJECT> \
       --gateway-api=standard

   For the management cluster that is:

     gcloud container clusters update yeti-hub-gke \
       --location us-central1-a --project yeti-504903 \
       --gateway-api=standard

   Then re-run bootstrap. See helmcharts/gke-gateway/README.md.
EOF
  exit 1
fi

echo "✓ Gateway API CRDs present"

# A GatewayClass is the real signal: the CRDs can exist while the controller has not published
# any class, in which case helmcharts/gke-gateway has nothing to bind to.
classes=$(kubectl get gatewayclass -o name 2>/dev/null | sed 's|gatewayclass.gateway.networking.k8s.io/||' || true)

if [[ -z "$classes" ]]; then
  echo "❌ No GatewayClass is published. The Gateway API CRDs exist but no controller claimed them."
  echo "   On GKE this usually means the upstream CRDs were installed by hand over GKE's."
  exit 1
fi

echo "✓ GatewayClasses available:"
echo "$classes" | sed 's|^|   - |'

# TCPRoute is experimental-channel only. GKE ships the standard channel, so four charts in this
# repo (cloudnative-pg, victoria-metrics, nats, tempo) cannot have their TCPRoute served here.
if kubectl get crd/tcproutes.gateway.networking.k8s.io &>/dev/null; then
  echo "ℹ️  TCPRoute CRD present (non-GKE / experimental channel)."
else
  echo "⚠️  No TCPRoute CRD — expected on GKE (standard channel only)."
  echo "   cloudnative-pg, victoria-metrics, nats and tempo template a TCPRoute and will fail to"
  echo "   sync until it is disabled per-cluster. See helmcharts/gke-gateway/README.md."
fi

echo "✅ GKE Gateway API preflight passed"
