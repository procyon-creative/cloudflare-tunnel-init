# cloudflare-tunnel-init

A drop-in Docker service that automates Cloudflare Tunnel setup and runs the tunnel — no dashboard clicks, no `cloudflared login`, no browser required. Add one service to your `docker-compose.yml` and go.

## Quick start

**1. Create a Cloudflare API token** at [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) with these permissions:

| Scope   | Permission             | Access |
|---------|------------------------|--------|
| Account | Cloudflare Tunnel      | Edit   |
| Zone    | DNS                    | Edit   |

**2. Create a `.env` file:**

```env
CLOUDFLARE_API_TOKEN=your-api-token
CLOUDFLARE_ACCOUNT_ID=your-account-id
CLOUDFLARE_ZONE_ID=your-zone-id
TUNNEL_NAME=my-tunnel
```

**3. Create `tunnel-config.json`** with your hostname-to-service mappings:

```json
{
  "$schema": "./tunnel-config.schema.json",
  "ingress": [
    {
      "hostname": "app.example.com",
      "service": "http://app:8080"
    },
    {
      "service": "http_status:404"
    }
  ]
}
```

**4. Add the service** to your `docker-compose.yml`:

```yaml
services:
  cloudflared:
    image: ghcr.io/procyon-creative/cloudflare-tunnel-init:latest
    env_file: .env
    volumes:
      - ./tunnel-config.json:/config/tunnel-config.json:ro
    restart: unless-stopped
```

**5. Start it:**

```sh
docker compose up -d
```

On startup, the container creates the tunnel (or finds an existing one), configures DNS records, then runs `cloudflared` to keep the tunnel alive.

## How it works

On container start:

1. Validates `tunnel-config.json`
2. Creates a Cloudflare Tunnel via the API (or finds an existing one by name)
3. Applies ingress rules from your config
4. Creates/updates CNAME DNS records for each hostname
5. Exec's into `cloudflared tunnel run` to keep the tunnel running

Everything happens in a single container. The API setup runs once on startup, then `cloudflared` takes over as PID 1.

## Using with Lando

Add this to your `.lando.yml`:

```yaml
services:
  cloudflared:
    api: 3
    type: lando
    services:
      image: ghcr.io/procyon-creative/cloudflare-tunnel-init:latest
      environment:
        CLOUDFLARE_API_TOKEN: ${CLOUDFLARE_API_TOKEN}
        CLOUDFLARE_ACCOUNT_ID: ${CLOUDFLARE_ACCOUNT_ID}
        CLOUDFLARE_ZONE_ID: ${CLOUDFLARE_ZONE_ID}
        TUNNEL_NAME: ${TUNNEL_NAME}
      volumes:
        - ./tunnel-config.json:/config/tunnel-config.json:ro
      restart: unless-stopped
```

## Config file reference

`tunnel-config.json` defines your hostname-to-service mappings. A JSON Schema is provided at `tunnel-config.schema.json` for editor autocomplete and validation.

### Ingress rules

Each rule maps a hostname to an origin service:

| Field           | Required | Description |
|-----------------|----------|-------------|
| `hostname`      | Yes*     | Public hostname (e.g. `app.example.com`). *Omit only on the catch-all rule. |
| `service`       | Yes      | Origin URL (e.g. `http://app:8080`) or built-in like `http_status:404`. |
| `path`          | No       | Path filter with glob syntax (e.g. `/api/*`). |
| `originRequest` | No       | Per-rule origin settings (timeouts, TLS, etc). |

The last rule **must** be a catch-all with no `hostname` — this handles unmatched requests.

### Full example

```json
{
  "$schema": "./tunnel-config.schema.json",
  "ingress": [
    {
      "hostname": "app.example.com",
      "service": "http://app:8080"
    },
    {
      "hostname": "api.example.com",
      "path": "/v1/*",
      "service": "http://api:3000",
      "originRequest": {
        "connectTimeout": "60s"
      }
    },
    {
      "service": "http_status:404"
    }
  ]
}
```

### originRequest options

See the [Cloudflare origin configuration docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/origin-configuration/) for details. Supported fields:

`connectTimeout`, `tlsTimeout`, `tcpKeepAlive`, `noHappyEyeballs`, `keepAliveConnections`, `keepAliveTimeout`, `httpHostHeader`, `originServerName`, `matchSNItoHost`, `caPool`, `noTLSVerify`, `disableChunkedEncoding`, `bastionMode`, `proxyAddress`, `proxyPort`, `proxyType`, `ipRules`, `http2Origin`, `access`

## API key auth (optional)

Set `API_KEY` in your `.env` to protect your tunnel with a standard Bearer token. The container creates a Cloudflare WAF custom rule that blocks any request without the correct `Authorization: Bearer <key>` header — all auth happens at the Cloudflare edge, before traffic reaches your origin.

This works with any OpenAI-compatible client (Continue, Brave, LiteLLM, etc.) — just set the URL and API key.

To use API key auth, your API token needs one additional permission:
- Zone: Firewall Services (Write)

## Environment variables

| Variable               | Required | Default                       | Description |
|------------------------|----------|-------------------------------|-------------|
| `CLOUDFLARE_API_TOKEN` | Yes      |                               | API token with Tunnel + DNS permissions |
| `CLOUDFLARE_ACCOUNT_ID`| Yes      |                               | Cloudflare account ID |
| `CLOUDFLARE_ZONE_ID`   | Yes      |                               | Zone ID for DNS record creation |
| `TUNNEL_NAME`          | Yes      |                               | Name for the tunnel (created if it doesn't exist) |
| `CONFIG_FILE`          | No       | `/config/tunnel-config.json`  | Path to ingress config inside the container |
| `API_KEY`              | No       |                               | Bearer token for API key auth via WAF rule |

## Idempotency

Everything is safe to restart:

- **Tunnel**: Finds existing tunnel by name before creating a new one
- **DNS records**: Checks existing records, updates if the target changed, skips if already correct
- **Ingress config**: PUT replaces the full config each time
- **WAF rule**: Updates existing rule if found, creates if not

## License

MIT
