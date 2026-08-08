#!/bin/bash
# Script to load nvme module on Kubernetes nodes
# Run this script on each node via SSH

set -e

echo "🔍 Checking if nvme module is already loaded..."
if lsmod | grep -q "^nvme "; then
    echo "✅ nvme module is already loaded"
    lsmod | grep nvme
else
    echo "📦 Loading nvme module..."
    modprobe nvme
    if [ $? -eq 0 ]; then
        echo "✅ nvme module loaded successfully"
        lsmod | grep nvme
    else
        echo "❌ Failed to load nvme module"
        exit 1
    fi
fi

echo ""
echo "💾 Making nvme module persistent across reboots..."
if [ ! -f /etc/modules-load.d/nvme.conf ]; then
    echo "nvme" | sudo tee /etc/modules-load.d/nvme.conf > /dev/null
    echo "✅ Added nvme to /etc/modules-load.d/nvme.conf"
else
    if grep -q "^nvme$" /etc/modules-load.d/nvme.conf; then
        echo "✅ nvme already in /etc/modules-load.d/nvme.conf"
    else
        echo "nvme" | sudo tee -a /etc/modules-load.d/nvme.conf > /dev/null
        echo "✅ Added nvme to /etc/modules-load.d/nvme.conf"
    fi
fi

echo ""
echo "📊 Verification:"
echo "Loaded modules:"
lsmod | grep nvme || echo "No nvme modules found"
echo ""
echo "Module file:"
cat /etc/modules-load.d/nvme.conf 2>/dev/null || echo "Module file not found"
