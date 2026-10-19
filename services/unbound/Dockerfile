FROM debian:13.1-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends unbound dns-root-data ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -o unbound -g unbound /var/lib/unbound \
    && cp /usr/share/dns/root.key /var/lib/unbound/root.key \
    && chown unbound:unbound /var/lib/unbound/root.key
COPY unbound.conf /etc/unbound/unbound.conf
USER unbound
EXPOSE 5335/tcp 5335/udp
CMD ["unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
