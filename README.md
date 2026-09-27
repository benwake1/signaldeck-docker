# SignalDeck CI — Docker

The self-hosted Docker image for [SignalDeck CI](https://github.com/benwake1/signaldeck-ci-server), a Cypress & Playwright test dashboard: trigger suites from a web UI, watch live output, generate branded client reports and schedule runs.

One image contains everything: PHP 8.4, Nginx, Node, Google Chrome, Xvfb and the Playwright system libraries. The stack adds MySQL and Redis. No bare-metal setup required.

```
ghcr.io/benwake1/signaldeck-ci:<version>     # GitHub Container Registry
benwake1/signaldeck-ci:<version>             # Docker Hub
```

Both registries carry the same multi-arch images (amd64 + arm64). Tags follow upstream releases: `1.2.4`, `1.2`, `1`, `latest`. The compose files use GHCR by default; set `SIGNALDECK_IMAGE=benwake1/signaldeck-ci` to pull from Docker Hub instead.

---

## Quick start (Docker Compose)

```bash
git clone https://github.com/benwake1/signaldeck-docker.git
cd signaldeck-docker
cp .env.example .env
```

Edit `.env` — at minimum set `APP_URL`, `DB_PASSWORD`, `DB_ROOT_PASSWORD`, `REDIS_PASSWORD`, `ADMIN_EMAIL` and `ADMIN_PASSWORD` (`openssl rand -hex 24` makes good secrets). Then:

```bash
docker compose up -d
docker compose logs -f signaldeck
```

Open `http://<host>:8080/admin` and sign in with the admin account. To serve it on a domain with HTTPS, see [Connecting via a domain](#connecting-via-a-domain). First boot takes a minute or two while migrations run.

## Portainer

**Stacks → Add stack → Repository**

- Repository URL: `https://github.com/benwake1/signaldeck-docker`
- Compose path: `docker-compose.yml`
- Environment variables: the values from `.env.example` (at minimum the *Required* block)

Or add `https://raw.githubusercontent.com/benwake1/signaldeck-docker/main/portainer/templates.json` under **Settings → App Templates** to get a one-click *SignalDeck CI* template.

---

## Architecture

| Service | Purpose | Volume |
|---|---|---|
| `signaldeck` | Web UI + API, queue workers, scheduler | `signaldeck-data`, `signaldeck-runner-cache` |
| `mysql` | Application database (MySQL 8.4) | `signaldeck-mysql` |
| `redis` | Queue and cache (AOF-persisted, no eviction) | `signaldeck-redis` |

Inside the `signaldeck` container Supervisor runs:

- **nginx + php-fpm** — the web UI, REST API and live-log streams (SSE)
- **queue-cypress** × `WORKER_PROCESSES` — one test run per process
- **queue-default** — email, Slack and other notifications
- **scheduler** — cron-scheduled suites, artifact cleanup, event pruning

### Volumes

| Volume | Contents | Back up? |
|---|---|---|
| `signaldeck-data` | Reports, screenshots, videos, uploaded logos, generated `APP_KEY` | **Yes** |
| `signaldeck-mysql` | Database | **Yes** (prefer `mysqldump`) |
| `signaldeck-redis` | Queued jobs | Optional |
| `signaldeck-runner-cache` | Cypress binaries, Playwright browsers, npm cache | No — rebuilt on demand |

Configure S3 in the app's **Settings** to keep artifacts off local disk.

### Scaling

`docker-compose.scale.yml` runs the same image as separate `web`, `worker` and `scheduler` services, so test capacity scales independently:

```bash
docker compose -f docker-compose.scale.yml up -d --scale worker=3
```

Each worker container runs `WORKER_PROCESSES` concurrent test runs. Plan on roughly 1–2 GB RAM and one CPU per concurrent run.

Roles can also be selected directly: `command: web | worker | scheduler | all` (or `SIGNALDECK_ROLE`).

---

## Configuration

Mail, Google SSO, Slack, S3 storage and branding are configured in the app under **Settings** and stored in the database. The environment only covers infrastructure:

| Variable | Default | Notes |
|---|---|---|
| `APP_URL` | — | **Required.** Public URL, used for links, emails and SSO callbacks |
| `DB_PASSWORD` / `DB_ROOT_PASSWORD` | — | **Required** |
| `REDIS_PASSWORD` | — | **Required** |
| `APP_KEY` | generated | Encrypts stored secrets. If empty, generated on first boot into `signaldeck-data/.signaldeck/app.key`. **Back it up.** |
| `ADMIN_EMAIL` / `ADMIN_PASSWORD` / `ADMIN_NAME` | — | Creates the first admin on first boot only |
| `HTTP_PORT` / `HTTP_BIND` | `8080` / `0.0.0.0` | Published web port |
| `TRUSTED_PROXIES` | private ranges | Proxies allowed to set `X-Forwarded-For`. Add `cloudflare` for Cloudflare's proxy ranges (built into the image, refreshed weekly); `*` trusts all |
| `WORKER_PROCESSES` | `3` | Concurrent test runs per container |
| `CYPRESS_JOB_TIMEOUT` | `10800` | Max seconds per run. Worker timeout and queue retry window are derived from it |
| `WORKER_STOP_WAIT` / `STOP_GRACE_PERIOD` | `900` / `16m` | How long in-flight runs get to finish on stop/redeploy |
| `PHP_FPM_MAX_CHILDREN` | `30` | Each open live-log view holds one PHP worker |
| `MAX_UPLOAD_SIZE` | `100M` | Nginx + PHP upload limit |
| `SIGNALDECK_THEME` | `signaldeck` | Dark SignalDeck theme for the admin panel; `default` for the standard light/dark theme. Colours and logo are still set under **Settings → Branding** |
| `LOG_LEVEL` | `warning` | Logs go to `docker logs` |
| `SIGNALDECK_TAG` | `latest` | Pin a version in production |

Only MySQL/MariaDB and Redis are supported; the container refuses to start with other database drivers.

## Connecting via a domain

SignalDeck needs to know its public address: set `APP_URL` to exactly what users type, e.g. `https://sdtest.example.com` or `https://example.com`. It's used for links, emails, shared report URLs and SSO callbacks.

Then pick how traffic reaches the container:

### Option A — built-in Caddy (automatic HTTPS)

Best for a VPS or any server with a public IP.

1. Create a DNS record: `sdtest.example.com  A  <server IP>` (a root domain works the same way).
2. Open ports **80** and **443** to the server (80 is needed for the Let's Encrypt challenge and HTTP→HTTPS redirect).
3. Set:
   ```env
   COMPOSE_PROFILES=https
   SIGNALDECK_DOMAIN=sdtest.example.com
   APP_URL=https://sdtest.example.com
   HTTP_BIND=127.0.0.1
   ```
4. `docker compose up -d` — the certificate is issued on first start and renewed automatically.

Using Cloudflare's proxy (orange cloud)?

- Set SSL/TLS mode to **Full (strict)**; Caddy's certificate is trusted.
- Add `cloudflare` to `TRUSTED_PROXIES` so the app sees visitors' real IPs rather than Cloudflare's (login rate limits are per IP):
  ```env
  TRUSTED_PROXIES=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.1,::1,cloudflare
  ```
- Cloudflare limits uploads to 100 MB on the Free and Pro plans, whatever `MAX_UPLOAD_SIZE` says.

Ports 80/443 already used by another web server on this machine? Use [Option C](#option-c--your-existing-reverse-proxy) (proxy through it) or [Option B](#option-b--cloudflare-tunnel-no-open-ports) (Cloudflare Tunnel) instead — Let's Encrypt needs the standard ports.

### Option B — Cloudflare Tunnel (no open ports)

Best for home labs, NAS boxes and servers behind NAT.

1. Cloudflare Zero Trust → Networks → Tunnels → create a tunnel (Docker connector) and copy its token.
2. Add a public hostname: `sdtest.example.com` → service `http://signaldeck:80` (`http://web:80` for the scaled stack).
3. Set:
   ```env
   COMPOSE_PROFILES=tunnel
   CLOUDFLARE_TUNNEL_TOKEN=<token>
   APP_URL=https://sdtest.example.com
   HTTP_BIND=127.0.0.1
   ```

### Option C — your existing reverse proxy

Traefik, Nginx Proxy Manager, host Nginx/Apache, etc. Proxy to the container's HTTP port (`HTTP_PORT`, default 8080) and set `APP_URL` to the `https://` address. The proxy must:

- send `X-Forwarded-Proto` and `X-Forwarded-For` (most do by default),
- not buffer `/api/v1/test-runs/*/stream` — live logs use Server-Sent Events (`proxy_buffering off;` in Nginx),
- allow uploads up to `MAX_UPLOAD_SIZE` (`client_max_body_size 100M;` in Nginx).

If the proxy isn't on a private network address, add its IP to `TRUSTED_PROXIES`. If Cloudflare's proxy sits in front of it, add `cloudflare` as well, and make sure your proxy passes the incoming `X-Forwarded-For` on rather than replacing it.

In Portainer, put `COMPOSE_PROFILES`, `SIGNALDECK_DOMAIN` / `CLOUDFLARE_TUNNEL_TOKEN` in the stack's environment variables alongside the others.

## Upgrading

```bash
docker compose pull
docker compose up -d
```

Migrations run automatically on start. Test runs that are in progress get `WORKER_STOP_WAIT` seconds to finish before the old container stops.

## Backups

```bash
docker compose exec -T mysql sh -c 'mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction signaldeck' > signaldeck.sql
docker run --rm -v signaldeck_signaldeck-data:/data -v "$PWD":/backup alpine tar czf /backup/signaldeck-data.tgz -C /data .
```

The data archive includes the generated `APP_KEY` (if you didn't set one), which is needed to decrypt stored settings and deploy keys — keep both files together. The volume name is prefixed with your stack/project name (`docker volume ls`).

### Restoring

Into a new, empty stack (new passwords in `.env` are fine):

```bash
docker compose up -d --wait mysql redis
docker compose exec -T mysql sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD" signaldeck' < signaldeck.sql
docker compose create signaldeck
docker run --rm -v signaldeck_signaldeck-data:/data -v "$PWD":/backup alpine tar xzf /backup/signaldeck-data.tgz -C /data
docker compose up -d
```

Restore the database **before** the app's first start, otherwise it migrates an empty database. If `APP_KEY` is set in the old `.env`, copy it across.

## Useful commands

```bash
docker compose exec -u www-data signaldeck php artisan make:admin        # create/promote an admin
docker compose exec -u www-data signaldeck php artisan about
docker compose exec signaldeck supervisorctl status                       # process status
```

## Notes

- **Architecture:** `linux/amd64` and `linux/arm64`. Google Chrome is only available on amd64; on arm64 Cypress runs in its bundled Electron browser and Playwright uses its own Chromium.
- **Security:** test suites execute the code in the repositories you add, inside the worker container, which has access to the app's database credentials. Only add repositories you trust.
- **Shared memory:** the compose files set `shm_size: 2gb`. If you run the image some other way, do the same (`--shm-size=2g`), or browsers will crash on larger pages.

## Building locally

```bash
docker build --build-arg SIGNALDECK_VERSION=v1.2.4 -t signaldeck-ci:local .
```

Build arguments: `SIGNALDECK_VERSION` (upstream tag), `SIGNALDECK_REPO`, `NODE_MAJOR`, `CHROME_VERSION` (pin a Chrome build), `PLAYWRIGHT_DEPS_VERSION`.

## License

MIT
