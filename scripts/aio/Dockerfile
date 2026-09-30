# syntax=docker/dockerfile:1
#
# The all-in-one image (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md).
# Built by scripts/aio.sh from a context in build/aio/, never from this
# directory. The Margince binaries and the SPA come unchanged from the role
# images of the same version; this file only packages them with PostgreSQL,
# Redis and nginx.
ARG API_IMAGE
ARG WORKER_IMAGE
ARG WEB_IMAGE

FROM ${API_IMAGE} AS api
FROM ${WORKER_IMAGE} AS worker
FROM ${WEB_IMAGE} AS web

FROM pgvector/pgvector:pg16

ARG TARGETARCH
ARG VERSION=dev

RUN apt-get update \
    && apt-get install -y --no-install-recommends tini nginx redis-server curl ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled /etc/nginx/conf.d \
    && useradd --system --uid 10001 --user-group --home-dir /app --no-create-home app \
    && mkdir -p /app/secrets /etc/margince \
    && chown -R app:app /app

COPY --from=api /usr/local/bin/margince-api /usr/local/bin/margince-migrate /usr/local/bin/
COPY --from=api /usr/local/bin/entrypoint.sh /usr/local/bin/margince-api-entrypoint
COPY --from=worker /usr/local/bin/margince-worker /usr/local/bin/
COPY --from=worker /usr/local/bin/entrypoint.sh /usr/local/bin/margince-worker-entrypoint
COPY --from=web /usr/share/nginx/html /usr/share/margince/web
COPY --from=api /etc/margince/release-version /etc/margince/release-version

COPY nginx.conf /etc/nginx/nginx.conf
COPY margince.yaml /etc/margince/margince.yaml
COPY db-bootstrap.sql /usr/share/margince/db-bootstrap.sql
COPY --chmod=0755 margince-init margince-seed margince-logins /usr/local/bin/

# The seeder and the dataset, when the build included them (Section 7.2).
COPY seed/ /tmp/seed/
RUN if [ -f "/tmp/seed/seed-demo-${TARGETARCH}" ]; then \
      install -m 0755 "/tmp/seed/seed-demo-${TARGETARCH}" /usr/local/bin/seed-demo; \
    fi \
    && rm -rf /tmp/seed
COPY demo/ /opt/margince/demo/
RUN if [ ! -x /usr/local/bin/seed-demo ]; then rm -rf /opt/margince/demo; fi

LABEL org.opencontainers.image.version="${VERSION}"

EXPOSE 80
VOLUME ["/data"]
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=10s --timeout=5s --start-period=600s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:8080/readyz || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/margince-init"]
CMD []
