# Combined image that clones two repos (project-1 and project-2)
# and runs both under supervisord. Designed to avoid merging prebuilt images.

FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive

# Build args: point to your repositories and refs
ARG SERVICE_A_REPO
ARG SERVICE_A_REF=main
ARG SERVICE_A_SUBDIR=
ARG SERVICE_A_INSTALL_CMD=

ARG SERVICE_B_REPO
ARG SERVICE_B_REF=main
ARG SERVICE_B_SUBDIR=
ARG SERVICE_B_INSTALL_CMD=

# Runtime ports (can be overridden at run time)
ENV SERVICE_A_PORT=8080 \
    SERVICE_B_PORT=9090 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# Base system deps + Python + Node (Debian packages) + Supervisor
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    python3 python3-pip python3-venv \
    nodejs npm \
    git supervisor \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/services

# Create dedicated unprivileged users for each service
RUN useradd -r -u 10001 -m -d /home/svc_a -s /usr/sbin/nologin svc_a \
 && useradd -r -u 10002 -m -d /home/svc_b -s /usr/sbin/nologin svc_b

# Isolated Python venv for Service A
RUN python3 -m venv /opt/venv-a
ENV PATH=/opt/venv-a/bin:$PATH

# --- Service A: clone and install deps ---
RUN if [ -n "$SERVICE_A_REPO" ]; then \
      git clone --depth=1 --branch "$SERVICE_A_REF" "$SERVICE_A_REPO" service-a; \
    fi

# Optional subdir for Service A
ENV SA_DIR=/opt/services/service-a
RUN if [ -n "$SERVICE_A_SUBDIR" ] && [ -d "service-a/$SERVICE_A_SUBDIR" ]; then \
      mkdir -p /opt/services && mv "service-a/$SERVICE_A_SUBDIR" "$SA_DIR" && rm -rf service-a; \
    else \
      mv service-a "$SA_DIR" 2>/dev/null || true; \
    fi

# Strip VCS metadata from Service A
RUN if [ -d "$SA_DIR/.git" ]; then rm -rf "$SA_DIR/.git"; fi

# Install dependencies for Service A
RUN set -eux; \
    if [ -d "$SA_DIR" ]; then \
      cd "$SA_DIR"; \
      if [ -n "$SERVICE_A_INSTALL_CMD" ]; then \
        /bin/sh -lc "$SERVICE_A_INSTALL_CMD"; \
      elif [ -f requirements.txt ]; then \
        pip install --no-cache-dir -r requirements.txt; \
      elif [ -f pyproject.toml ]; then \
        pip install --no-cache-dir .; \
      elif [ -f setup.py ]; then \
        pip install --no-cache-dir .; \
      else \
        echo "[INFO] Service A: no Python manifest found; skipping pip install"; \
      fi; \
    fi

# --- Service B: clone and install deps ---
RUN if [ -n "$SERVICE_B_REPO" ]; then \
      git clone --depth=1 --branch "$SERVICE_B_REF" "$SERVICE_B_REPO" service-b; \
    fi

# Optional subdir for Service B
ENV SB_DIR=/opt/services/service-b
RUN if [ -n "$SERVICE_B_SUBDIR" ] && [ -d "service-b/$SERVICE_B_SUBDIR" ]; then \
      mkdir -p /opt/services && mv "service-b/$SERVICE_B_SUBDIR" "$SB_DIR" && rm -rf service-b; \
    else \
      mv service-b "$SB_DIR" 2>/dev/null || true; \
    fi

# Strip VCS metadata from Service B
RUN if [ -d "$SB_DIR/.git" ]; then rm -rf "$SB_DIR/.git"; fi

# Install dependencies for Service B (Node: pnpm/yarn/npm autodetect)
ENV NODE_ENV=production
RUN set -eux; \
    if [ -d "$SB_DIR" ]; then \
      cd "$SB_DIR"; \
      if [ -n "$SERVICE_B_INSTALL_CMD" ]; then \
        /bin/sh -lc "$SERVICE_B_INSTALL_CMD"; \
      elif [ -f pnpm-lock.yaml ]; then \
        (corepack enable || true) && (corepack prepare pnpm@latest --activate || npm i -g pnpm) \
          && pnpm install --frozen-lockfile --prod; \
      elif [ -f yarn.lock ]; then \
        (corepack enable || true) && (corepack prepare yarn@stable --activate || npm i -g yarn) \
          && yarn install --frozen-lockfile --production; \
      elif [ -f package-lock.json ]; then \
        npm ci --omit=dev || npm install --omit=dev --no-audit --no-fund; \
      elif [ -f package.json ]; then \
        npm install --omit=dev --no-audit --no-fund; \
      else \
        echo "[INFO] Service B: no Node manifest found; skipping install"; \
      fi; \
      npm cache clean --force || true; \
    fi

# Restrict code directories
RUN chown -R svc_a:svc_a /opt/services/service-a 2>/dev/null || true \
 && chown -R svc_b:svc_b /opt/services/service-b 2>/dev/null || true \
 && chmod -R 750 /opt/services/service-a /opt/services/service-b 2>/dev/null || true

# Supervisor config and health/entrypoint
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY healthcheck.sh /healthcheck.sh
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /healthcheck.sh /entrypoint.sh \
 && apt-get purge -y git \
 && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

EXPOSE 8080 9090

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 CMD /healthcheck.sh || exit 1

LABEL org.opencontainers.image.title="supervisor two-services (clone+install)" \
      org.opencontainers.image.description="Clones project-1 and project-2, installs deps, and runs both under supervisord in one container" \
      org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/entrypoint.sh"]
