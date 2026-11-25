# Kamailio SBC for Reprise — Debian trixie, built from the reprise-voice
# kamailio fork (2600hz's patched core plus their kazoo and db_kazoo
# modules, ported to 6.x), configured from configs/kamailio in this tree.
#
# Build from the repository root:
#   docker build -f docker/kamailio/Dockerfile -t reprise-kamailio .
FROM debian:trixie-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential g++ bison flex pkg-config git ca-certificates \
      libssl-dev libcurl4-openssl-dev libxml2-dev libpcre2-dev \
      libjson-c-dev libev-dev uuid-dev zlib1g-dev libunistring-dev \
      libevent-dev libsctp-dev libjansson-dev libmnl-dev libnghttp2-dev \
    && rm -rf /var/lib/apt/lists/*

# The reprise-voice fork of Kamailio; REPRISE_GIT_BASE
# points it at a mirror (see make/repos.mk). KAMAILIO_REF: the tip of the
# reprise/6.1.6 branch as of 2026-11-25 (a commit, a tag or a branch all work:
# it is fetched by name).
ARG REPRISE_GIT_BASE=https://github.com/reprise-voice
ARG KAMAILIO_REPO=${REPRISE_GIT_BASE}/kamailio
ARG KAMAILIO_REF=32fd62f54c3adcafeee7da666d4ae4abc755b98a
RUN git init -q /src \
    && git -C /src fetch -q --depth 1 ${KAMAILIO_REPO} ${KAMAILIO_REF} \
    && git -C /src checkout -q FETCH_HEAD \
    && git -C /src rev-parse HEAD > /src/REV && rm -rf /src/.git
WORKDIR /src
# The module set the configs load (regex needs pcre1, gone in trixie).
RUN make cfg FLAVOUR=kamailio PREFIX=/usr \
      include_modules="presence presence_dialoginfo presence_mwi presence_xml pua pua_dialoginfo websocket tls outbound uuid tcpops crypto rtjson sipjson json jansson xhttp_prom sctp http_client xmlops kazoo db_kazoo" \
    && make -j"$(nproc)" all \
    && make install PREFIX=/usr DESTDIR=/out \
    # the install (re)builds kamcmd with RUN_DIR under DESTDIR, so it would
    # look for its socket under /out/var/run: rebuild it without DESTDIR
    && make -C utils/kamcmd clean && make -C utils/kamcmd \
    && install -m 755 utils/kamcmd/kamcmd /out/usr/sbin/kamcmd \
    && install -m 644 REV /out/usr/lib64/kamailio/kamailio.rev \
    && ls /out/usr/lib64/kamailio/modules/kazoo.so /out/usr/lib64/kamailio/modules/db_kazoo.so /out/usr/sbin/KazooDB

FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      libssl3t64 libcurl4t64 libxml2 libpcre2-8-0 libjson-c5 libev4t64 libuuid1 zlib1g \
      libunistring5 libevent-2.1-7t64 libsctp1 libjansson4 libmnl0 libnghttp2-14 libstdc++6 \
      ca-certificates curl gettext-base openssl procps iproute2 less netbase \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/usr /usr

# The Kamailio configuration (configs/kamailio in this tree: 2600hz 5.4 plus
# the files newer Kamailio needs) at the path the configs themselves expect.
COPY configs/kamailio/kamailio /etc/kazoo/kamailio
RUN chmod +x /etc/kazoo/kamailio/db_scripts/*.sh

COPY docker/kamailio/local.cfg.tpl /local.cfg.tpl
COPY docker/kamailio/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && groupadd --gid 10001 kamailio \
    && useradd --uid 10001 --gid 10001 --no-log-init --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin kamailio \
    && mkdir -p /run/kamailio /etc/kazoo/kamailio/db /etc/kazoo/kamailio/certs \
    && touch /etc/kazoo/kamailio/local.cfg \
    && chown -R 10001:10001 /run/kamailio /etc/kazoo/kamailio/db \
        /etc/kazoo/kamailio/certs /etc/kazoo/kamailio/local.cfg \
    && chmod 0750 /etc/kazoo/kamailio/certs \
    && chmod 0640 /etc/kazoo/kamailio/local.cfg \
    && find / -xdev -type f -perm /6000 -exec chmod a-s {} +

USER 10001:10001
ENTRYPOINT ["/entrypoint.sh"]

# OCI metadata. The source label is what links the GHCR package to the
# repository; CI passes the version and the commit.
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
LABEL org.opencontainers.image.title="reprise-kamailio" \
      org.opencontainers.image.description="Kamailio SBC with the kazoo and db_kazoo modules, configured for Reprise" \
      org.opencontainers.image.source="https://github.com/reprise-voice/reprise" \
      org.opencontainers.image.url="https://github.com/reprise-voice/reprise" \
      org.opencontainers.image.licenses="GPL-2.0-or-later AND MPL-2.0" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}"
