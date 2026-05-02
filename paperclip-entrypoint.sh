#!/bin/bash
# Paperclip entrypoint wrapper.
#
# Docker creates bind-mounted host dirs as root, but Paperclip's embedded
# Postgres refuses to run as root — so we briefly run as root to:
#   1. fix /data ownership for PAPERCLIP_UID
#   2. ensure /etc/passwd + /etc/group have an entry for PAPERCLIP_UID/GID
#      (Node's libuv calls uv_os_get_passwd() and crashes with
#       "uv_os_get_passwd returned ENOENT" if the UID isn't registered;
#       the Hermes base image only has root + hermes@10000)
# then drop to PAPERCLIP_UID/GID via setpriv and exec paperclipai "$@".
set -e

: "${PAPERCLIP_UID:=1000}"
: "${PAPERCLIP_GID:=1000}"
PAPERCLIP_USER="${PAPERCLIP_USER:-paperclip}"
PAPERCLIP_GROUP="${PAPERCLIP_GROUP:-paperclip}"

# Add group entry if PAPERCLIP_GID isn't in /etc/group yet.
if ! getent group "${PAPERCLIP_GID}" >/dev/null; then
    groupadd -g "${PAPERCLIP_GID}" "${PAPERCLIP_GROUP}"
fi

# Add user entry if PAPERCLIP_UID isn't in /etc/passwd yet.
# Without this, libuv's uv_os_get_passwd() fails with ENOENT.
if ! getent passwd "${PAPERCLIP_UID}" >/dev/null; then
    useradd -u "${PAPERCLIP_UID}" -g "${PAPERCLIP_GID}" \
        -d /data -s /bin/bash -M -N "${PAPERCLIP_USER}"
fi

chown -R "${PAPERCLIP_UID}:${PAPERCLIP_GID}" /data

# We share /opt/data with the `hermes` service so `hermes setup` config is
# visible from inside paperclip (HERMES_HOME=/opt/data in compose). For that
# to work, paperclip must be able to read/write /opt/data — i.e. its UID must
# match HERMES_UID. The hermes service also remaps to HERMES_UID at startup,
# so when both default to 1000 ownership lines up automatically.
#
# Also fix any root-owned subdirs left by accidental `docker compose exec`
# invocations (`exec` defaults to root). Quietly skip if /opt/data isn't a
# bind mount yet (first run before the hermes service has initialised it).
if [ -d /opt/data ] && [ -w /opt/data ]; then
    # Don't recursively chown — that would clobber HERMES_UID files if the
    # user deliberately set HERMES_UID != PAPERCLIP_UID. Only fix the
    # well-known subdirs hermes' Python writes from paperclipai's probe.
    for d in /opt/data/logs /opt/data/logs/curator; do
        if [ -e "$d" ] && [ ! -w "$d" ]; then
            chown -R "${PAPERCLIP_UID}:${PAPERCLIP_GID}" "$d" 2>/dev/null || true
        fi
    done
fi

# If a config already exists, force bind=lan / host=0.0.0.0 so paperclipai is
# reachable from other containers on the compose network (nginx upstream).
# This is idempotent — only the four server.* fields below are touched, so
# anything else you've configured (LLM keys, secrets, storage paths) is
# preserved. Skipped on first-run; in that case `run --bind lan` does it.
CONFIG_FILE="/data/instances/default/config.json"
if [ -f "$CONFIG_FILE" ]; then
    CONFIG_FILE="$CONFIG_FILE" PAPERCLIP_ALLOWED_HOSTS="${PAPERCLIP_ALLOWED_HOSTS:-}" \
    /usr/bin/node -e '
        const fs = require("fs");
        const file = process.env.CONFIG_FILE;
        const extra = (process.env.PAPERCLIP_ALLOWED_HOSTS || "")
            .split(",").map(s => s.trim()).filter(Boolean);
        const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
        cfg.server = cfg.server || {};
        const before = JSON.stringify(cfg.server);
        cfg.server.bind = "lan";
        cfg.server.host = "0.0.0.0";
        cfg.server.deploymentMode = "authenticated";
        const set = new Set([
            ...(cfg.server.allowedHostnames || []),
            "paperclip", "localhost", ...extra,
        ]);
        cfg.server.allowedHostnames = [...set].filter(s => s && s.length > 0);
        if (JSON.stringify(cfg.server) !== before) {
            fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
            console.log("[paperclip-entrypoint] server config patched: bind=lan host=0.0.0.0 hosts=" + cfg.server.allowedHostnames.join(","));
        } else {
            console.log("[paperclip-entrypoint] server config already correct");
        }
    ' || echo "[paperclip-entrypoint] WARN: could not patch $CONFIG_FILE — continuing"
    chown "${PAPERCLIP_UID}:${PAPERCLIP_GID}" "$CONFIG_FILE"
fi

# Default to `run --bind lan` if no command was given.
# `--bind lan` only affects FIRST-run onboarding; on subsequent runs the
# patcher above keeps the config in sync.
if [ "$#" -eq 0 ]; then
    set -- run --bind lan
fi

exec setpriv \
    --reuid="${PAPERCLIP_UID}" --regid="${PAPERCLIP_GID}" --clear-groups \
    env HOME=/data PAPERCLIP_HOME=/data HOST=0.0.0.0 \
        PAPERCLIP_TELEMETRY_DISABLED=1 DO_NOT_TRACK=1 \
        HERMES_HOME=/opt/data \
        PATH="/opt/hermes/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    paperclipai "$@"
