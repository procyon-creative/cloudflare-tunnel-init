# cloudflare-tunnel-init

## Overview

A standalone Docker container that automates Cloudflare Tunnel creation via the Cloudflare API. Drop it into any docker-compose project to get a fully configured tunnel on `docker compose up` — no manual dashboard setup, no `tunnel login`, no browser interaction.

## Core principle

**Everything must be automated via API. Zero manual steps. No logging into dashboards, no clicking through UIs, no browser interaction.** If a feature can't be set up entirely via environment variables and API calls on `docker compose up`, it doesn't ship. This applies to tunnel creation, DNS, ingress config, and any future features like Cloudflare Access auth.

## How it works

1. User adds one service to their docker-compose.yml (or .lando.yml) pointing at the published image
2. User provides Cloudflare API token, account ID, zone ID, and tunnel name in `.env`
3. User defines hostname→service mappings in `tunnel-config.json`
4. On container start, the entrypoint:
   - Creates a tunnel (or finds existing by name) via Cloudflare API
   - Configures ingress rules for declared services
   - Creates DNS CNAME records pointing to the tunnel
   - Exec's into `cloudflared tunnel run` to keep the tunnel alive

## Status

### Phase 1: Core init container — Done
- [x] entrypoint.sh with full API workflow (create/find tunnel, configure ingress, create DNS, write token)
- [x] Dockerfile (alpine + curl + jq + openssl)
- [x] docker-compose.yml with single service
- [x] .env.example with all required variables documented
- [x] Ingress config via mounted JSON file with JSON Schema validation

### Phase 2: Idempotency and error handling — Mostly done
- [x] Tunnel creation idempotent (finds by name before creating)
- [x] DNS record creation idempotent (checks before creating, updates if changed)
- [x] Ingress config idempotent (PUT replaces)
- [x] API errors handled with clear messages
- [ ] Support tunnel cleanup/deletion (optional destroy mode)

### Phase 3: Documentation and usability — Done
- [x] README with quick start
- [x] API token permissions documented
- [x] .gitignore

### Phase 4: API key auth via WAF — Done
- [x] If `API_KEY` is set, create a WAF custom rule blocking requests without `Authorization: Bearer <key>`
- [x] Standard OpenAI API key format — works with any client (Continue, Brave, LiteLLM, etc.)
- [x] Auth enforced at Cloudflare edge — no unauthenticated traffic reaches origin
- [x] Idempotent: finds existing ruleset/rule by name, updates if present
- [x] All via API — no dashboard interaction, no manual steps

### Phase 5: Per-route auth — In progress ([CT-1](https://procyoncreative.atlassian.net/browse/CT-1))
- [x] `auth.apiKey: true` on ingress rule opts that hostname into WAF Bearer protection; hostnames without it are public ([CT-2](https://procyoncreative.atlassian.net/browse/CT-2))
- [x] Breaking change: `API_KEY` no longer applies globally; each hostname must opt in
- [x] Stale WAF rule is removed when all hostnames opt out
- [ ] `auth.access` provisions a Cloudflare Access app + policy ([CT-3](https://procyoncreative.atlassian.net/browse/CT-3))

### Design decisions made
- **Single container**: Base image is `cloudflare/cloudflared`, entrypoint does API setup then exec's into `cloudflared tunnel run`. One service for users to add, not two.
- **Ingress config**: JSON config file with JSON Schema (not env vars) — maps 1:1 to Cloudflare API format, supports originRequest and path fields, gives IDE autocomplete via $schema
- **Schema**: Derived from cloudflared Go structs (config/configuration.go, ingress/config.go), not a hand-crafted guess. No official standalone JSON Schema exists from Cloudflare.
- **Teardown**: Not yet implemented — could be a future `DESTROY_MODE=true` env var

## Cloudflare API reference

### Tunnel
- Create tunnel: `POST /accounts/{account_id}/cfd_tunnel` with `{"name": "...", "config_src": "cloudflare"}`
- Configure ingress: `PUT /accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations`
- List tunnels: `GET /accounts/{account_id}/cfd_tunnel?name={name}&is_deleted=false`
- Get token: `GET /accounts/{account_id}/cfd_tunnel/{tunnel_id}/token`

### DNS
- Create DNS: `POST /zones/{zone_id}/dns_records` with CNAME type, proxied, pointing to `{tunnel_id}.cfargotunnel.com`
- List DNS: `GET /zones/{zone_id}/dns_records?type=CNAME&name={hostname}`
- Update DNS: `PUT /zones/{zone_id}/dns_records/{record_id}`

### WAF Custom Rules (API key auth)
- List zone rulesets: `GET /zones/{zone_id}/rulesets`
- Create ruleset: `POST /zones/{zone_id}/rulesets` with phase `http_request_firewall_custom`
- Add rule to ruleset: `POST /zones/{zone_id}/rulesets/{ruleset_id}/rules`
- Update rule: `PATCH /zones/{zone_id}/rulesets/{ruleset_id}/rules/{rule_id}`
- Expression format: `(http.host eq "...") and not (http.request.headers["authorization"][0] eq "Bearer <key>")`

### Runtime
- Run tunnel: `exec cloudflared tunnel --no-autoupdate run --token {TUNNEL_TOKEN}` (entrypoint exec's into this)

## API token permissions needed

- Account: Cloudflare Tunnel (Edit)
- Zone: DNS (Edit)
- Zone: Firewall Services (Write) — only if using API_KEY
