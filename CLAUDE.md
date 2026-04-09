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

### Phase 4: Cloudflare Access auth — Done
- [x] If `ACCESS_ENABLED=true`, create a Cloudflare Access self-hosted application for each hostname
- [x] Create a service token via API, persist client_id and client_secret to `/shared/access-credentials.json`
- [x] Create a non_identity policy requiring the service token
- [x] Attach policy to the Access application
- [x] Idempotent: checks credentials file first, finds existing app/token/policy by name, rotates token if credentials file lost
- [x] All via API — no dashboard interaction, no manual steps

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

### Cloudflare Access (for future auth feature)
- Create service token: `POST /accounts/{account_id}/access/service_tokens` with `{"name": "...", "duration": "8760h"}` — **client_secret is only returned once**, must be persisted to file immediately
- Create reusable policy: `POST /accounts/{account_id}/access/policies` with `{"name": "...", "decision": "non_identity", "include": [{"service_token": {"token_id": "..."}}]}`
- Create self-hosted app: `POST /accounts/{account_id}/access/apps` with `{"name": "...", "type": "self_hosted", "domain": "...", "policies": [{"id": "...", "precedence": 1}]}`
- Client auth headers: `CF-Access-Client-Id` and `CF-Access-Client-Secret`

### Runtime
- Run tunnel: `exec cloudflared tunnel --no-autoupdate run --token {TUNNEL_TOKEN}` (entrypoint exec's into this)

## API token permissions needed

- Account: Cloudflare Tunnel (Edit)
- Zone: DNS (Edit)
- Account: Access: Apps and Policies (Edit) — only if using Access auth
- Account: Access: Service Tokens (Edit) — only if using Access auth
