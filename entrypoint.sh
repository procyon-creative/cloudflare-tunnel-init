#!/bin/sh
set -e

# cloudflare-tunnel-init entrypoint
# Creates/configures a Cloudflare Tunnel, optionally sets up Access auth,
# then exec's into cloudflared to run the tunnel.

API_BASE="https://api.cloudflare.com/client/v4"
CONFIG_FILE="${CONFIG_FILE:-/config/tunnel-config.json}"
ACCESS_CREDENTIALS_FILE="${ACCESS_CREDENTIALS_FILE:-/shared/access-credentials.json}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }

cf_api() {
  method="$1"; shift
  path="$1"; shift
  resp=$(curl -s -X "$method" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@" \
    "${API_BASE}${path}") || die "curl failed for $method $path"

  if echo "$resp" | jq -e '.success == false' >/dev/null 2>&1; then
    errors=$(echo "$resp" | jq -r '.errors[] | "\(.code): \(.message)"' 2>/dev/null || echo "unknown error")
    die "$method $path failed: $errors"
  fi

  echo "$resp"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
missing=""
for var in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ZONE_ID TUNNEL_NAME; do
  eval val=\$$var
  if [ -z "$val" ]; then
    missing="$missing $var"
  fi
done

if [ -n "$missing" ]; then
  die "Missing required environment variables:$missing"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  die "Config file not found: $CONFIG_FILE"
fi

validate_config() {
  config="$1"

  if ! jq empty "$config" 2>/dev/null; then
    die "Config file is not valid JSON: $config"
  fi

  has_ingress=$(jq 'has("ingress")' "$config")
  if [ "$has_ingress" != "true" ]; then
    die "Config file missing required 'ingress' array"
  fi

  ingress_type=$(jq -r '.ingress | type' "$config")
  if [ "$ingress_type" != "array" ]; then
    die "'ingress' must be an array, got: $ingress_type"
  fi

  ingress_len=$(jq '.ingress | length' "$config")
  if [ "$ingress_len" -lt 1 ]; then
    die "'ingress' array must have at least one rule"
  fi

  unknown_keys=$(jq -r 'keys[] | select(. != "$schema" and . != "ingress")' "$config")
  if [ -n "$unknown_keys" ]; then
    die "Unknown top-level keys in config: $unknown_keys"
  fi

  i=0
  while [ "$i" -lt "$ingress_len" ]; do
    rule=$(jq ".ingress[$i]" "$config")

    has_service=$(echo "$rule" | jq 'has("service")')
    if [ "$has_service" != "true" ]; then
      die "Ingress rule $i missing required 'service' field"
    fi

    service=$(echo "$rule" | jq -r '.service')
    if [ -z "$service" ]; then
      die "Ingress rule $i has empty 'service' field"
    fi

    unknown_rule_keys=$(echo "$rule" | jq -r 'keys[] | select(. != "hostname" and . != "path" and . != "service" and . != "originRequest")')
    if [ -n "$unknown_rule_keys" ]; then
      die "Ingress rule $i has unknown keys: $unknown_rule_keys"
    fi

    i=$((i + 1))
  done

  last_rule=$(jq ".ingress[$((ingress_len - 1))]" "$config")
  last_has_hostname=$(echo "$last_rule" | jq 'has("hostname")')
  if [ "$last_has_hostname" = "true" ]; then
    die "Last ingress rule must be a catch-all with no 'hostname' (e.g. {\"service\": \"http_status:404\"})"
  fi

  i=0
  while [ "$i" -lt "$((ingress_len - 1))" ]; do
    has_hostname=$(jq ".ingress[$i] | has(\"hostname\")" "$config")
    if [ "$has_hostname" != "true" ]; then
      die "Ingress rule $i must have a 'hostname' (only the last rule can be a catch-all)"
    fi
    i=$((i + 1))
  done

  echo "Config validated: $ingress_len ingress rules"
}

echo "Validating config file: $CONFIG_FILE"
validate_config "$CONFIG_FILE"

ingress_rules=$(jq '.ingress' "$CONFIG_FILE")

# ---------------------------------------------------------------------------
# 1. Create or find tunnel
# ---------------------------------------------------------------------------
echo "Looking for existing tunnel named '${TUNNEL_NAME}'..."

existing=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false")
tunnel_count=$(echo "$existing" | jq '.result | length')

if [ "$tunnel_count" -gt 0 ]; then
  TUNNEL_ID=$(echo "$existing" | jq -r '.result[0].id')
  echo "Found existing tunnel: ${TUNNEL_ID}"
else
  echo "Creating tunnel '${TUNNEL_NAME}'..."
  create_resp=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" \
    -d "{\"name\":\"${TUNNEL_NAME}\",\"config_src\":\"cloudflare\",\"tunnel_secret\":\"$(openssl rand -base64 32)\"}")

  TUNNEL_ID=$(echo "$create_resp" | jq -r '.result.id')
  echo "Created tunnel: ${TUNNEL_ID}"
fi

# ---------------------------------------------------------------------------
# 2. Apply ingress configuration
# ---------------------------------------------------------------------------
echo "Configuring ingress rules..."

config_payload=$(jq -n --argjson ingress "$ingress_rules" '{"config": {"ingress": $ingress}}')
cf_api PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -d "$config_payload" > /dev/null

echo "Ingress rules applied."

# ---------------------------------------------------------------------------
# 3. Create DNS CNAME records
# ---------------------------------------------------------------------------
echo "Setting up DNS records..."

hostnames=$(echo "$ingress_rules" | jq -r '.[] | select(.hostname) | .hostname')

for hostname in $hostnames; do
  cname_target="${TUNNEL_ID}.cfargotunnel.com"

  dns_check=$(cf_api GET "/zones/${CLOUDFLARE_ZONE_ID}/dns_records?type=CNAME&name=${hostname}")
  record_count=$(echo "$dns_check" | jq '.result | length')

  if [ "$record_count" -gt 0 ]; then
    existing_content=$(echo "$dns_check" | jq -r '.result[0].content')
    if [ "$existing_content" = "$cname_target" ]; then
      echo "  DNS record for ${hostname} already exists and is correct."
    else
      record_id=$(echo "$dns_check" | jq -r '.result[0].id')
      echo "  Updating DNS record for ${hostname}..."
      cf_api PUT "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${record_id}" \
        -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${cname_target}\",\"proxied\":true}" \
        > /dev/null
    fi
  else
    echo "  Creating DNS record for ${hostname}..."
    cf_api POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
      -d "{\"type\":\"CNAME\",\"name\":\"${hostname}\",\"content\":\"${cname_target}\",\"proxied\":true}" \
      > /dev/null
  fi
done

# ---------------------------------------------------------------------------
# 4. Cloudflare Access auth (optional)
# ---------------------------------------------------------------------------
if [ "${ACCESS_ENABLED}" = "true" ]; then
  echo "Setting up Cloudflare Access..."

  ACCESS_TOKEN_NAME="${ACCESS_TOKEN_NAME:-${TUNNEL_NAME}-service-token}"
  ACCESS_APP_NAME="${ACCESS_APP_NAME:-${TUNNEL_NAME}-access}"
  ACCESS_POLICY_NAME="${ACCESS_POLICY_NAME:-${TUNNEL_NAME}-service-auth}"

  # --- Service Token ---
  if [ -f "$ACCESS_CREDENTIALS_FILE" ]; then
    echo "  Found existing credentials file: $ACCESS_CREDENTIALS_FILE"
    SERVICE_TOKEN_ID=$(jq -r '.service_token_id' "$ACCESS_CREDENTIALS_FILE")
    echo "  Using existing service token: ${SERVICE_TOKEN_ID}"
  else
    existing_tokens=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/service_tokens")
    existing_token_id=$(echo "$existing_tokens" | jq -r --arg name "$ACCESS_TOKEN_NAME" '.result[] | select(.name == $name) | .id' | head -1)

    if [ -n "$existing_token_id" ]; then
      echo "  Found existing service token '${ACCESS_TOKEN_NAME}' but no saved credentials. Rotating..."
      rotate_resp=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/service_tokens/${existing_token_id}/rotate")

      SERVICE_TOKEN_ID=$(echo "$rotate_resp" | jq -r '.result.id')
      CLIENT_ID=$(echo "$rotate_resp" | jq -r '.result.client_id')
      CLIENT_SECRET=$(echo "$rotate_resp" | jq -r '.result.client_secret')
    else
      echo "  Creating service token '${ACCESS_TOKEN_NAME}'..."
      token_resp=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/service_tokens" \
        -d "{\"name\":\"${ACCESS_TOKEN_NAME}\",\"duration\":\"8760h\"}")

      SERVICE_TOKEN_ID=$(echo "$token_resp" | jq -r '.result.id')
      CLIENT_ID=$(echo "$token_resp" | jq -r '.result.client_id')
      CLIENT_SECRET=$(echo "$token_resp" | jq -r '.result.client_secret')
    fi

    # Save credentials immediately — secret is never returned again
    mkdir -p "$(dirname "$ACCESS_CREDENTIALS_FILE")"
    jq -n \
      --arg sid "$SERVICE_TOKEN_ID" \
      --arg cid "$CLIENT_ID" \
      --arg csec "$CLIENT_SECRET" \
      '{"service_token_id": $sid, "client_id": $cid, "client_secret": $csec}' \
      > "$ACCESS_CREDENTIALS_FILE"
    chmod 600 "$ACCESS_CREDENTIALS_FILE"
    echo "  Credentials saved to $ACCESS_CREDENTIALS_FILE"
  fi

  # --- Access Policy ---
  echo "  Configuring Access policy..."

  existing_policies=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/policies")
  POLICY_ID=$(echo "$existing_policies" | jq -r --arg name "$ACCESS_POLICY_NAME" '.result[] | select(.name == $name) | .id' | head -1)

  if [ -n "$POLICY_ID" ]; then
    echo "  Found existing policy: ${POLICY_ID}"
    cf_api PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/policies/${POLICY_ID}" \
      -d "{\"name\":\"${ACCESS_POLICY_NAME}\",\"decision\":\"non_identity\",\"include\":[{\"service_token\":{\"token_id\":\"${SERVICE_TOKEN_ID}\"}}]}" \
      > /dev/null
  else
    echo "  Creating Access policy '${ACCESS_POLICY_NAME}'..."
    policy_resp=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/policies" \
      -d "{\"name\":\"${ACCESS_POLICY_NAME}\",\"decision\":\"non_identity\",\"include\":[{\"service_token\":{\"token_id\":\"${SERVICE_TOKEN_ID}\"}}]}")

    POLICY_ID=$(echo "$policy_resp" | jq -r '.result.id')
    echo "  Created policy: ${POLICY_ID}"
  fi

  # --- Access Applications (one per hostname) ---
  existing_apps=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps")

  for hostname in $hostnames; do
    app_name="${ACCESS_APP_NAME}-${hostname}"

    APP_ID=$(echo "$existing_apps" | jq -r --arg domain "$hostname" '.result[] | select(.domain == $domain) | .id' | head -1)

    if [ -n "$APP_ID" ]; then
      echo "  Access app for ${hostname} already exists: ${APP_ID}"
      cf_api PUT "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}" \
        -d "{\"name\":\"${app_name}\",\"type\":\"self_hosted\",\"domain\":\"${hostname}\",\"session_duration\":\"24h\",\"policies\":[{\"id\":\"${POLICY_ID}\",\"precedence\":1}]}" \
        > /dev/null
    else
      echo "  Creating Access app for ${hostname}..."
      app_resp=$(cf_api POST "/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" \
        -d "{\"name\":\"${app_name}\",\"type\":\"self_hosted\",\"domain\":\"${hostname}\",\"session_duration\":\"24h\",\"policies\":[{\"id\":\"${POLICY_ID}\",\"precedence\":1}]}")

      APP_ID=$(echo "$app_resp" | jq -r '.result.id')
      echo "  Created Access app: ${APP_ID}"
    fi
  done

  echo "Cloudflare Access configured."
fi

# ---------------------------------------------------------------------------
# 5. Get tunnel token and run cloudflared
# ---------------------------------------------------------------------------
echo "Fetching tunnel token..."

token_resp=$(cf_api GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token")
TUNNEL_TOKEN=$(echo "$token_resp" | jq -r '.result')

if [ -z "$TUNNEL_TOKEN" ] || [ "$TUNNEL_TOKEN" = "null" ]; then
  die "Got empty tunnel token from API"
fi

echo ""
echo "========================================="
echo "Tunnel ready: ${TUNNEL_NAME} (${TUNNEL_ID})"
echo "Starting cloudflared..."
echo "========================================="

exec cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN"
