# Smoke image: full FS install (from freeswitch-dev) + mod_reprise +
# a minimal 3-module config pointed at the test cluster's broker.
ARG BASE=reprise/reprise-freeswitch-dev:dev
FROM ${BASE}

COPY . /usr/src/mod_reprise
WORKDIR /usr/src/mod_reprise
ENV PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig
RUN make && make install

RUN groupadd --gid 10001 freeswitch \
    && useradd --uid 10001 --gid 10001 --no-log-init --no-create-home \
        --home-dir /smoke --shell /usr/sbin/nologin freeswitch \
    && mkdir -p /smoke/conf /smoke/log /smoke/db /smoke/run /smoke/cache /smoke/storage /smoke/certs \
    && chown -R 10001:10001 /smoke
COPY ci/smoke/freeswitch.xml /smoke/conf/freeswitch.xml

ENV HOME=/smoke
USER 10001:10001
CMD ["/usr/local/freeswitch/bin/freeswitch", "-nf", "-nonat", "-np", \
     "-conf", "/smoke/conf", "-log", "/smoke/log", "-db", "/smoke/db", \
     "-run", "/smoke/run", "-cache", "/smoke/cache", \
     "-storage", "/smoke/storage", "-certs", "/smoke/certs"]
