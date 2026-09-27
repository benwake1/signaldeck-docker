# syntax=docker/dockerfile:1.7
#
# SignalDeck CI — self-hosted image
#
# Packages an upstream release of https://github.com/benwake1/signaldeck-ci-server
# together with everything needed to run Cypress and Playwright suites:
# PHP 8.4 (FPM + CLI), Nginx, Node, Google Chrome (amd64), Xvfb and the
# Playwright system libraries. Supervisor runs the web server, queue workers
# and scheduler — all of them, or a single role (see SIGNALDECK_ROLE).
#
# Build:  docker build --build-arg SIGNALDECK_VERSION=v1.2.4 -t signaldeck-ci .

FROM ubuntu:24.04

ARG TARGETARCH
ARG NODE_MAJOR=24
# Pin the Chrome build (e.g. 140.0.7339.207) for reproducible images.
# Empty = current stable at build time. Ignored on arm64 (no Chrome build exists).
ARG CHROME_VERSION=""
ARG PLAYWRIGHT_DEPS_VERSION=1.63.0
# Changing this invalidates the build cache from the first layer, so OS
# packages, Chrome and SSH host keys are refreshed. CI sets it to the ISO week.
ARG CACHE_EPOCH=""

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=C.UTF-8

# ─────────────────────────────────────────────────────────────────────────────
# Base system
# ─────────────────────────────────────────────────────────────────────────────
RUN echo "cache epoch: ${CACHE_EPOCH:-none}" \
    && apt-get update && apt-get upgrade -y && apt-get install -y \
        software-properties-common \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssh-client \
        unzip \
        zip \
        tini \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────────
# SSH host keys for the common Git hosts, from each provider's published
# source rather than trust-on-first-use. Without them a project with an SSH
# URL but no deploy key fails with a misleading "Host key verification
# failed" instead of "Permission denied (publickey)".
# GitLab has no key endpoint: scanned keys must match its documented
# fingerprints, otherwise the build fails.
# The optional github_token build secret avoids GitHub's 60-requests-an-hour
# limit for anonymous API calls (shared CI runners hit it); it isn't stored
# in the image.
# ─────────────────────────────────────────────────────────────────────────────
RUN --mount=type=secret,id=github_token,required=false \
    set -eu \
    && auth="" \
    && if [ -s /run/secrets/github_token ]; then auth="Authorization: Bearer $(cat /run/secrets/github_token)"; fi \
    && curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 ${auth:+-H "$auth"} https://api.github.com/meta \
        | grep -oE '"(ssh-[a-z0-9-]+|ecdsa-[a-z0-9-]+) [A-Za-z0-9+/=]+"' \
        | tr -d '"' | sed 's/^/github.com /' > /tmp/known_hosts \
    && [ "$(grep -c '^github.com ' /tmp/known_hosts)" -ge 3 ] \
    && curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 https://bitbucket.org/site/ssh | grep '^bitbucket.org ' >> /tmp/known_hosts \
    && ssh-keyscan -t ed25519,ecdsa,rsa gitlab.com 2>/dev/null > /tmp/gitlab \
    && ssh-keygen -lf /tmp/gitlab | awk '{print $2}' | sort > /tmp/gitlab.fp \
    && printf '%s\n' \
        SHA256:HbW3g8zUjNSksFbqTiUWPWg2Bq1x8xdGUrliXFzSnUw \
        SHA256:ROQFvPThGrW4RuWLoL9tq9I9zJ42fK4XywyRtbOz/EQ \
        SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8 \
        | sort | diff - /tmp/gitlab.fp \
    && cat /tmp/gitlab >> /tmp/known_hosts \
    && install -m 0644 /tmp/known_hosts /etc/ssh/ssh_known_hosts \
    && rm -f /tmp/known_hosts /tmp/gitlab /tmp/gitlab.fp \
    && ssh-keygen -lf /etc/ssh/ssh_known_hosts

# Cloudflare's published proxy ranges, for TRUSTED_PROXIES=...,cloudflare.
# Refreshed on the weekly rebuild (CACHE_EPOCH).
RUN set -eu \
    && mkdir -p /usr/local/lib/signaldeck \
    && { curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 https://www.cloudflare.com/ips-v4; echo; curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 https://www.cloudflare.com/ips-v6; echo; } \
        | grep -E '^[0-9A-Fa-f:.]+/[0-9]+$' > /usr/local/lib/signaldeck/cloudflare-ips \
    && [ "$(wc -l < /usr/local/lib/signaldeck/cloudflare-ips)" -ge 10 ] \
    && cat /usr/local/lib/signaldeck/cloudflare-ips

# ─────────────────────────────────────────────────────────────────────────────
# PHP 8.4 (Ondřej Surý PPA), Nginx, Supervisor
# MySQL + Redis only — SQLite is intentionally not supported.
# ─────────────────────────────────────────────────────────────────────────────
RUN add-apt-repository -y ppa:ondrej/php \
    && apt-get update && apt-get install -y \
        php8.4-fpm \
        php8.4-cli \
        php8.4-opcache \
        php8.4-mysql \
        php8.4-redis \
        php8.4-gd \
        php8.4-xml \
        php8.4-mbstring \
        php8.4-zip \
        php8.4-curl \
        php8.4-bcmath \
        php8.4-intl \
        nginx \
        supervisor \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────────
# Headless browser dependencies (Cypress + Playwright)
# xvfb-run is detected at runtime by RunCypressTestJob.
# ─────────────────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
        xvfb \
        xauth \
        libgtk-3-0t64 \
        libnotify-dev \
        libnss3 \
        libxss1 \
        libasound2t64 \
        libxtst6 \
        libgbm-dev \
        libdrm2 \
        libxkbcommon0 \
        libpango-1.0-0 \
        libcairo2 \
        libatk1.0-0 \
        libatk-bridge2.0-0 \
        libcups2 \
        libxrandr2 \
        libxcomposite1 \
        libxdamage1 \
        libxfixes3 \
        libdbus-1-3 \
        libnspr4 \
        fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────────────────────────────────────────
# Google Chrome stable — amd64 only. On arm64 Cypress falls back to its
# bundled Electron browser and Playwright uses its own Chromium build.
# ─────────────────────────────────────────────────────────────────────────────
RUN if [ "${TARGETARCH}" = "amd64" ]; then \
        if [ -n "${CHROME_VERSION}" ]; then \
            url="https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_${CHROME_VERSION}-1_amd64.deb"; \
        else \
            url="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; \
        fi \
        && apt-get update \
        && curl -fsSL "${url}" -o /tmp/google-chrome.deb \
        && apt-get install -y /tmp/google-chrome.deb \
        && rm -f /tmp/google-chrome.deb \
        && rm -rf /var/lib/apt/lists/* \
        && google-chrome-stable --version; \
    else \
        echo "Skipping Google Chrome on ${TARGETARCH}"; \
    fi

# ─────────────────────────────────────────────────────────────────────────────
# Node.js (NodeSource)
# ─────────────────────────────────────────────────────────────────────────────
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# Playwright OS packages only — browser binaries are installed per run by
# RunPlaywrightTestJob and cached in the runner-cache volume.
RUN npx -y "playwright@${PLAYWRIGHT_DEPS_VERSION}" install-deps \
    && rm -rf /var/lib/apt/lists/* /root/.npm

COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# ─────────────────────────────────────────────────────────────────────────────
# Application — pinned upstream release tag
# ─────────────────────────────────────────────────────────────────────────────
ARG SIGNALDECK_REPO=https://github.com/benwake1/signaldeck-ci-server.git
ARG SIGNALDECK_VERSION=v1.2.4

RUN git clone --depth 1 --branch "${SIGNALDECK_VERSION}" "${SIGNALDECK_REPO}" /var/www/app \
    && rm -rf /var/www/app/.git

WORKDIR /var/www/app

RUN COMPOSER_ALLOW_SUPERUSER=1 composer install \
        --no-dev \
        --no-interaction \
        --no-progress \
        --no-scripts \
        --optimize-autoloader \
    && rm -rf /root/.composer/cache

RUN npm ci --no-audit --no-fund \
    && npm run build \
    && rm -rf node_modules /root/.npm

# Remove bare-metal tooling that doesn't apply inside the container
RUN rm -f deploy.sh install.sh install-existing-lemp.sh .env .env.example

# ─────────────────────────────────────────────────────────────────────────────
# Runtime user, directories and config
# ─────────────────────────────────────────────────────────────────────────────
COPY rootfs/ /

RUN usermod -d /var/www www-data \
    && mkdir -p /var/www/.cache /var/www/.ssh /run/php /run/signaldeck \
    && chmod 700 /var/www/.ssh \
    && chown -R www-data:www-data /var/www \
    && rm -f /etc/nginx/sites-enabled/default /etc/php/8.4/fpm/pool.d/www.conf \
    && sed -i 's|^;*error_log = .*|error_log = /proc/self/fd/2|' /etc/php/8.4/fpm/php-fpm.conf \
    && chmod +x /usr/local/bin/signaldeck-entrypoint /usr/local/bin/signaldeck-healthcheck /usr/local/lib/signaldeck/graceful-worker \
    && if [ "${TARGETARCH}" = "amd64" ]; then \
         install -m 0755 /usr/local/lib/signaldeck/chrome-cypress /usr/local/bin/chrome-cypress; \
       fi

# Defaults — override at runtime. Mail, SSO, Slack and S3 are configured
# in the app's Settings pages and stored in the database.
ENV APP_NAME="SignalDeck CI" \
    APP_ENV=production \
    APP_DEBUG=false \
    APP_VERSION=${SIGNALDECK_VERSION} \
    LOG_CHANNEL=stderr \
    LOG_LEVEL=warning \
    DB_CONNECTION=mysql \
    DB_HOST=mysql \
    DB_PORT=3306 \
    DB_DATABASE=signaldeck \
    DB_USERNAME=signaldeck \
    REDIS_CLIENT=phpredis \
    REDIS_HOST=redis \
    REDIS_PORT=6379 \
    CACHE_STORE=redis \
    QUEUE_CONNECTION=redis \
    SESSION_DRIVER=database \
    BROADCAST_CONNECTION=log \
    FILESYSTEM_DISK=local \
    NPM_PATH=/usr/bin/npm \
    CYPRESS_CACHE_FOLDER=/var/www/.cache/Cypress \
    PLAYWRIGHT_BROWSERS_PATH=/var/www/.cache/ms-playwright \
    npm_config_cache=/var/www/.cache/npm \
    SIGNALDECK_ROLE=all

LABEL org.opencontainers.image.title="SignalDeck CI" \
      org.opencontainers.image.description="Self-hosted Cypress & Playwright test dashboard" \
      org.opencontainers.image.source="https://github.com/benwake1/signaldeck-docker" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${SIGNALDECK_VERSION}"

EXPOSE 80
VOLUME ["/var/www/app/storage/app", "/var/www/.cache"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["signaldeck-healthcheck"]

# tini is PID 1 so orphaned browser processes are always reaped, even
# when the container is started without --init. With no command the role
# comes from SIGNALDECK_ROLE; `command: worker` (etc.) overrides it.
ENTRYPOINT ["/usr/bin/tini", "--", "signaldeck-entrypoint"]
