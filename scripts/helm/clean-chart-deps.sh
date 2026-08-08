#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="${1:?Chart directory required}"
cd "$CHART_DIR"
echo "🧹 Cleaning up..."
rm -rf charts/*.tgz
echo "✅ Cleanup complete"
