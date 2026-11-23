# Container security

All production images start as an unprivileged user, including their
entrypoints. Application executables and libraries remain owned by root.
Setuid/setgid bits are removed from production images. Build stages still
use root to install packages and compile software; `freeswitch-dev` is a
build environment, not a production service. The FreeSWITCH CI smoke
service also runs as UID/GID 10001.

| Image | UID:GID | Writable runtime paths (in addition to `/tmp`) |
|---|---|---|
| Reprise (all node roles) | `10001:10001` | `/var/lib/kazoo` (HOME, Erlang cookie, LibreOffice profile), `/opt/kazoo/log`, `/opt/kazoo/var` |
| FreeSWITCH | `10001:10001` | `/run/freeswitch`, `/var/log/freeswitch`, `/var/lib/freeswitch`; entrypoint-managed config directories under `/etc/kazoo/freeswitch`: `vars`, `sip_profiles`, `autoload_configs`, `kazoo/connections` |
| Kamailio | `10001:10001` | `/run/kamailio`, `/etc/kazoo/kamailio/local.cfg`, `/etc/kazoo/kamailio/db`, `/etc/kazoo/kamailio/certs` |
| Monster UI (nginx) | `101:101` | `/tmp/nginx` (rendered config, PID, temporary files) |

## Deploying the images

Deployments that ran earlier, root-running builds of these images need the
following changes alongside the new images:

- **Monster UI now listens on 8080.** Change container ports, service
  target port, health probes, and Docker mappings (for example `-p 80:8080`).
  Nginx's base image still advertises port 80 in image metadata; it does not
  listen there.
- Existing volumes and bind mounts retain their host ownership. Before
  rollout, grant the listed UID/GID access to each writable path, including
  existing files. Image ownership does not repair mounted volumes. Mount
  Reprise configuration read-only, readable by UID/GID 10001.
- For standalone Reprise smoke runs, provide a fully qualified hostname
  (for example `--hostname kazoo.local`). The existing launcher uses Erlang
  long node names and can fail with `nodistribution` on a bare container ID.
- FreeSWITCH edits the listed configuration directories at startup; those
  directories must be writable if mounted. Kamailio needs a writable
  `local.cfg` file and `db`/`certs` directories. Its remaining configuration
  and database scripts can stay read-only.
- If `KAM_TLS_DOMAIN` is set, the Let's Encrypt certificate and private key
  must exist and be readable by Kamailio. Give GID 10001 read access to the
  private key and traversal access through both `live` and `archive`, or
  project equivalent secrets with suitable ownership. Keep keys private;
  do not make them world-readable. A missing/unreadable explicitly selected
  certificate fails startup. With no domain configured, the development
  self-signed fallback remains available.
- FreeSWITCH uses normal scheduling priority (`-np`) so it needs no
  scheduling capabilities. Validate call capacity and latency at production
  load before rollout.

Run services with `--cap-drop=ALL --security-opt=no-new-privileges`. The
shipped listeners use unprivileged ports. In Kubernetes, set the container
`securityContext` to `runAsNonRoot: true`, `allowPrivilegeEscalation: false`,
`capabilities.drop: ["ALL"]`, and `seccompProfile.type: RuntimeDefault`.
Use each image's UID/GID above when specifying `runAsUser`/`runAsGroup`.
Prepare storage permissions or use `fsGroup` where the volume driver
supports it.

Monster UI supports a read-only root filesystem with a writable `/tmp`:

```sh
docker run --rm --read-only --tmpfs /tmp:rw,nosuid,nodev \
  --cap-drop=ALL --security-opt=no-new-privileges -p 80:8080 \
  -e CROSSBAR_UPSTREAM=http://kazoo-apps:8000 \
  -e BLACKHOLE_UPSTREAM=http://blackhole:5555 \
  ghcr.io/reprise-voice/reprise-monster-ui:<tag>
```

Attach it to the network that resolves those upstream names. For the other
services, a read-only root filesystem additionally requires writable mounts
for every runtime path in the table. Configuration directories must be
populated before mounting them; empty tmpfs mounts would hide their image
contents. Validate these mounts with the actual deployment configuration.

## Validation

After building the images, run:

```sh
docker/build.sh
bash docker/test-security.sh
```

The check verifies non-root identity, writable state paths, protected code,
absence of setuid/setgid programs under `/usr` and `/opt`, Erlang distribution,
FreeSWITCH's executable, Kamailio configuration generation/parsing, and nginx
configuration on a read-only filesystem. All containers run without network
access, Linux capabilities, or permission to gain privileges.
`REGISTRY`/`TAG` select the same names as `build.sh`; individual image overrides
are `REPRISE_IMAGE`, `FREESWITCH_IMAGE`,
`KAMAILIO_IMAGE`, and `MONSTER_UI_IMAGE`.
These preflights do not replace integration tests against RabbitMQ/CouchDB,
SIP/media traffic, fax conversion, or the deployment's persistent volumes.

## Further build and deployment hardening

- Pin base images by digest and external source repositories by immutable
  revision, with automated update PRs. Several current builds track moving
  tags/branches, including Monster UI and sounds.
- Scan the final images and publish SBOMs/provenance in the release
  pipeline. Rebuild regularly for base-image security updates.
- Upgrade Monster UI's legacy Node 18/node-sass build toolchain as a separate
  compatibility change; the compiler image is not shipped in the nginx
  runtime.
- Inject credentials as runtime secrets; replace development broker
  credentials and cookies in deployment configuration. Keep secrets out of
  build arguments and the Docker context.
- Apply memory/CPU/PID limits and network policies suited to SIP/RTP and
  internal AMQP/CouchDB traffic. Keep management sockets and database/broker
  ports private.

References: [Docker build practices](https://docs.docker.com/build/building/best-practices/)
and [nginx unprivileged runtime paths](https://github.com/nginx/docker-nginx-unprivileged).
