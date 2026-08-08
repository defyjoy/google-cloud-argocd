#!/usr/bin/env bash
set -euo pipefail

# Installs the Kubernetes Gateway API CRDs (gateway.networking.k8s.io).
#
# helmcharts/gateway-api-crds packages the same manifest for Argo CD, but it cannot sync early
# enough for the charts that depend on it. Without these CRDs every chart templating an
# HTTPRoute/TCPRoute fails to sync with:
#   The Kubernetes API could not find gateway.networking.k8s.io/HTTPRoute for requested resource

: "${GATEWAY_API_VERSION:?}"
GATEWAY_API_CHANNEL="${GATEWAY_API_CHANNEL:-experimental}"

URL="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/${GATEWAY_API_CHANNEL}-install.yaml"

echo "🌉 Installing Gateway API CRDs (${GATEWAY_API_CHANNEL} channel, ${GATEWAY_API_VERSION})"
echo "   ${URL}"

# --server-side is REQUIRED, not a preference. A client-side apply stores the entire manifest in
# the kubectl.kubernetes.io/last-applied-configuration annotation, and the httproutes CRD alone is
# ~533 KB — well past the API server's 262144-byte annotation cap. Plain `kubectl apply -f` dies
# with: metadata.annotations: Too long: must have at most 262144 bytes
#
# --force-conflicts takes ownership from any earlier client-side apply of the same CRDs; these
# CRDs are not managed by any chart in this repo, so there is no Argo CD field manager to fight.
kubectl apply --server-side --force-conflicts -f "$URL"

# Established means the API server is actually serving the type. Applying the manifest is not
# enough — a chart syncing in the gap still gets "could not find ... HTTPRoute".
echo "⏳ Waiting for CRDs to become Established..."
for crd in \
  gatewayclasses \
  gateways \
  httproutes \
  tcproutes \
  backendtlspolicies; do
  kubectl wait --for=condition=Established --timeout=60s \
    "crd/${crd}.gateway.networking.k8s.io"
done

echo "✅ Gateway API CRDs ready:"
kubectl get crd -o name \
  | grep 'gateway\.networking\.k8s\.io' \
  | sed 's|customresourcedefinition.apiextensions.k8s.io/|   - |'
