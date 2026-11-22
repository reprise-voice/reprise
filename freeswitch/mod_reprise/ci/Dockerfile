# Compile-checks the module against the matching patched FS 1.11.3 using its
# freeswitch-dev image (the FS image's build stage: full toolchain,
# /usr/local/freeswitch install, librabbitmq-dev).
ARG BASE=reprise/reprise-freeswitch-dev:dev
FROM ${BASE}

COPY . /usr/src/mod_reprise
WORKDIR /usr/src/mod_reprise
ENV PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig

RUN make && ls -la mod_reprise.so && make test-call-paths
