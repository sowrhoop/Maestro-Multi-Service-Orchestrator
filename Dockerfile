# syntax=docker/dockerfile:1.7

ARG BUILDPLATFORM
ARG TARGETPLATFORM=linux/amd64

FROM --platform=$TARGETPLATFORM debian:bookworm-slim AS base

ARG DEBIAN_FRONTEND=noninteractive

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    PIP_INSTALL_OPTIONS= \
    NPM_INSTALL_OPTIONS="--omit=dev --no-audit --no-fund" \
    PNPM_VERSION=8.15.5 \
    YARN_VERSION=1.22.22

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

RUN --mount=type=cache,target=/var/cache/apt --mount=type=cache,target=/var/lib/apt \
    apt-get update \
 && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    python3 python3-pip python3-venv \
    nodejs npm \
    supervisor \
    git \
    bubblewrap uidmap unzip iptables iproute2 \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/projects

COPY config/supervisord-main.conf /etc/supervisor/supervisord.conf
RUN ln -sf /etc/supervisor/supervisord.conf /etc/supervisord.conf

COPY healthcheck.sh /healthcheck.sh
COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/deploy-interactive.sh /usr/local/bin/deploy
COPY scripts/deploy-from-env.sh /usr/local/bin/deploy-from-env
COPY scripts/list-services.sh /usr/local/bin/list-services
COPY scripts/remove-project.sh /usr/local/bin/remove-service
COPY scripts/remove-project.sh /usr/local/bin/remove-project
COPY scripts/lib-deploy.sh /usr/local/lib/deploy/lib-deploy.sh
COPY scripts/maestro-sandbox.sh /usr/local/bin/maestro-sandbox
COPY scripts/fetch-and-extract.sh /usr/local/lib/deploy/fetch-and-extract.sh

RUN chmod +x /healthcheck.sh /entrypoint.sh \
 && chmod +x /usr/local/bin/deploy /usr/local/bin/deploy-from-env \
               /usr/local/bin/list-services \
               /usr/local/bin/remove-service /usr/local/bin/remove-project \
               /usr/local/bin/maestro-sandbox \
 && chmod 755 /usr/local/lib/deploy/lib-deploy.sh \
 && chmod 755 /usr/local/lib/deploy/fetch-and-extract.sh \
 && apt-get purge -y git \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD /healthcheck.sh || exit 1

LABEL org.opencontainers.image.title="maestro multi-project orchestrator" \
      org.opencontainers.image.description="Polyglot supervisor-based runtime for orchestrating multiple services under supervisord" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/entrypoint.sh"]
