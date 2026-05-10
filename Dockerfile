# Combined image: Hermes Agent (NousResearch) + Paperclip (paperclipai)
#
# Starts from the official Hermes image, upgrades Node.js from Debian's
# bundled 18.x to Node 22 (NodeSource), enables pnpm via corepack
# (paperclipai requires pnpm >= 9.15), and globally installs the
# paperclipai npm package so the `paperclipai` CLI is on PATH.
#
# Hermes' original ENTRYPOINT is preserved, so this image keeps full
# Hermes behaviour (`docker run ... <image> setup|gateway run|dashboard|...`).
# To run Paperclip instead, override the entrypoint, e.g.:
#   docker run --rm -it --entrypoint paperclipai <image> onboard --yes
FROM nousresearch/hermes-agent:latest

# Hermes' Dockerfile leaves the image as root so its entrypoint can
# usermod/groupmod and drop privileges with gosu. We follow the same
# convention here.
USER root

ARG NODE_MAJOR=22
ARG PAPERCLIP_VERSION=latest

ENV DEBIAN_FRONTEND=noninteractive \
    PNPM_HOME=/usr/local/share/pnpm \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_LOGLEVEL=info \
    NPM_CONFIG_FETCH_RETRIES=10 \
    NPM_CONFIG_FETCH_RETRY_MINTIMEOUT=20000 \
    NPM_CONFIG_FETCH_RETRY_MAXTIMEOUT=180000 \
    NPM_CONFIG_FETCH_TIMEOUT=600000 \
    NPM_CONFIG_MAXSOCKETS=20
ENV PATH=$PNPM_HOME:$PATH

# Step 1: replace Debian-bundled Node/npm with NodeSource Node ${NODE_MAJOR}.x.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    apt-get purge -y --auto-remove nodejs npm libnode-dev libnode109 || true; \
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends nodejs; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    node -v; npm -v

# Step 2: enable pnpm (paperclipai requires pnpm for some workflows).
RUN set -eux; \
    corepack enable; \
    corepack prepare pnpm@latest --activate; \
    pnpm -v

# Step 3: install paperclipai globally. paperclipai pulls in a deep
# dep graph (@aws-sdk/*, embedded-postgres, drizzle-orm, ws native
# addons, sharp, etc.); on slower disks/networks the default npm
# fetch settings can hit transient timeouts. We use a BuildKit cache
# mount for /root/.npm so retries are fast, and dump the npm debug
# log on failure so the cause is visible in build output.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    set -eux; \
    if ! npm install -g "paperclipai@${PAPERCLIP_VERSION}"; then \
      echo "==== paperclipai install FAILED — dumping last 400 lines of npm debug log ===="; \
      tail -n 400 /root/.npm/_logs/*-debug-0.log || true; \
      echo "==== first 100 lines ===="; \
      head -n 100 /root/.npm/_logs/*-debug-0.log || true; \
      exit 1; \
    fi; \
    which paperclipai; \
    paperclipai --version || true; \
    rm -rf /tmp/*

# Make the npm global lib + bin world-readable so any HERMES_UID can
# resolve `paperclipai` at runtime (matches Hermes' chmod -R a+rX /opt/hermes).
# PNPM_HOME may be empty if we never `pnpm add -g`'d anything — chmod only
# the dirs that actually exist.
RUN set -eux; \
    chmod -R a+rX /usr/lib/node_modules /usr/bin/node /usr/bin/npm /usr/bin/npx; \
    [ -d "$PNPM_HOME" ] && chmod -R a+rX "$PNPM_HOME" || true

# Symlink the hermes CLI into /usr/local/bin so it resolves on the default
# PATH for any user — Hermes' own entrypoint normally adds /opt/hermes/.venv/bin
# to PATH, but processes that bypass that entrypoint (paperclip, direct
# `docker exec`) wouldn't find it otherwise. Paperclip's version probe
# (`hermes --version`) needs this.
RUN ln -sf /opt/hermes/.venv/bin/hermes /usr/local/bin/hermes \
    && /usr/local/bin/hermes --version 2>&1 | head -1

# Pre-build the hermes dashboard web UI at image-build time (as root).
# The dashboard command always runs `npm install && npm run build` on startup;
# this pre-populates node_modules and web_dist so the runtime build is fast.
# We also make the entire web/ tree world-writable because the container
# entrypoint remaps the hermes user from UID 10000 to the host UID, and
# the remapped user can't write to directories owned by the original UID 10000.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    set -eux; \
    cd /opt/hermes/web; \
    npm install --prefer-offline --no-audit; \
    npm run build; \
    chmod -R a+w /opt/hermes/web /opt/hermes/hermes_cli/web_dist

# Paperclip's API server defaults to :3100; Hermes uses 8642 (gateway)
# and 9119 (dashboard). Document them all.
EXPOSE 3100 8642 9119

# Inherit Hermes' ENTRYPOINT (tini -> /opt/hermes/docker/entrypoint.sh).
# No CMD override; Hermes' default behaviour is preserved.
