#!/bin/bash
# Paperclip entrypoint wrapper.
#
# Docker creates bind-mounted host dirs as root, but Paperclip's embedded
# Postgres refuses to run as root — so we briefly run as root to fix
# /data ownership, then drop to PAPERCLIP_UID/GID via setpriv and exec
# `paperclipai` with whatever args were passed (defaults to `run`).
set -e

: "${PAPERCLIP_UID:=1000}"
: "${PAPERCLIP_GID:=1000}"

chown -R "${PAPERCLIP_UID}:${PAPERCLIP_GID}" /data

# Default to `run` if no command was given.
if [ "$#" -eq 0 ]; then
    set -- run
fi

exec setpriv \
    --reuid="${PAPERCLIP_UID}" --regid="${PAPERCLIP_GID}" --clear-groups \
    env HOME=/data PAPERCLIP_HOME=/data HOST=0.0.0.0 \
        PAPERCLIP_TELEMETRY_DISABLED=1 DO_NOT_TRACK=1 \
    paperclipai "$@"
