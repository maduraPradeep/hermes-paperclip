#!/bin/sh
# nginx entrypoint: substitute ${HERMES_DOMAIN} and ${PAPERCLIP_DOMAIN} into
# the conf templates, then either:
#   1. Wait for certs to exist (production), or
#   2. Drop the HTTPS server blocks (bootstrap mode, before certs exist),
# then exec nginx.
set -eu

: "${HERMES_DOMAIN:?HERMES_DOMAIN must be set in .env}"
: "${PAPERCLIP_DOMAIN:?PAPERCLIP_DOMAIN must be set in .env}"
: "${WORKSPACE_DOMAIN:?WORKSPACE_DOMAIN must be set in .env}"

CONF_DIR=/etc/nginx/conf.d
LE_DIR=/etc/letsencrypt/live

render_template() {
    src="$1"; dst="$2"
    sed -e "s|\${HERMES_DOMAIN}|${HERMES_DOMAIN}|g" \
        -e "s|\${PAPERCLIP_DOMAIN}|${PAPERCLIP_DOMAIN}|g" \
        -e "s|\${WORKSPACE_DOMAIN}|${WORKSPACE_DOMAIN}|g" \
        "$src" > "$dst"
}

render_template "$CONF_DIR/hermes.conf.template"    "$CONF_DIR/hermes.conf"
render_template "$CONF_DIR/paperclip.conf.template" "$CONF_DIR/paperclip.conf"
render_template "$CONF_DIR/workspace.conf.template" "$CONF_DIR/workspace.conf"

# Bootstrap mode: if Let's Encrypt certs don't exist yet, disable the HTTPS
# server blocks so nginx can still come up on :80 to serve the ACME challenge.
# init-letsencrypt.sh handles initial cert provisioning; after that, restart
# nginx (`docker compose restart nginx`) and HTTPS will activate.
if [ ! -f "$LE_DIR/$HERMES_DOMAIN/fullchain.pem" ] \
   || [ ! -f "$LE_DIR/$PAPERCLIP_DOMAIN/fullchain.pem" ] \
   || [ ! -f "$LE_DIR/$WORKSPACE_DOMAIN/fullchain.pem" ]; then
    echo "[nginx-entrypoint] certs not found — starting in HTTP-only bootstrap mode"
    echo "[nginx-entrypoint] run ./init-letsencrypt.sh, then: docker compose restart nginx"
    mv "$CONF_DIR/hermes.conf"    "$CONF_DIR/hermes.conf.disabled"
    mv "$CONF_DIR/paperclip.conf" "$CONF_DIR/paperclip.conf.disabled"
    mv "$CONF_DIR/workspace.conf" "$CONF_DIR/workspace.conf.disabled"
fi

exec nginx -g 'daemon off;'
