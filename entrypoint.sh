#!/bin/sh
set -e

# cloudflare-tunnel-init entrypoint
# Creates/configures a Cloudflare Tunnel, optionally sets up Access auth,
# then exec's into cloudflared to run the tunnel.

API_BASE="https://api.cloudflare.com/client/v4"
CONFIG_FILE="${CONFIG_FILE:-/config/tunnel-config.json}"

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
# 4. API key auth via WAF custom rule (optional)
# ---------------------------------------------------------------------------
if [ -n "${API_KEY}" ]; then
  echo "Setting up API key auth (WAF custom rule)..."

  WAF_RULE_NAME="${TUNNEL_NAME}-api-key-auth"

  # Build expression: block requests to any ingress hostname without the correct Bearer token
  host_conditions=""
  for hostname in $hostnames; do
    if [ -n "$host_conditions" ]; then
      host_conditions="${host_conditions} or "
    fi
    host_conditions="${host_conditions}http.host eq \"${hostname}\""
  done

  expression="(${host_conditions}) and not (http.request.headers[\"authorization\"][0] eq \"Bearer ${API_KEY}\") and not (http.request.method eq \"OPTIONS\")"

  # Build rule JSON with jq to avoid escaping issues
  rule_json=$(jq -n --arg expr "$expression" --arg desc "$WAF_RULE_NAME" \
    '{expression: $expr, action: "block", description: $desc}')

  # Check if a custom firewall ruleset already exists
  existing_rulesets=$(cf_api GET "/zones/${CLOUDFLARE_ZONE_ID}/rulesets")
  RULESET_ID=$(echo "$existing_rulesets" | jq -r '.result[] | select(.phase == "http_request_firewall_custom") | .id' | head -1)

  if [ -n "$RULESET_ID" ]; then
    ruleset=$(cf_api GET "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${RULESET_ID}")
    RULE_ID=$(echo "$ruleset" | jq -r --arg desc "$WAF_RULE_NAME" '.result.rules[] | select(.description == $desc) | .id' | head -1)

    if [ -n "$RULE_ID" ]; then
      echo "  Updating existing WAF rule..."
      cf_api PATCH "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${RULESET_ID}/rules/${RULE_ID}" \
        -d "$rule_json" > /dev/null
    else
      echo "  Adding WAF rule to existing ruleset..."
      cf_api POST "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${RULESET_ID}/rules" \
        -d "$rule_json" > /dev/null
    fi
  else
    echo "  Creating WAF ruleset with API key rule..."
    ruleset_json=$(jq -n --argjson rule "$rule_json" \
      '{name: "API Key Auth", kind: "zone", phase: "http_request_firewall_custom", rules: [$rule]}')
    cf_api POST "/zones/${CLOUDFLARE_ZONE_ID}/rulesets" \
      -d "$ruleset_json" > /dev/null
  fi

  echo "  API key auth configured for: $hostnames"
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
