FROM caddy:2.11.7-builder AS builder
ARG CADDY_DNS_MODULE
RUN test -n "$CADDY_DNS_MODULE" \
    && xcaddy build v2.11.7 --with "$CADDY_DNS_MODULE"
FROM caddy:2.11.7
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
