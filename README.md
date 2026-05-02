# hermes-paperclip

A single Docker image that bundles **[Hermes Agent](https://hermes-agent.nousresearch.com/)** (Nous Research) and **[Paperclip](https://docs.paperclip.ing/)** (`paperclipai`) so you can run both autonomous-agent platforms from one image.

- **Base:** `nousresearch/hermes-agent:latest` (Debian 13 trixie)
- **Node.js:** v22 (NodeSource), upgraded from Hermes' bundled Node 20
- **Paperclip:** `paperclipai` installed globally (`/usr/bin/paperclipai`)
- **Hermes:** untouched at `/opt/hermes/.venv/bin/hermes`, original `ENTRYPOINT` preserved

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the combined image |
| `docker-compose.yml` | Runs Hermes gateway + dashboard + Paperclip + nginx + certbot |
| `nginx/nginx.conf` | Top-level nginx config (TLS defaults, gzip, WebSocket map) |
| `nginx/conf.d/00-acme.conf` | Port 80: serves ACME challenge, 301s everything else to HTTPS |
| `nginx/conf.d/hermes.conf.template` | HTTPS reverse proxy → `hermes-dashboard:9119` |
| `nginx/conf.d/paperclip.conf.template` | HTTPS reverse proxy → `paperclip:3100` |
| `nginx/docker-entrypoint.sh` | Renders templates and bootstraps in HTTP-only mode if certs are missing |
| `init-letsencrypt.sh` | One-shot script to provision Let's Encrypt certs for both domains |
| `.env.example` | Template for `HERMES_DOMAIN`, `PAPERCLIP_DOMAIN`, `LE_EMAIL` |
| `README.md` | This file |

## Build

```bash
cd docker/hermes-paperclip
DOCKER_BUILDKIT=1 docker build -t hermes-paperclip:latest .
```

The Node 22 install + `npm install -g paperclipai` step is the slow one (~10–15 min on first build, faster with the BuildKit cache mount on rebuilds).

Build args you can override:

| Arg | Default | What it does |
|---|---|---|
| `NODE_MAJOR` | `22` | Node major version installed from NodeSource |
| `PAPERCLIP_VERSION` | `latest` | npm dist-tag or version of `paperclipai` |

```bash
docker build --build-arg NODE_MAJOR=20 --build-arg PAPERCLIP_VERSION=2026.428.0 \
  -t hermes-paperclip:latest .
```

## Verify

```bash
docker run --rm --entrypoint /bin/bash hermes-paperclip:latest -c '
  echo "node:        $(node -v)"
  echo "paperclipai: $(paperclipai --version)"
  /opt/hermes/.venv/bin/hermes --version
'
```

Expected:
```
node:        v22.22.2
paperclipai: 2026.428.0
Hermes Agent v0.10.0 (...)
```

## Run with docker run

The image's default `ENTRYPOINT` is Hermes' own — so any Hermes subcommand works directly:

```bash
# Hermes setup wizard (interactive)
docker run -it --rm -v ~/.hermes:/opt/data hermes-paperclip:latest setup

# Hermes gateway (OpenAI-compatible API on :8642)
docker run -d --name hermes --restart unless-stopped \
  -v ~/.hermes:/opt/data -p 8642:8642 \
  hermes-paperclip:latest gateway run

# Hermes dashboard
docker run -d --name hermes-dashboard --restart unless-stopped \
  -v ~/.hermes:/opt/data -p 9119:9119 \
  -e GATEWAY_HEALTH_URL=http://host.docker.internal:8642 \
  hermes-paperclip:latest dashboard
```

To run Paperclip instead, override the entrypoint:

```bash
# First-run Paperclip onboarding
docker run -it --rm -v ~/.paperclip:/data \
  --entrypoint paperclipai \
  hermes-paperclip:latest onboard --yes

# Paperclip API + UI on :3100 (embedded Postgres refuses root)
docker run -d --name paperclip --restart unless-stopped \
  -v ~/.paperclip:/data -p 3100:3100 \
  --user 1000:1000 \
  -e HOME=/data -e PAPERCLIP_HOME=/data -e HOST=0.0.0.0 \
  --entrypoint paperclipai \
  hermes-paperclip:latest run
```

## Run with docker compose

The bundled `docker-compose.yml` wires up five containers sharing one image:

| Container | Bound on host | Purpose |
|---|---|---|
| `hermes` | `:8642` | Hermes gateway (OpenAI-compatible) — direct host access for local SDKs |
| `hermes-dashboard` | _internal only_ | Hermes web UI, fronted by nginx |
| `paperclip` | _internal only_ | Paperclip API + UI, fronted by nginx |
| `nginx` | `:80`, `:443` | TLS termination + reverse proxy |
| `certbot` | — | Renews Let's Encrypt certs every 12h |

### One-time bootstrap with HTTPS (Let's Encrypt)

1. Point DNS for both subdomains at this host:
   ```
   hermes.example.com    A   <your-ip>
   paperclip.example.com A   <your-ip>
   ```

2. Configure environment:
   ```bash
   cp .env.example .env
   $EDITOR .env   # set HERMES_DOMAIN, PAPERCLIP_DOMAIN, LE_EMAIL
   ```

3. Initialize Hermes + Paperclip data dirs (interactive):
   ```bash
   docker compose run --rm hermes setup
   docker compose run --rm paperclip onboard --yes
   ```

4. Bring everything up. nginx starts in **HTTP-only bootstrap mode** because no certs exist yet — it serves only the ACME challenge path on `:80`:
   ```bash
   docker compose up -d
   ```

5. Provision real certs and switch nginx into HTTPS mode:
   ```bash
   ./init-letsencrypt.sh
   ```
   While iterating on DNS/firewall, set `LE_STAGING=1` in `.env` to use Let's Encrypt's staging environment (untrusted certs, no rate limits), then re-run.

6. Tell Paperclip its public hostname is allowed (only needed for Paperclip — Hermes doesn't gate by Host):
   ```bash
   docker compose exec paperclip paperclipai allowed-hostname "$PAPERCLIP_DOMAIN"
   ```

You're live:

| Service | URL |
|---|---|
| Paperclip | `https://paperclip.example.com` |
| Hermes dashboard | `https://hermes.example.com` |
| Hermes gateway (OpenAI-compatible) | `http://<host>:8642` (kept on plain HTTP for local SDK use; front it with nginx if you want it public) |

### Day-to-day

```bash
docker compose up -d             # start
docker compose down              # stop, keep data
docker compose logs -f nginx     # tail any service
docker compose pull && docker compose up -d   # update images
```

### Cert renewal

The `certbot` service runs `certbot renew` every 12h in the background. You don't need a host cron job. Force a renewal with:
```bash
docker compose exec certbot certbot renew --force-renewal
docker compose exec nginx nginx -s reload
```

### Environment variables (compose)

| Var | Default | Purpose |
|---|---|---|
| `HERMES_UID` | `1000` | Maps Hermes' in-container UID to your host user so `./data/hermes` files aren't owned by UID 10000 |
| `HERMES_GID` | `1000` | Same for GID |

Drop a `.env` next to `docker-compose.yml` if you want to pin them:

```env
HERMES_UID=1000
HERMES_GID=1000
```

## Ports

| Port | Service | Purpose |
|---|---|---|
| `3100` | Paperclip | API + UI |
| `8642` | Hermes | Gateway / OpenAI-compatible API |
| `9119` | Hermes | Dashboard web UI |

## Data layout

When using `docker-compose.yml`:

```
./data/
├── hermes/      # mounted at /opt/data inside the hermes containers
│   ├── .env
│   ├── config.yaml
│   ├── skills/
│   ├── memories/
│   └── sessions/
└── paperclip/   # mounted at /data inside the paperclip container
    ├── .paperclip/
    └── instances/
```

Both directories are stateless from the image's perspective — you can `docker compose down`, pull a newer `hermes-paperclip:latest`, and `docker compose up -d` without losing config or sessions.

## Troubleshooting

**`paperclipai` install fails with timeout during build.** The dependency graph is large (`@aws-sdk/*`, `embedded-postgres`, `drizzle-orm`, native `ws`/`sharp` addons). The Dockerfile already sets `NPM_CONFIG_FETCH_TIMEOUT=600000` and `NPM_CONFIG_FETCH_RETRIES=10` and uses a BuildKit cache mount — make sure `DOCKER_BUILDKIT=1` is set.

**`paperclipai run` errors with "postgres refuses to run as root".** Run the container as a non-root user (`--user 1000:1000` or set `user:` in compose). The bundled `docker-compose.yml` already does this.

**Files written by Hermes are owned by UID 10000 on the host.** Set `HERMES_UID` / `HERMES_GID` to your host user — Hermes' entrypoint runs `usermod`/`groupmod` then drops privileges via `gosu`.

**Image is ~9 GB.** The Hermes base alone is 8.15 GB (Playwright browsers, Python `.venv`, ffmpeg, ripgrep, `docker-cli`, etc.). To slim, fork the Hermes Dockerfile rather than overlaying it.

**`init-letsencrypt.sh` fails with "Connection refused" or "NXDOMAIN".** Let's Encrypt validates from the public internet — DNS for both `HERMES_DOMAIN` and `PAPERCLIP_DOMAIN` must resolve to this host's public IP, and ports 80/443 must be open. Test from outside: `curl -v http://hermes.example.com/.well-known/acme-challenge/_probe` should return 404 from nginx (not connection-refused).

**`init-letsencrypt.sh` hits Let's Encrypt rate limits.** You get 5 cert requests per domain per week. Set `LE_STAGING=1` in `.env` while iterating, then flip back to `0` and re-run for the real cert.

**Paperclip returns "host not allowed" after switching to a custom domain.** Run `docker compose exec paperclip paperclipai allowed-hostname <your-domain>` once.

## References

- Hermes: https://hermes-agent.nousresearch.com/ · [Docker Hub](https://hub.docker.com/r/nousresearch/hermes-agent) · [GitHub](https://github.com/NousResearch/hermes-agent)
- Paperclip: https://docs.paperclip.ing/ · [npm](https://www.npmjs.com/package/paperclipai) · [GitHub](https://github.com/paperclipai/paperclip)
- Reference image (Node-20 base, this image started from there): [MinuteCode/paperclip-hermes](https://github.com/MinuteCode/paperclip-hermes)
