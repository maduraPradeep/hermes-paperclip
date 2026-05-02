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

# Default to `run` if no command was given.
if [ "$#" -eq 0 ]; then
    set -- run
fi

exec setpriv \
    --reuid="${PAPERCLIP_UID}" --regid="${PAPERCLIP_GID}" --clear-groups \
    env HOME=/data PAPERCLIP_HOME=/data HOST=0.0.0.0 \
        PAPERCLIP_TELEMETRY_DISABLED=1 DO_NOT_TRACK=1 \
    paperclipai "$@"
