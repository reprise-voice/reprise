# Monster-UI + business apps (2600hz's UI, from the reprise-voice forks),
# built with the legacy toolchain (gulp4/babel6/node-sass8, which needs
# Node 18) and served by nginx, which also reverse-proxies crossbar (/v2) and blackhole
# websockets (/socket) so the UI needs no CORS and no absolute URLs.
#
# Build from the repository root:
#   docker build -f docker/monster-ui/Dockerfile -t reprise-monster-ui .
FROM debian:trixie-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    git ca-certificates curl xz-utils python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

# Node 18 is the newest release node-sass 8 supports, and there is no Node 18
# image on trixie, so the last 18.x release is installed from nodejs.org's
# own binaries, checked against the published checksum. It is used at build
# time only: the image that ships has no Node in it.
ARG NODE_VERSION=18.20.8
ARG NODE_SHA256=5467ee62d6af1411d46b6a10e3fb5cacc92734dbcef465fea14e7b90993001c9
RUN curl -fsSL -o /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
         --exclude='*/CHANGELOG.md' --exclude='*/README.md' --exclude='*/LICENSE' \
    && rm /tmp/node.tar.xz \
    && node --version && npm --version

# The reprise-voice forks: monster-ui and one
# monster-ui-<app> repository per app. REPRISE_GIT_BASE points them at a
# mirror (see make/repos.mk); ORG is its older name. Every ref is the tip of
# the repository's master branch as of 2026-11-21 (a commit, a tag or a
# branch all work: each is fetched by name). MONSTER_APPS lists <app>=<ref>
# (a bare <app> takes that repository's default branch).
ARG REPRISE_GIT_BASE=https://github.com/reprise-voice
ARG ORG=${REPRISE_GIT_BASE}
ARG MONSTER_REF=9b758e7dc4ba5c7ecf17b5beb69d86252199c4e2
RUN git init -q /src \
    && git -C /src fetch -q --depth 1 ${ORG}/monster-ui ${MONSTER_REF} \
    && git -C /src checkout -q FETCH_HEAD
WORKDIR /src

ARG MONSTER_APPS="\
voip=dde3866bb4c04fae93a222152ef352744987e061 \
callflows=d137150e7c6fad8cc8a6ef7fdeae16cf0da1cfa7 \
accounts=6a4e389949e76e8175d4ed7661744827d8f64b42 \
numbers=2d1e65f0a60e12f670d5d7583cb5198b76659d6e \
pbxs=131e57caada33fb91a3d9fcff4a9b778ffbf323c \
fax=d48ef78d0da734c1884ab6bfb1df4457886643db \
webhooks=fb791b73b6a5ad9a3482c8affab99ce1ee937443"
RUN set -e; for entry in ${MONSTER_APPS}; do \
      app=${entry%%=*}; \
      case "$entry" in *=*) ref=${entry#*=} ;; *) ref=HEAD ;; esac; \
      git init -q src/apps/$app; \
      git -C src/apps/$app fetch -q --depth 1 ${ORG}/monster-ui-$app $ref; \
      git -C src/apps/$app checkout -q FETCH_HEAD; \
    done

RUN npm install --no-audit --no-fund
RUN npx gulp build-prod || npx gulp build-dev

# config.js: compute API/websocket endpoints from the page origin at runtime.
COPY docker/monster-ui/config.js dist/js/config.js

FROM nginx:stable-trixie
COPY --from=build /src/dist /usr/share/nginx/html
# app metadata used by `sup crossbar_maintenance init_apps` (mount into the kazoo_apps node)
COPY --from=build /src/src/apps /opt/monster-apps
# nginx's entrypoint renders /etc/nginx/templates/*.template with envsubst
COPY docker/monster-ui/default.conf.template /etc/nginx/templates/default.conf.template
COPY docker/monster-ui/nginx.conf /etc/nginx/nginx.conf
COPY docker/monster-ui/19-runtime-dirs.sh /docker-entrypoint.d/19-runtime-dirs.sh
RUN chmod +x /docker-entrypoint.d/19-runtime-dirs.sh \
    && rm -f /etc/nginx/conf.d/default.conf \
    && find / -xdev -type f -perm /6000 -exec chmod a-s {} +
ENV CROSSBAR_UPSTREAM=http://kazoo-apps:8000 \
    BLACKHOLE_UPSTREAM=http://blackhole:5555 \
    NGINX_ENVSUBST_OUTPUT_DIR=/tmp/nginx/conf.d \
    NGINX_ENVSUBST_FILTER="^(CROSSBAR_UPSTREAM|BLACKHOLE_UPSTREAM)$"
EXPOSE 8080
USER 101:101

# OCI metadata. The source label is what links the GHCR package to the
# repository; CI passes the version and the commit.
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
LABEL org.opencontainers.image.title="reprise-monster-ui" \
      org.opencontainers.image.description="Monster UI and its apps for Reprise, served by unprivileged nginx (port 8080)" \
      org.opencontainers.image.source="https://github.com/reprise-voice/reprise" \
      org.opencontainers.image.url="https://github.com/reprise-voice/reprise" \
      org.opencontainers.image.licenses="MPL-2.0" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}"
