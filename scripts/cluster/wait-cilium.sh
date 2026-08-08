#!/usr/bin/env bash
set -euo pipefail

# Waits for Cilium to be the live datapath: agents rolled out, operator ready, and every node
# flipped NotReady -> Ready. On a fresh Talos cluster (cni:none) the nodes cannot become Ready
# until Cilium's agents are running, so node Readiness is the real success signal.
CILIUM_NAMESPACE="${CILIUM_NAMESPACE:-kube-system}"
readonly overall_deadline=$((SECONDS + 900))

remaining_s() {
  local left=$((overall_deadline - SECONDS))
  (( left < 1 )) && left=1
  echo "$left"
}

echo "⏳ Waiting for Cilium in namespace ${CILIUM_NAMESPACE}..."

# 1) Cilium agent DaemonSet + operator (helm --wait usually covers this; belt and suspenders).
echo "   rollout status daemonset/cilium ..."
kubectl -n "$CILIUM_NAMESPACE" rollout status daemonset/cilium --timeout="$(remaining_s)s"

if kubectl -n "$CILIUM_NAMESPACE" get deploy cilium-operator &>/dev/null; then
  echo "   rollout status deployment/cilium-operator ..."
  kubectl -n "$CILIUM_NAMESPACE" rollout status deployment/cilium-operator --timeout="$(remaining_s)s"
fi

# 2) Every node Ready (the datapath is only truly up once the CNI reports Ready per node).
echo "   waiting for all nodes to be Ready ..."
kubectl wait --for=condition=Ready node --all --timeout="$(remaining_s)s"

echo "✅ Cilium is ready and all nodes are Ready in ${CILIUM_NAMESPACE}"
