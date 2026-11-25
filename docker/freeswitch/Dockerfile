# FreeSWITCH (upstream signalwire tag + Kazoo session handoff) + mod_reprise, the AMQP
# transport from freeswitch/mod_reprise in this tree, configured from
# configs/freeswitch.
#
# Build from the repository root:
#   docker build -f docker/freeswitch/Dockerfile -t reprise-freeswitch .
#   docker build -f docker/freeswitch/Dockerfile --target build -t reprise-freeswitch-dev .
# The `build` stage (full toolchain, /usr/local/freeswitch install,
# librabbitmq-dev) is published as reprise-freeswitch-dev: the compile
# environment for the module's tests (`make test` in freeswitch/mod_reprise).
FROM debian:trixie AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential autoconf automake libtool libtool-bin pkg-config git ca-certificates \
    bison yasm \
    libssl-dev zlib1g-dev libdb-dev unixodbc-dev libncurses-dev libexpat1-dev libgdbm-dev \
    libtiff-dev libjpeg62-turbo-dev libsqlite3-dev libcurl4-openssl-dev libpcre2-dev \
    libspeex-dev libspeexdsp-dev libedit-dev libldns-dev libopus-dev libsndfile1-dev \
    libmpg123-dev libmp3lame-dev libshout3-dev flite1-dev \
    librabbitmq-dev uuid-dev libpq-dev libminiupnpc-dev libnatpmp-dev \
    && rm -rf /var/lib/apt/lists/*

# sofia-sip >= 1.13.19 and spandsp >= 3.1.1 (what 1.11.4 requires) are not in
# Debian: build FreeSWITCH's forks at their release tags.
# Both are fetched from their living upstream (SignalWire's freeswitch org);
# the *_REPO arguments let a mirror stand in.
ARG SOFIA_REPO=https://github.com/freeswitch/sofia-sip
ARG SOFIA_REF=v1.13.19
RUN git clone --depth 1 -b ${SOFIA_REF} ${SOFIA_REPO} /usr/src/sofia-sip \
    && cd /usr/src/sofia-sip && ./bootstrap.sh && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" && make install && ldconfig

ARG SPANDSP_REPO=https://github.com/freeswitch/spandsp
ARG SPANDSP_REF=v3.1.1
RUN git clone --depth 1 -b ${SPANDSP_REF} ${SPANDSP_REPO} /usr/src/spandsp \
    && cd /usr/src/spandsp && ./bootstrap.sh && ./configure --prefix=/usr/local \
    && make -j"$(nproc)" && make install && ldconfig

# Source repositories: the reprise-voice forks, under their upstream names
# (REPRISE_GIT_BASE points the lot at a mirror; see make/repos.mk).
# reprise-voice/freeswitch carries signalwire's v1.11.4 tag (795228ad).
ARG REPRISE_GIT_BASE=https://github.com/reprise-voice
ARG FS_REPO=${REPRISE_GIT_BASE}/freeswitch
ARG FS_REF=v1.11.4
RUN git clone --depth 1 -b ${FS_REF} ${FS_REPO} /usr/src/freeswitch

WORKDIR /usr/src/freeswitch
# The stateful kz endpoint and core are one compatibility unit. Fail the
# build if a different FreeSWITCH revision no longer matches this patch.
COPY docker/freeswitch/patches /usr/src/reprise-freeswitch-patches
RUN git apply --check /usr/src/reprise-freeswitch-patches/0001-kazoo-session-handoff.patch \
    && git apply /usr/src/reprise-freeswitch-patches/0001-kazoo-session-handoff.patch \
    && git apply --check /usr/src/reprise-freeswitch-patches/0002-kazoo-intercept.patch \
    && git apply /usr/src/reprise-freeswitch-patches/0002-kazoo-intercept.patch \
    && git apply --check /usr/src/reprise-freeswitch-patches/0003-kazoo-early-transfer.patch \
    && git apply /usr/src/reprise-freeswitch-patches/0003-kazoo-early-transfer.patch \
    && git apply --check /usr/src/reprise-freeswitch-patches/0004-loopback-replacement-event.patch \
    && git apply /usr/src/reprise-freeswitch-patches/0004-loopback-replacement-event.patch \
    && git apply --check /usr/src/reprise-freeswitch-patches/0005-kazoo-event-flags.patch \
    && git apply /usr/src/reprise-freeswitch-patches/0005-kazoo-event-flags.patch \
    && git apply --check /usr/src/reprise-freeswitch-patches/0006-loopback-bridge-ownership.patch \
    && git apply /usr/src/reprise-freeswitch-patches/0006-loopback-bridge-ownership.patch \
    && git apply --check /usr/src/reprise-freeswitch-patches/0007-ring-ready-inline.patch \
    && git apply /usr/src/reprise-freeswitch-patches/0007-ring-ready-inline.patch
# NOTE: no -j — that flag backgrounds the autotools jobs and the RUN step
# would return (and kill them) before all Makefile.ins are generated.
RUN ./bootstrap.sh

# Module set: enable mod_amqp, mod_http_cache (Kazoo plays media as
# http_cache:// URLs, including prompt:// through mod_reprise),
# mod_shout (mp3 recording / playback: Kazoo's default voicemail and
# recording format) and mod_flite (Kazoo's default text-to-speech engine);
# disable modules with deps we don't ship. The configs' modules.conf.xml
# loads http_cache, shout and flite and ships http_cache.conf.xml /
# shout.conf.xml.
RUN cp build/modules.conf.in modules.conf \
    && sed -i \
        -e 's|^#event_handlers/mod_amqp|event_handlers/mod_amqp|' \
        -e 's|^#applications/mod_http_cache|applications/mod_http_cache|' \
        -e 's|^#formats/mod_shout|formats/mod_shout|' \
        -e 's|^#asr_tts/mod_flite|asr_tts/mod_flite|' \
        -e 's|^applications/mod_signalwire|#applications/mod_signalwire|' \
        -e 's|^endpoints/mod_verto|#endpoints/mod_verto|' \
        -e 's|^endpoints/mod_rtc|#endpoints/mod_rtc|' \
        -e 's|^languages/mod_python3|#languages/mod_python3|' \
        -e 's|^applications/mod_av|#applications/mod_av|' \
        -e 's|^applications/mod_sms|#applications/mod_sms|' \
        -e 's|^languages/mod_lua|#languages/mod_lua|' \
        -e 's|^applications/mod_enum|#applications/mod_enum|' \
        modules.conf

RUN ./configure --prefix=/usr/local/freeswitch \
    && make -j"$(nproc)" \
    && make install

# Sounds: reprise-voice/kazoo-sounds carries the FreeSWITCH-side tree
# (music/8000 for local_stream://default = music on hold, and the
# per-language callie/julie prompt sets FreeSWITCH's own apps use) under
# freeswitch/, and the Kazoo prompts (imported into system_media by the
# kazoo image) under kazoo-core/. The FreeSWITCH half is installed where the
# stock sounds_dir points; the configs' vars name the voice "allison", which
# this set does not have, so callie stands in.
# SOUNDS_REF: master's tip as of 2026-11-21 (a commit, a tag or a branch all
# work: it is fetched by name).
ARG SOUNDS_REPO=${REPRISE_GIT_BASE}/kazoo-sounds
ARG SOUNDS_REF=c82a707d9f06cf8160891aa57025ee606806bd0b
RUN git init -q /usr/src/kazoo-sounds \
    && git -C /usr/src/kazoo-sounds fetch -q --depth 1 ${SOUNDS_REPO} ${SOUNDS_REF} \
    && git -C /usr/src/kazoo-sounds checkout -q FETCH_HEAD \
    && mkdir -p /usr/local/freeswitch/share/freeswitch/sounds \
    && cp -r /usr/src/kazoo-sounds/freeswitch/. /usr/local/freeswitch/share/freeswitch/sounds/ \
    && ln -s callie /usr/local/freeswitch/share/freeswitch/sounds/en/us/allison \
    && rm -rf /usr/src/kazoo-sounds

# The AMQP transport, built out-of-tree against the install above, in its
# own stage so `--target build` needs no module source.
FROM build AS reprise
COPY freeswitch/mod_reprise /usr/src/mod_reprise
RUN cd /usr/src/mod_reprise && rm -f src/*.o *.so \
    && PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig make \
    && PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig make install

# The FreeSWITCH configuration (configs/freeswitch in this tree) at the path
# Kazoo's ecallmgr and the configs themselves expect.
COPY configs/freeswitch/freeswitch /etc/kazoo/freeswitch

FROM debian:trixie-slim

# The runtime halves of the build stage's -dev packages, under their trixie
# names (the t64 ones are the 64-bit time_t builds).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    libssl3t64 zlib1g libdb5.3t64 odbcinst libodbc2 libncursesw6 libexpat1 libgdbm6t64 \
    libtiff6 libjpeg62-turbo libsqlite3-0 libcurl4t64 libpcre2-8-0 \
    libspeex1 libspeexdsp1 libedit2 libldns3t64 libopus0 libsndfile1 \
    libmpg123-0t64 libmp3lame0 libshout3 libflite1 \
    librabbitmq4 libuuid1 libpq5 libminiupnpc18 libnatpmp1t64 \
    xmlstarlet procps iproute2 less \
    && rm -rf /var/lib/apt/lists/*

COPY --from=reprise /usr/local/freeswitch /usr/local/freeswitch
COPY --from=reprise /usr/local/lib /usr/local/lib
COPY --from=reprise /etc/kazoo/freeswitch /etc/kazoo/freeswitch
RUN ldconfig

COPY docker/freeswitch/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && groupadd --gid 10001 freeswitch \
    && useradd --uid 10001 --gid 10001 --no-log-init --create-home \
        --home-dir /var/lib/freeswitch --shell /usr/sbin/nologin freeswitch \
    && mkdir -p /var/log/freeswitch /run/freeswitch \
        /var/lib/freeswitch/db /var/lib/freeswitch/storage \
        /var/lib/freeswitch/cache /var/lib/freeswitch/certs \
    && chown -R 10001:10001 /var/log/freeswitch /var/lib/freeswitch /run/freeswitch \
        /etc/kazoo/freeswitch/vars /etc/kazoo/freeswitch/sip_profiles \
        /etc/kazoo/freeswitch/autoload_configs /etc/kazoo/freeswitch/kazoo/connections \
    && find / -xdev -type f -perm /6000 -exec chmod a-s {} +

ENV HOME=/var/lib/freeswitch
USER 10001:10001
ENTRYPOINT ["/entrypoint.sh"]

# OCI metadata. The source label is what links the GHCR package to the
# repository; CI passes the version and the commit.
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
LABEL org.opencontainers.image.title="reprise-freeswitch" \
      org.opencontainers.image.description="FreeSWITCH with mod_reprise, the AMQP transport to Reprise ecallmgr, configured for Reprise" \
      org.opencontainers.image.source="https://github.com/reprise-voice/reprise" \
      org.opencontainers.image.url="https://github.com/reprise-voice/reprise" \
      org.opencontainers.image.licenses="MPL-1.1 AND MPL-2.0" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}"
