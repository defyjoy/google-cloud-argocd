#!/usr/bin/env bash
set -euo pipefail

# Scaffold the gitignored hashicorp-vault-init.json from the committed
# example template, so the unseal/status/create-secret tasks have a file to
# read when Vault was initialized on a previous run (keys are only ever emitted
# once, at `vault operator init`).
#
# Run from {{.BOOTSTRAP_STATE_DIR}} (the Taskfile sets `dir:` accordingly).

TEMPLATE="hashicorp-vault-init.example.json"
TARGET="hashicorp-vault-init.json"

if [ ! -f "$TEMPLATE" ]; then
  echo "❌ Template $TEMPLATE not found in $(pwd)"
  exit 1
fi

if [ -f "$TARGET" ]; then
  # Guard against clobbering a file that already holds real keys.
  if grep -q "REPLACE_WITH" "$TARGET"; then
    echo "ℹ️  $TARGET already exists (still contains placeholders)."
  else
    echo "⚠️  $TARGET already exists and appears to contain real keys — not overwriting."
  fi
  echo "   Edit it directly if you need to change the keys: $(pwd)/$TARGET"
  exit 0
fi

cp "$TEMPLATE" "$TARGET"
echo "✅ Created $TARGET from $TEMPLATE"
echo ""
echo "📝 Next steps:"
echo "   1. Open $(pwd)/$TARGET"
echo "   2. Replace every REPLACE_WITH_* placeholder with the values you saved"
echo "      from the original 'vault operator init' output:"
echo "        - unseal_keys_b64[]  → the 5 base64 unseal keys (required to unseal)"
echo "        - unseal_keys_hex[]  → the 5 hex unseal keys (shown by the status task)"
echo "        - root_token         → the root token (used by create-secret/status)"
echo "   3. Then run: task hashicorp-vault-unseal"
echo ""
echo "🔒 $TARGET is gitignored — it will not be committed."
