#!/usr/bin/env bash
# Bootstrap Let's Encrypt certificates for HERMES_DOMAIN + PAPERCLIP_DOMAIN.
#
# Run ONCE, after DNS for both domains points at this host and `docker compose
# up -d nginx` is up in HTTP-only bootstrap mode.
#
# Usage:
#   cp .env.example .env   # set HERMES_DOMAIN, PAPERCLIP_DOMAIN, LE_EMAIL
#   docker compose up -d nginx paperclip hermes hermes-dashboard
#   ./init-letsencrypt.sh
#   docker compose restart nginx
set -euo pipefail

cd "$(dirname "$0")"

# shellcheck disable=SC1091
[ -f .env ] && set -a && . ./.env && set +a

: "${HERMES_DOMAIN:?HERMES_DOMAIN missing — set in .env}"
: "${PAPERCLIP_DOMAIN:?PAPERCLIP_DOMAIN missing — set in .env}"
: "${LE_EMAIL:?LE_EMAIL missing — set in .env (used for cert expiry notices)}"

# Set LE_STAGING=1 to use Let's Encrypt's staging environment for testing
# (avoids the 5-cert-per-week-per-domain rate limit while you're iterating).
STAGING_FLAG=""
if [ "${LE_STAGING:-0}" = "1" ]; then
    echo "[init-le] using Let's Encrypt STAGING (test certs, will not be trusted)"
    STAGING_FLAG="--staging"
fi

# Verify nginx is up and serving the ACME path.
echo "[init-le] verifying nginx ACME endpoint is reachable"
for d in "$HERMES_DOMAIN" "$PAPERCLIP_DOMAIN"; do
    if ! curl -fsS -o /dev/null "http://${d}/.well-known/acme-challenge/_probe" \
            && [ "$?" -ne 22 ]; then  # 22 = HTTP 4xx, fine — means nginx answered
        echo "[init-le] WARNING: http://${d}/.well-known/acme-challenge/ not reachable."
        echo "[init-le] Make sure DNS points at this host and 'docker compose up -d nginx' is running."
    fi
done

for DOMAIN in "$HERMES_DOMAIN" "$PAPERCLIP_DOMAIN"; do
    echo ""
    echo "[init-le] requesting cert for ${DOMAIN}"
    docker compose run --rm --entrypoint "" certbot \
        certbot certonly --webroot -w /var/www/certbot \
            --email "$LE_EMAIL" \
            --agree-tos --no-eff-email \
            --non-interactive \
            $STAGING_FLAG \
            -d "$DOMAIN"
done

echo ""
echo "[init-le] done. Reloading nginx to pick up new certs..."
docker compose restart nginx
echo "[init-le] HTTPS should now be live:"
echo "  https://${HERMES_DOMAIN}"
echo "  https://${PAPERCLIP_DOMAIN}"
