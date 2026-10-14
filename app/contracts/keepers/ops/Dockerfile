# syntax=docker/dockerfile:1
# DyorHQ keepers image for Fly.io (build 17 K4). The build context is a bundle of a reviewed commit (ops/bundle.sh):
# contracts/keepers, contracts/deployments/*.json, package.json and package-lock.json, nothing else. No secret is ever
# baked in: the keystores, their passwords, the webhook and the healthchecks.io URLs are Fly secrets that
# entrypoint.sh moves into a tmpfs at boot. Every image runs the keeper tests on its own Node and dependencies while it
# builds (the "test" stage), so an image that exists passed them.
#
# Pinned: Node 22 LTS on Debian 13 slim by digest (22.23.3, the multi-arch index of node:22-trixie-slim, 2026-09-23),
# Foundry v1.7.1 `cast` and supercronic v0.2.49 by SHA256 (the values Foundry's .sha256 release files and GitHub's
# release asset digests give). Fly runs linux/amd64; arm64 is for local builds on Apple silicon.
ARG NODE_IMAGE=node:22-trixie-slim@sha256:b26b04c123d9ff8ab646ceb18b9d75a1173acf64b9a401094b906d27b29338d4

FROM ${NODE_IMAGE} AS tools
ARG TARGETARCH
ARG FOUNDRY_VERSION=v1.7.1
ARG FOUNDRY_SHA256_AMD64=cf7e688ed0c4c48adffca788b496076e31060b67ac5afe1e43dbb5499c20c88b
ARG FOUNDRY_SHA256_ARM64=c8fe8fa09ae3aba2c81b510c6f9da3a9d468029b9580e690b245b3f0aea687ae
ARG SUPERCRONIC_VERSION=v0.2.49
ARG SUPERCRONIC_SHA256_AMD64=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1
ARG SUPERCRONIC_SHA256_ARM64=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /tools
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) foundry_sha=$FOUNDRY_SHA256_AMD64; cron_sha=$SUPERCRONIC_SHA256_AMD64 ;; \
      arm64) foundry_sha=$FOUNDRY_SHA256_ARM64; cron_sha=$SUPERCRONIC_SHA256_ARM64 ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --proto '=https' -o foundry.tar.gz \
      "https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/foundry_${FOUNDRY_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    echo "${foundry_sha}  foundry.tar.gz" | sha256sum -c -; \
    tar -xzf foundry.tar.gz cast; \
    rm foundry.tar.gz; \
    ./cast --version | grep -q "^cast Version: ${FOUNDRY_VERSION#v}"; \
    curl -fsSL --proto '=https' -o supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}"; \
    echo "${cron_sha}  supercronic" | sha256sum -c -; \
    chmod 0755 cast supercronic

# Production dependencies only (viem), exactly as the lockfile pins them, with no install scripts.
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund

# The keeper tests and the crontab check, on the image's own Node and node_modules.
FROM deps AS test
COPY --from=tools /tools/cast /tools/supercronic /usr/local/bin/
COPY contracts/deployments/ contracts/deployments/
COPY contracts/keepers/ contracts/keepers/
RUN supercronic -test contracts/keepers/ops/crontab \
 && npm run keepers:test \
 && touch /tests-passed

FROM ${NODE_IMAGE}
# curl for the healthchecks.io pings (and ca-certificates for it and cast); procps for the owner's `ps` check during the
# dry run (no password or URL on any command line). npm, npx, corepack and yarn are not needed to run the keepers, so
# they are removed. /app is root's: the keeper user can read it and write nothing there.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl procps \
 && rm -rf /var/lib/apt/lists/* \
 && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /usr/local/bin/npm /usr/local/bin/npx \
      /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-* \
 && groupadd --system --gid 10001 keeper \
 && useradd --system --uid 10001 --gid keeper --home-dir /home/keeper --create-home --shell /usr/sbin/nologin keeper
COPY --from=tools /tools/cast /tools/supercronic /usr/local/bin/
WORKDIR /app
COPY --from=deps /app/node_modules/ node_modules/
COPY package.json package-lock.json ./
COPY contracts/deployments/ contracts/deployments/
COPY contracts/keepers/ contracts/keepers/
COPY --from=test /tests-passed /app/.tests-passed
RUN chmod 0555 /app/contracts/keepers/ops/*.sh
ENV NODE_ENV=production TZ=UTC
# The entrypoint starts as root only to mount the secrets tmpfs and hand /data to the keeper user; everything it
# starts runs as keeper (uid 10001) with no capabilities.
ENTRYPOINT ["/app/contracts/keepers/ops/entrypoint.sh"]
