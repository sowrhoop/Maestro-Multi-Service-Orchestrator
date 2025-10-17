# syntax=docker/dockerfile:1.7

# Maestro Multi-Project Orchestrator container, capable of cloning
# two primary repos at build-time and bootstrapping additional
# projects at runtime under supervisord.
ARG BUILDPLATFORM
ARG TARGETPLATFORM=linux/amd64

FROM --platform=$TARGETPLATFORM debian:bookworm-slim AS base

ARG DEBIAN_FRONTEND=noninteractive

# Build args: optional repositories + refs for legacy slots
ARG SERVICE_A_REPO
ARG SERVICE_A_REF=main
ARG SERVICE_A_SUBDIR=
ARG SERVICE_A_INSTALL_CMD=

ARG SERVICE_B_REPO
ARG SERVICE_B_REF=main
ARG SERVICE_B_SUBDIR=
ARG SERVICE_B_INSTALL_CMD=

ARG PIP_INSTALL_OPTIONS=
ARG NPM_INSTALL_OPTIONS=--omit=dev --no-audit --no-fund
ARG PNPM_VERSION=8.15.5
ARG YARN_VERSION=1.22.22

# Runtime ports (can be overridden at run time)
ENV SERVICE_A_PORT=8080 \
    SERVICE_B_PORT=9090 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Common base packages
RUN --mount=type=cache,target=/var/cache/apt --mount=type=cache,target=/var/lib/apt \
    apt-get update \
 && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    python3 python3-pip python3-venv \
    nodejs npm \
    supervisor \
    git \
    bubblewrap uidmap unzip \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/projects

# Create dedicated unprivileged users for each legacy project
RUN useradd --system --uid 10001 --create-home --home-dir /home/svc_a \
        --shell /usr/sbin/nologin --no-log-init svc_a \
 && useradd --system --uid 10002 --create-home --home-dir /home/svc_b \
        --shell /usr/sbin/nologin --no-log-init svc_b

# Isolated Python venv for Project A
RUN python3 -m venv /opt/venv-a
ENV PATH=/opt/venv-a/bin:$PATH

# --- Project A: clone and install deps (legacy slot) ---
RUN if [ -n "$SERVICE_A_REPO" ]; then \
      git clone --depth=1 --branch "$SERVICE_A_REF" "$SERVICE_A_REPO" project-a; \
    fi

# Optional subdir for Project A
ENV SA_DIR=/opt/projects/project-a
RUN if [ -n "$SERVICE_A_SUBDIR" ] && [ -d "project-a/$SERVICE_A_SUBDIR" ]; then \
      mkdir -p /opt/projects && mv "project-a/$SERVICE_A_SUBDIR" "$SA_DIR" && rm -rf project-a; \
    else \
      mv project-a "$SA_DIR" 2>/dev/null || true; \
    fi

# Strip VCS metadata from Project A
RUN if [ -d "$SA_DIR/.git" ]; then rm -rf "$SA_DIR/.git"; fi

# Record resolved project name for runtime derivation
RUN if [ -d "$SA_DIR" ] && [ -n "$SERVICE_A_REPO" ]; then \
      name="${SERVICE_A_REPO##*/}"; \
      name="${name%.git}"; \
      printf '%s\n' "$name" > "$SA_DIR/.maestro-name"; \
    fi

# Install dependencies for Project A
RUN --mount=type=cache,target=/root/.cache/pip \
    set -eux; \
    if [ -d "$SA_DIR" ]; then \
      cd "$SA_DIR"; \
      if [ -n "$SERVICE_A_INSTALL_CMD" ]; then \
        /bin/sh -lc "$SERVICE_A_INSTALL_CMD"; \
      elif [ -f requirements.txt ]; then \
        pip install ${PIP_INSTALL_OPTIONS} -r requirements.txt; \
      elif [ -f pyproject.toml ] || [ -f setup.py ]; then \
        pip install ${PIP_INSTALL_OPTIONS} .; \
      else \
        echo "[INFO] Project A: no Python manifest found; skipping pip install"; \
      fi; \
    fi

# --- Project B: clone and install deps (legacy slot) ---
RUN if [ -n "$SERVICE_B_REPO" ]; then \
      git clone --depth=1 --branch "$SERVICE_B_REF" "$SERVICE_B_REPO" project-b; \
    fi

# Optional subdir for Project B
ENV SB_DIR=/opt/projects/project-b
RUN if [ -n "$SERVICE_B_SUBDIR" ] && [ -d "project-b/$SERVICE_B_SUBDIR" ]; then \
      mkdir -p /opt/projects && mv "project-b/$SERVICE_B_SUBDIR" "$SB_DIR" && rm -rf project-b; \
    else \
      mv project-b "$SB_DIR" 2>/dev/null || true; \
    fi

# Strip VCS metadata from Project B
RUN if [ -d "$SB_DIR/.git" ]; then rm -rf "$SB_DIR/.git"; fi

# Record resolved project name for runtime derivation
RUN if [ -d "$SB_DIR" ] && [ -n "$SERVICE_B_REPO" ]; then \
      name="${SERVICE_B_REPO##*/}"; \
      name="${name%.git}"; \
      printf '%s\n' "$name" > "$SB_DIR/.maestro-name"; \
    fi

# Install dependencies for Project B (Node: pnpm/yarn/npm autodetect)
ENV NODE_ENV=production
RUN --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.local/share/pnpm \
    set -eux; \
    if [ -d "$SB_DIR" ]; then \
      cd "$SB_DIR"; \
      if [ -n "$SERVICE_B_INSTALL_CMD" ]; then \
        /bin/sh -lc "$SERVICE_B_INSTALL_CMD"; \
      elif [ -f pnpm-lock.yaml ]; then \
        (corepack enable || true) && (corepack prepare pnpm@${PNPM_VERSION} --activate || npm install --global --no-audit --no-fund --loglevel=error --unsafe-perm=false pnpm@${PNPM_VERSION}) \
          && pnpm install --frozen-lockfile --prod; \
      elif [ -f yarn.lock ]; then \
        (corepack enable || true) && (corepack prepare yarn@${YARN_VERSION} --activate || npm install --global --no-audit --no-fund --loglevel=error --unsafe-perm=false yarn@${YARN_VERSION}) \
          && yarn install --frozen-lockfile --production; \
      elif [ -f package-lock.json ]; then \
        npm ci ${NPM_INSTALL_OPTIONS} || npm install ${NPM_INSTALL_OPTIONS}; \
      elif [ -f package.json ]; then \
        npm install ${NPM_INSTALL_OPTIONS}; \
      else \
        echo "[INFO] Project B: no Node manifest found; skipping install"; \
      fi; \
      npm cache clean --force || true; \
    fi

# Restrict code directories
RUN chown -R svc_a:svc_a /opt/projects/project-a 2>/dev/null || true \
 && chown -R svc_b:svc_b /opt/projects/project-b 2>/dev/null || true \
 && chmod -R 750 /opt/projects/project-a /opt/projects/project-b 2>/dev/null || true

# Supervisor config and health/entrypoint
COPY config/supervisord-main.conf /etc/supervisor/supervisord.conf
RUN ln -sf /etc/supervisor/supervisord.conf /etc/supervisord.conf
COPY healthcheck.sh /healthcheck.sh
COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/deploy-interactive.sh /usr/local/bin/deploy
COPY scripts/deploy-from-env.sh /usr/local/bin/deploy-from-env
COPY scripts/list-services.sh /usr/local/bin/list-services
COPY scripts/remove-service.sh /usr/local/bin/remove-service
COPY scripts/lib-deploy.sh /usr/local/lib/deploy/lib-deploy.sh
COPY scripts/maestro-sandbox.sh /usr/local/bin/maestro-sandbox
COPY scripts/fetch-and-extract.sh /usr/local/lib/deploy/fetch-and-extract.sh
RUN chmod +x /healthcheck.sh /entrypoint.sh \
 && chmod +x /usr/local/bin/deploy /usr/local/bin/deploy-from-env \
               /usr/local/bin/list-services /usr/local/bin/remove-service \
               /usr/local/bin/maestro-sandbox \
 && chmod 755 /usr/local/lib/deploy/lib-deploy.sh \
 && chmod 755 /usr/local/lib/deploy/fetch-and-extract.sh \
 && apt-get purge -y git \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

EXPOSE 8080 9090

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD /healthcheck.sh || exit 1

LABEL org.opencontainers.image.title="maestro multi-project orchestrator" \
      org.opencontainers.image.description="Polyglot supervisor-based runtime that bootstraps two primary repos and any number of additional projects" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/entrypoint.sh"]
