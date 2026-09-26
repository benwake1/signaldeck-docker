# Release test plan

Verifies a **published** image end to end, the way a new user would get it: from the registry, with this repo's compose files and `.env.example`. Run it against a new upstream release, or after changes to the Dockerfile, entrypoint or compose files.

Owner key: **C** = Claude can run it locally (arm64, Docker Desktop) · **U** = needs you (GitHub, Portainer UI, a server).

Record results in the table at the bottom.

---

## 0. Preconditions

- [ ] **U** Latest `main` build is green (GHCR + Docker Hub push).
- [ ] **C** Local `signaldeck-ci:local` image removed, so nothing is tested by accident against a local build.

## 1. Registry

- [ ] **C** Anonymous pull works from both registries: `ghcr.io/benwake1/signaldeck-ci:<ver>` and `benwake1/signaldeck-ci:<ver>`.
- [ ] **C** Both registries have the tags `<ver>`, `<major>.<minor>`, `<major>`, `latest`, and they point at the same digest.
- [ ] **C** The manifest lists `linux/amd64` and `linux/arm64`; provenance and SBOM are attached (`docker buildx imagetools inspect`).
- [ ] **C** The `org.opencontainers.image.version` label and `APP_VERSION` match the upstream tag.

## 2. Fresh install (all-in-one)

Clone this repo from GitHub (not the local working copy), `cp .env.example .env`, fill in only the *Required* and *Recommended* blocks, then `docker compose up -d`.

- [ ] **C** The stack is healthy within the 180s start period; the `signaldeck` container reaches `healthy`.
- [ ] **C** `supervisorctl status`: nginx, php-fpm, queue-cypress × `WORKER_PROCESSES`, queue-default and scheduler are all RUNNING.
- [ ] **C** Logs show migrations ran, the admin was created and an `APP_KEY` was generated; there are no PHP errors.
- [ ] **C** `/admin/login` works with `ADMIN_EMAIL` / `ADMIN_PASSWORD` in the browser.
- [ ] **C** `php artisan about` shows mysql / redis / redis / database (db, cache, queue, session) and config cached.
- [ ] **C** Restart (`docker compose restart signaldeck`):
  - the same `APP_KEY` is kept,
  - no second admin is created,
  - migrations are a no-op.

**Negative checks**

- [ ] **C** `DB_PASSWORD` unset → `docker compose up` refuses, with a clear message.
- [ ] **C** `DB_CONNECTION=sqlite` → the container exits with a clear error.
- [ ] **C** Invalid `TRUSTED_PROXIES` / `MAX_UPLOAD_SIZE` → the container exits with a clear error.

## 3. Test runs (public repos)

- [ ] **C** **Cypress** — `dummy-reporting`.
  - Expect 6 tests (3 intentional failures), screenshots and videos.
  - The report page renders.
- [ ] **C** **Playwright** — `playwright-examples`.
  - Baseline: 7 passed / 8 failed; the failures are DNS errors for the dead contosotraders demo site.
  - Suite discovery works.
- [ ] **C** Live log streams update during a run (SSE); the run finishes and its status is final.
- [ ] **C** Share link opens logged out.
  - Assets load.
  - Video seeking works (HTTP 206 range responses).
- [ ] **C** Two runs triggered together run concurrently (`WORKER_PROCESSES=3`).
- [ ] **C** Trigger a run via the API/webhook → it is queued and runs.
- [ ] **C** Schedule a suite a couple of minutes ahead → the scheduler dispatches it.
- [ ] **C** Second run of the same repo reuses the runner cache: no Cypress binary or Playwright browser re-download.

## 4. Private repo over SSH

1. **C** Create the project with the SSH URL (`git@github.com:benwake1/dummy-reporting.git`) and run a suite **before** generating a key → fails fast with `Permission denied (publickey)`, not "Host key verification failed" (host keys are pinned in `/etc/ssh/ssh_known_hosts`).
2. **C** **Generate Deploy Key** (the key is generated inside the container) and run again before adding it → same `Permission denied (publickey)`.
3. **U** Add the shown public key to the repo: Settings → Deploy keys → **read-only**.
4. **C** Run a suite.
   - The clone succeeds, the host key is accepted, and the run completes.
   - For Playwright, check project discovery as well.
5. **C** Negative check: remove the deploy key on GitHub, run again → a clean "permission denied" failure; the worker must not hang.
6. **U** Clean up: delete the deploy key from the repo when done.

## 5. Lifecycle and data

- [ ] **C** `docker compose down && docker compose up -d` keeps:
  - runs, reports, artifacts, uploaded logo and settings,
  - the logged-in session.
- [ ] **C** `up -d --force-recreate` (the upgrade path): migrations are a no-op and data is intact.
- [ ] **C** Graceful stop: start a run, then `docker compose stop`.
  - The run is allowed to finish within `WORKER_STOP_WAIT`.
  - Known upstream limitation: a run killed past the grace period stays "running".
- [ ] **C** An idle stop completes in seconds and leaves no zombie or orphaned browser processes.
- [ ] **C** Backup and restore using the exact README commands (`mysqldump` + data volume tar), into a fresh stack:
  - login works,
  - reports are present,
  - the private-repo project still runs. This proves `APP_KEY` travelled with the data volume and encrypted deploy keys decrypt.

## 6. Scaled stack

`docker compose -f docker-compose.scale.yml up -d --scale worker=2`

- [ ] **C** web, worker × 2 and scheduler are healthy; each runs only its own role's processes.
- [ ] **C** Runs execute on the worker containers; reports and artifacts are visible through web (shared volume).
- [ ] **C** Only web runs migrations; workers wait for web to be healthy.

## 7. HTTPS via Caddy (local)

`COMPOSE_PROFILES=https`, `SIGNALDECK_DOMAIN=localhost`, `APP_URL=https://localhost` (Caddy's internal CA).

- [ ] **C** HTTP → HTTPS redirect (308); generated URLs are `https://`.
- [ ] **C** Live logs stream through Caddy without buffering.
- [ ] **C** Share-link video range requests work over HTTPS.

## 8. Portainer

1. **U** Run Portainer CE locally and create its admin user:

   ```bash
   docker run -d -p 9443:9443 --name portainer -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce
   ```

2. **U/C** Stacks → Add stack → Repository (this repo, `docker-compose.yml`) with the *Required* env vars → it deploys and becomes healthy.
3. **U/C** App Templates: add the `portainer/templates.json` URL → the template deploys; the `COMPOSE_PROFILES` select (empty / https / tunnel) is honoured.
4. **U** Clean up: remove the stack, the Portainer container and the `portainer_data` volume.

## Nice to have (needs a public server)

- [ ] **U** **amd64 + Chrome:** Cypress suite with `--browser chrome` on an x86 host (CI only smoke-tests amd64).
- [ ] **U** **Real domain:** Caddy with a Let's Encrypt certificate (`sdtest.<domain>`, ports 80/443 open), and/or a Cloudflare Tunnel.

## Cleanup

- [ ] **C** `docker compose down -v` for every test stack; remove pulled test images.
- [ ] **U** Deploy key removed from the private repo.

---

## Results

| Section | Date | Image digest | Result | Notes |
|---|---|---|---|---|
| 1 Registry | | | | |
| 2 Fresh install | | | | |
| 3 Test runs | | | | |
| 4 Private repo | | | | |
| 5 Lifecycle | | | | |
| 6 Scaled | | | | |
| 7 Caddy | | | | |
| 8 Portainer | | | | |
