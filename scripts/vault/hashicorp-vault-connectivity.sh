#!/usr/bin/env bash
set -euo pipefail

echo "🌐 Checking cluster connectivity..."
if ! command -v kubectl &>/dev/null; then
  echo "❌ kubectl command not found. Please install kubectl."
  exit 1
fi
echo "✅ kubectl command found"

if ! kubectl cluster-info &>/dev/null; then
  echo "❌ Cannot connect to Kubernetes cluster. Check your kubeconfig."
  echo "   Current context: $(kubectl config current-context 2>/dev/null || echo 'none')"
  exit 1
fi
echo "✅ Cluster connectivity verified"

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null)
echo "📋 Current context: $CURRENT_CONTEXT"

if ! kubectl get nodes &>/dev/null; then
  echo "❌ Cannot access cluster nodes. Check your permissions."
  exit 1
fi
echo "✅ Cluster access verified"

if ! kubectl get namespaces &>/dev/null; then
  echo "❌ Cannot access cluster namespaces. Check your permissions."
  exit 1
fi
echo "✅ Namespace access verified"

echo "✅ Cluster connectivity check passed"
