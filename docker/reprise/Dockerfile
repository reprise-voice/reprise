# Reprise (Kazoo 5.4 on OTP 28), built from this tree. One image serves both
# node types:
#   kazoo_apps: KAZOO_NODE=kazoo_apps
#   ecallmgr:   KAZOO_NODE=ecallmgr KAZOO_APPS=ecallmgr,ecallmgr_extension
# (ecallmgr_extension is the AMQP side of mod_reprise in the FreeSWITCH
# image; nothing else starts it, and without it no FreeSWITCH is adopted.)
#
# Build from the repository root:
#   docker build -f docker/reprise/Dockerfile -t reprise .
# Source repositories: the reprise-voice forks, under their upstream names.
# REPRISE_GIT_BASE points the dependency fetch (make/repos.mk) and the sounds
# clone at a mirror instead.
ARG REPRISE_GIT_BASE=https://github.com/reprise-voice

FROM erlang:28 AS builder

# Erlang's JIT maps its code twice (one mapping writable, one executable),
# which QEMU's user-mode emulation cannot follow: a build for a foreign
# platform (linux/amd64 on an arm64 machine, say) then crashes every `erl`
# at start. A single mapping works everywhere and costs nothing at build
# time. This is the build stage only; the release image is unaffected.
ENV ERL_FLAGS="+JMsingle true"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential git bash curl ca-certificates \
    zip unzip cpio jq \
    libssl-dev libncurses-dev zlib1g-dev libexpat1-dev libxslt1-dev \
    python3 python3-jsbeautifier \
    && rm -rf /var/lib/apt/lists/*

# The Gleam applications (callcenter, stir) are compiled to BEAM and shipped
# in the release; their Makefiles are skipped when gleam is missing. There is
# no Debian package, so the pinned release binary is fetched and checksummed.
# Keep GLEAM_VERSION in step with the CI configuration.
ARG GLEAM_VERSION=1.18.1
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) arch=x86_64;  sha=4955a38c2e8c99457458e2471472ccd5ee3c45bd7637a315ce33bccf0dd75d9e ;; \
      arm64) arch=aarch64; sha=ea08a64846677f36da7f2e9163c4393dd9a9dee814d13a8fb28fbe7dcbf32f6d ;; \
      *) echo "no gleam release for TARGETARCH '${TARGETARCH}'" >&2; exit 1 ;; \
    esac; \
    tarball="gleam-v${GLEAM_VERSION}-${arch}-unknown-linux-musl.tar.gz"; \
    curl -fsSL -o "/tmp/${tarball}" \
      "https://github.com/gleam-lang/gleam/releases/download/v${GLEAM_VERSION}/${tarball}"; \
    echo "${sha}  /tmp/${tarball}" | sha256sum -c -; \
    tar -xzf "/tmp/${tarball}" -C /usr/local/bin gleam; \
    rm "/tmp/${tarball}"; \
    gleam --version

# JOBS=1 (upstream default): several core apps generate .erl files via make
# rules that race with the app compile under parallel make.
# No BEAM_LEAN: relx must keep debug_info — ecallmgr_extension's node-module
# dispatch hot-patches freeswitch:mod/1 and mod_com_kazoo:core_uuid/1 via
# meta:replace_function, which needs the beams' abstract code
# ({cannot_load_forms,freeswitch} monitor crash otherwise).
ENV CI=true \
    ELIXIR=disable \
    JOBS=1

WORKDIR /src

# The dependency build is the expensive half of this image and changes only
# when the dependency set or the build machinery does, so it goes in its own
# layer ABOVE the source copy: an ordinary application commit then reuses it
# instead of refetching 47 repositories.
#
# It needs more than make/deps.mk. The root Makefile includes every make/*.mk
# when it parses, and reaches scripts/ both at parse time (check-changed.bash)
# and through `make prerequisites`, so a change to either still refetches.
COPY Makefile VERSION .base_branch ./
COPY make/ make/
COPY scripts/ scripts/
COPY vendor/ vendor/
ARG REPRISE_GIT_BASE
RUN make prerequisites deps

# After the dependency layer on purpose: KZ_VERSION only reaches the
# applications' .app vsn, and declaring it above would refetch every
# dependency on a version bump.
ARG KZ_VERSION=5.4.1
ENV KZ_VERSION=${KZ_VERSION}

# deps/, erlang.mk and the .deps.mk.* stamps are all in .dockerignore, so this
# leaves the tree the layer above built alone -- `make deps` stays satisfied
# because its stamp target carries no prerequisites.
COPY . /src

RUN make core
RUN make apps
RUN make build-release

# The Kazoo prompts (reprise-voice/kazoo-sounds, kazoo-core/<lang>/<region>)
# ride in the image so `kazoo_media_maintenance import_prompts` needs no
# download; the FreeSWITCH-side tree of the same repo goes into the
# freeswitch image.
FROM debian:trixie-slim AS sounds
# SOUNDS_REF: master's tip as of 2026-11-21 (a commit, a tag or a branch all
# work: it is fetched by name); keep it in step with docker/freeswitch.
ARG REPRISE_GIT_BASE
ARG SOUNDS_REPO=${REPRISE_GIT_BASE}/kazoo-sounds
ARG SOUNDS_REF=c82a707d9f06cf8160891aa57025ee606806bd0b
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates git \
    && git init -q /src \
    && git -C /src fetch -q --depth 1 ${SOUNDS_REPO} ${SOUNDS_REF} \
    && git -C /src checkout -q FETCH_HEAD \
    && rm -rf /src/.git

# runtime must be trixie: erlang:28 builds against glibc 2.41; bookworm
# (2.36) can't load the ERTS binaries
FROM debian:trixie-slim

# The fax converter (kazoo_convert) shells out to these: sox for audio,
# tiff2pdf/tiffinfo, gs and convert for TIFF/PDF/image faxes, and headless
# LibreOffice for Word, Excel, PowerPoint and OpenDocument attachments
# (email-to-fax and the fax API; fax.enable_openoffice in
# system_config/kazoo_convert, on by default). One component per document
# family the converter accepts; the fonts keep headless rendering from
# producing blank pages.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl openssl zlib1g libexpat1 libxslt1.1 libncursesw6 \
    sox ghostscript imagemagick libtiff-tools \
    libreoffice-writer libreoffice-calc libreoffice-impress fonts-liberation \
    iproute2 procps less vim-tiny \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/_rel/kazoo /opt/kazoo
COPY --from=sounds /src/kazoo-core /opt/kazoo/sounds
COPY docker/reprise/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && groupadd --gid 10001 kazoo \
    && useradd --uid 10001 --gid 10001 --no-log-init --create-home \
        --home-dir /var/lib/kazoo --shell /usr/sbin/nologin kazoo \
    && mkdir -p /opt/kazoo/log /opt/kazoo/var/lib/ra /etc/kazoo \
    && chown -R 10001:10001 /opt/kazoo/log /opt/kazoo/var \
    && find / -xdev -type f -perm /6000 -exec chmod a-s {} +

ENV KAZOO_CONFIG=/etc/kazoo/config.ini \
    KAZOO_NODE=kazoo_apps \
    HOME=/var/lib/kazoo \
    ERL_CRASH_DUMP=/opt/kazoo/log/erl_crash.dump \
    ERL_EPMD_ADDRESS=127.0.0.1 \
    PATH=/opt/kazoo/bin:$PATH

USER 10001:10001
ENTRYPOINT ["/entrypoint.sh"]

# OCI metadata. The source label is what links the GHCR package to the
# repository; CI passes the version and the commit.
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
LABEL org.opencontainers.image.title="reprise" \
      org.opencontainers.image.description="Reprise telephony platform (Kazoo 5.4 on OTP 28): one image for the kazoo_apps and ecallmgr node roles (KAZOO_NODE)" \
      org.opencontainers.image.source="https://github.com/reprise-voice/reprise" \
      org.opencontainers.image.url="https://github.com/reprise-voice/reprise" \
      org.opencontainers.image.licenses="MPL-2.0" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}"
