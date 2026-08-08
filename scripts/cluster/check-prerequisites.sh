#!/usr/bin/env bash
set -euo pipefail

echo "🔍 Checking prerequisites..."
if ! command -v kubectl &>/dev/null; then
  echo "❌ kubectl not found. Please install kubectl."
  exit 1
fi
echo "✓ kubectl found"
if ! command -v helm &>/dev/null; then
  echo "❌ helm not found. Please install Helm 3.x."
  exit 1
fi
echo "✓ helm found"
if ! kubectl cluster-info &>/dev/null; then
  echo "❌ Cannot connect to Kubernetes cluster. Check your kubeconfig."
  exit 1
fi
echo "✓ Cluster connectivity verified"
echo "✅ Prerequisites check passed"
