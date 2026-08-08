# Vault Management Tasks

This directory contains a Taskfile for managing HashiCorp Vault operations, specifically for unsealing Vault pods using keys stored in a JSON file.

Implementation scripts live in [`scripts/`](./scripts/README.md) and are invoked by Task; you can also run them directly with the same environment variables.

## Prerequisites

- **Task runner**: Install Task from https://taskfile.dev/installation/
- **kubectl**: Kubernetes command-line tool
- **jq**: JSON processor (for parsing the unseal keys JSON file)
- **kubeconfig**: Valid Kubernetes cluster access
- **Vault pods**: Vault pods must be running in the cluster

## Important: Get Real Vault Init Keys First

⚠️ **CRITICAL**: Before running `task unseal`, you need to initialize Vault and get the real unseal keys.

The `task create-dummy-init` creates fake keys that **will NOT work** with real Vault!

### Step 1: Initialize Vault (if not already done)

```bash
# Connect to the first Vault pod
kubectl exec -it local-vault-0 -n vault -- sh

# Initialize Vault (run inside the pod)
vault operator init -key-shares=5 -key-threshold=3 -format=json > /tmp/vault-init.json

# Exit the pod
exit

# Copy the JSON file to your local machine
kubectl cp vault/local-vault-0:/tmp/vault-init.json ./hashicorp-vault-init.json
```

### Step 2: Store the Keys Securely

The `hashicorp-vault-init.json` file contains:
- **Root token** (full access to Vault)
- **5 unseal keys** (need 3 to unseal)

⚠️ **Store these securely** - this is your only chance to get them!

### Step 3: Run Unseal Task

```bash
cd helmcharts/vault
task unseal
```

## Quick Start

Run `task --list` from `helmcharts/vault` for all tasks.

