FROM cloudflare/cloudflared:latest AS cloudflared

FROM alpine:3.21

RUN apk add --no-cache curl jq openssl

COPY --from=cloudflared /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
