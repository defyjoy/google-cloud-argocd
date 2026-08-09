#!/usr/bin/env bash
set -euo pipefail

# Seeds bootstrap secrets into Vault by exec'ing the `vault` CLI inside a Vault pod.
#
# Why exec instead of talking to Vault over the network: this runs before the cluster has
# a working north-south path, so vault.jrclabs.xyz is not yet resolvable or routable.
# `kubectl exec` reaches Vault over the API server, which needs no Gateway and no HTTPRoute.
#
# The secret is streamed in over the exec stdin and consumed by `vault kv put <path> -`.
# Nothing is written to the pod filesystem and no secret is ever passed as a command
# argument (argv is visible to anything that can read /proc inside the container).
#
# Seeds one path:
#   <mount>/alarmify/<env>/cloudflared/token        token               -> external-dns
#
# The `cloudflared/` path segment is historical. The Cloudflare TUNNEL was removed (north-south
# traffic now goes through the GKE Gateways in helmcharts/gke-gateway), but external-dns still
# manages the jrclabs.xyz zone through the Cloudflare DNS API and reads its token from here.
# Renaming the path would require rewriting helmcharts/external-dns/values/*.yaml and
# re-seeding both clusters' Vaults, so it is deliberately left alone.

VAULT_NAMESPACE="${VAULT_NAMESPACE:?}"
VAULT_CLUSTER_PREFIX="${VAULT_CLUSTER_PREFIX:?}"
VAULT_REPLICAS="${VAULT_REPLICAS:?}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-kv}"
VAULT_ENV="${VAULT_ENV:-local}"
VAULT_INIT_FILE="${VAULT_INIT_FILE:-hashicorp-vault-init.json}"

# Tasks run from BOOTSTRAP_STATE_DIR, so the repo root is derived from this script's
# own location rather than $PWD. This file lives in scripts/vault/, hence ../.. — keep
# these in step if the script is ever moved, or .env silently resolves to the wrong place.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

die() { echo "❌ $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# Reads one key out of a dotenv file. Deliberately NOT `source`: .env is hand-edited,
# and sourcing it would execute whatever is in there and export every other key into
# this script's environment, where it could shadow a VAULT_* var above.
dotenv_get() {
  local file="$1" key="$2" line value
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" | tail -n 1) || return 0
  [ -n "$line" ] || return 0
  value=${line#*=}
  value=$(printf '%s' "$value" | sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [ ${#value} -ge 2 ]; then
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
  fi
  printf '%s' "$value"
}

# The Vault env segment is the ARGO CD CLUSTER NAME, not a deployment stage — `local`
# is the management cluster. There is no prod; an alarmify/prod/... path resolves to
# nothing and fails the whole ExternalSecret.
case "$VAULT_ENV" in
  local|dev) ;;
  *) die "VAULT_ENV must be 'local' (management cluster) or 'dev' — got '$VAULT_ENV'" ;;
esac

echo "🔐 Provisioning Vault secrets for env '$VAULT_ENV' (mount '$VAULT_KV_MOUNT')"

# ---------------------------------------------------------------------------
# Cloudflare API token — read before touching the cluster so a missing .env
# fails in a second rather than after the credentials write
# ---------------------------------------------------------------------------
# An exported CLOUDFLARE_API_TOKEN wins over .env, matching how VAULT_TOKEN is handled
# below, so CI can supply it without writing a file.
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  echo "🔑 Using CLOUDFLARE_API_TOKEN from the environment"
else
  [ -f "$ENV_FILE" ] || die "$ENV_FILE not found.
   cp $REPO_ROOT/.env.example $ENV_FILE and set CLOUDFLARE_API_TOKEN, or export it."
  CLOUDFLARE_API_TOKEN=$(dotenv_get "$ENV_FILE" CLOUDFLARE_API_TOKEN)
  [ -n "$CLOUDFLARE_API_TOKEN" ] || die "CLOUDFLARE_API_TOKEN is unset or empty in $ENV_FILE.
   Create a token at https://dash.cloudflare.com -> My Profile -> API Tokens with
   Zone:Read + DNS:Edit on jrclabs.xyz, then put it in $ENV_FILE."
  echo "🔑 Using CLOUDFLARE_API_TOKEN from $ENV_FILE"
fi

case "$CLOUDFLARE_API_TOKEN" in
  *[[:space:]]*) die "CLOUDFLARE_API_TOKEN contains whitespace — check the quoting in $ENV_FILE" ;;
esac

# Exported so jq can read it as $ENV.CLOUDFLARE_API_TOKEN below instead of taking it as
# --arg, which would put the token in the local jq process's argv.
export CLOUDFLARE_API_TOKEN

# external-dns is the only consumer and it fails *quietly*: a bad token means DNS records
# silently stop being reconciled while every pod stays Running. Ask Cloudflare up front.
# Only an explicit rejection is fatal — no curl, or no egress, must not block a bootstrap.
#
# Deliberately NOT /user/tokens/verify. That endpoint only validates USER-owned tokens and
# answers code 1000 "Invalid API Token" for a perfectly valid ACCOUNT-owned one (created
# under Account -> API Tokens instead of My Profile -> API Tokens) — a false negative that
# blocks the bootstrap on a working token. Listing the zone external-dns manages instead
# authenticates either kind of token AND proves it carries the Zone:Read scope it needs.
CLOUDFLARE_ZONE="${CLOUDFLARE_ZONE:-jrclabs.xyz}"  # helmcharts/external-dns domainFilters

if command -v curl >/dev/null 2>&1 && [ "${CLOUDFLARE_TOKEN_VERIFY:-true}" = "true" ]; then
  # No `curl -f`: Cloudflare answers a bad token with HTTP 400 and a JSON body naming the
  # reason, and -f would throw that body away and make a rejection look like an outage.
  verify=$(curl -sS --max-time 15 \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=${CLOUDFLARE_ZONE}" 2>/dev/null) || verify=""
  if [ -z "$verify" ] || ! echo "$verify" | jq -e . >/dev/null 2>&1; then
    echo "   ⚠️  no usable answer from api.cloudflare.com — continuing unverified"
  elif ! echo "$verify" | jq -e '.success == true' >/dev/null 2>&1; then
    die "Cloudflare rejected the token: $(echo "$verify" | jq -r '[.errors[]?.message] | join("; ") | select(. != "") // "unknown"')
   Set CLOUDFLARE_TOKEN_VERIFY=false to skip this check."
  elif ! echo "$verify" | jq -e --arg z "$CLOUDFLARE_ZONE" 'any(.result[]?; .name == $z)' >/dev/null 2>&1; then
    die "the token authenticates but cannot see zone '$CLOUDFLARE_ZONE'.
   external-dns manages that zone, so a token scoped to a different one leaves DNS stale
   while everything looks healthy. Widen its Zone Resources, or set CLOUDFLARE_ZONE."
  else
    echo "✅ Token authenticates and can see zone '$CLOUDFLARE_ZONE'"
  fi
fi

# ---------------------------------------------------------------------------
# Root token
# ---------------------------------------------------------------------------
if [ -z "${VAULT_TOKEN:-}" ]; then
  [ -f "$VAULT_INIT_FILE" ] || die "no VAULT_TOKEN in the environment and no $VAULT_INIT_FILE in $(pwd).
   Run 'task hashicorp-vault-init' (fresh Vault) or 'task hashicorp-vault-init-template'
   (paste saved keys), or export VAULT_TOKEN yourself."
  VAULT_TOKEN=$(jq -r '.root_token // empty' "$VAULT_INIT_FILE")
  [ -n "$VAULT_TOKEN" ] || die "could not read .root_token from $VAULT_INIT_FILE"
  echo "🔑 Using root token from $VAULT_INIT_FILE"
else
  echo "🔑 Using VAULT_TOKEN from the environment"
fi

# ---------------------------------------------------------------------------
# Target pod — must be the active (leader) node
# ---------------------------------------------------------------------------
# A sealed pod cannot answer, and a standby only redirects. Picking the active node
# up front turns "wrong pod" into a clear message instead of a confusing 307/503.
ACTIVE_POD=""
for i in $(seq 0 $((VAULT_REPLICAS - 1))); do
  pod="${VAULT_CLUSTER_PREFIX}-vault-$i"
  status=$(kubectl exec -n "$VAULT_NAMESPACE" "$pod" -- vault status -format=json 2>/dev/null || true)
  [ -n "$status" ] || { echo "   ⚠️  $pod unreachable, skipping"; continue; }
  if ! echo "$status" | jq -e '.sealed == false' >/dev/null 2>&1; then
    echo "   ⚠️  $pod is sealed, skipping"
    continue
  fi
  if echo "$status" | jq -e '.ha_enabled != true or .is_self == true' >/dev/null 2>&1; then
    ACTIVE_POD="$pod"
    break
  fi
  echo "   ℹ️  $pod is a standby"
done

[ -n "$ACTIVE_POD" ] || die "no unsealed active Vault pod found. Run 'task hashicorp-vault-unseal' first."
echo "✅ Active Vault pod: $ACTIVE_POD"

# Runs `vault <args...>` in the active pod with the root token supplied on the first
# line of stdin; everything after that first line is the command's own stdin.
vault_exec() {
  kubectl exec -i -n "$VAULT_NAMESPACE" "$ACTIVE_POD" -- sh -c '
    IFS= read -r VAULT_TOKEN
    export VAULT_TOKEN
    exec vault "$@"
  ' sh "$@"
}

# ---------------------------------------------------------------------------
# KV v2 mount
# ---------------------------------------------------------------------------
mounts=$(printf '%s\n' "$VAULT_TOKEN" | vault_exec secrets list -format=json) \
  || die "could not list secrets engines — is the token valid?"

if echo "$mounts" | jq -e --arg m "${VAULT_KV_MOUNT}/" 'has($m)' >/dev/null; then
  echo "$mounts" | jq -e --arg m "${VAULT_KV_MOUNT}/" '.[$m].options.version == "2"' >/dev/null \
    || die "mount '$VAULT_KV_MOUNT' exists but is not KV v2 — refusing to write"
  echo "✅ KV v2 mount '$VAULT_KV_MOUNT' present"
else
  echo "🔧 Enabling KV v2 at '$VAULT_KV_MOUNT'..."
  printf '%s\n' "$VAULT_TOKEN" | vault_exec secrets enable -path="$VAULT_KV_MOUNT" kv-v2
fi

# Cloudflare API token (external-dns)
# ---------------------------------------------------------------------------
# Separate path from the tunnel credentials on purpose: helmcharts/external-dns reads a
# single property via spec.data[], so external-dns never gets the tunnel's cert handed
# to it, and rotating the API token does not touch the tunnel.
CF_TOKEN_PATH="${VAULT_KV_MOUNT}/alarmify/${VAULT_ENV}/cloudflared/token"

# Field name is load-bearing: helmcharts/external-dns/templates/cloudflare-api-token-secret.yaml
# reads property `token` from this path.
echo "✍️  Writing $CF_TOKEN_PATH ..."
{
  printf '%s\n' "$VAULT_TOKEN"
  jq -n '{token: $ENV.CLOUDFLARE_API_TOKEN}'
} | vault_exec kv put "$CF_TOKEN_PATH" - >/dev/null

token_readback=$(printf '%s\n' "$VAULT_TOKEN" | vault_exec kv get -format=json "$CF_TOKEN_PATH")
echo "$token_readback" | jq -e '.data.data.token == $ENV.CLOUDFLARE_API_TOKEN' >/dev/null \
  || die "read-back of $CF_TOKEN_PATH does not match the token that was written"
echo "$token_readback" | jq -r '"✅ wrote version \(.data.metadata.version) — token \(.data.data.token|length) bytes"'

# ---------------------------------------------------------------------------
echo ""
echo "💡 Next steps:"
echo "   1. task hashicorp-vault-create-secret     # vault-token for External Secrets Operator"
echo "   2. kubectl get clustersecretstore vault-secretstore   # must report Ready=True"
echo "   3. kubectl get externalsecret -A                      # external-dns must report SecretSynced"
echo "   4. kubectl rollout restart deploy -n external-dns"
