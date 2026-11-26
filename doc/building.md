# Building from source

How to build the Erlang release, the Gleam applications, the FreeSWITCH
module and the container images from this tree, and how to run the tests.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Erlang/OTP | 28 (`make/erlang_version` and `.tool-versions` name 28.2, the oldest release used) | Built with SSL. CI and the release image both use the moving `erlang:28` Docker image. |
| GNU make | 4.x | `scripts/make-prerequisite.sh` refuses any other major version. |
| git | 2.x | Checked by the same script. |
| C toolchain | | gcc/g++, plus the OpenSSL, ncurses, zlib, expat and libxslt development headers for the NIFs (the package list in `docker/reprise/Dockerfile` is a known-good set on Debian). |
| Gleam | 1.18.1 | For `core/kazoo_gleam`, `callcenter` and `stir`. Without the `gleam` binary these are skipped and the release is built without them. |
| Python 3 | | Several `scripts/` helpers (schema validation, docs). |
| 7z (p7zip) | | Only for `make elvis`. |

The build fetches over the network: erlang.mk (from github.com/ninenines,
pinned to a commit in the `Makefile`), rebar3 (`make/rebar.mk`), the Erlang
dependencies in `make/deps.mk` (from the reprise-voice forks and from hex),
and the Gleam packages from hex.

## Building the release

```bash
make prerequisites deps   # tool checks, rebar3, erlang.mk, deps/
make core apps            # compile core/ and applications/
make build-release        # relx release in _rel/kazoo
```

`make` alone runs `prerequisites` and `compile` (deps, core and apps).
`make -C applications/<app>` builds one application, once `core` is built.

The release in `_rel/kazoo` is started with `_rel/kazoo/bin/kazoo
foreground` and needs a `config.ini` ([configuration](configuration.md)),
a broker and CouchDB. `sup` is in `_rel/kazoo/bin`.

Other release targets in `make/releases.mk`: `build-dev-release`,
`build-ci-release`, `build-dist-release` and `tar-release`.

### Where dependencies come from

Every forked repository the build fetches is under
`REPRISE_GIT_BASE` (default `https://github.com/reprise-voice`, set in
`make/repos.mk`), always at a pinned commit or tag. To build from a mirror,
or with SSH keys:

```bash
make clean-deps
make deps REPRISE_GIT_BASE=file:///srv/git
make deps REPRISE_GIT_BASE=git@github.com:reprise-voice
```

A mirror must hold repositories of the same names (without a `.git`
suffix). The Dockerfiles take the same value as a build argument, and
`docker/build.sh` passes it through from the environment.

## Tests and checks

| Target | What it does |
|---|---|
| `make eunit` | EUnit for core and applications (compiles every test directory first). `make -C applications/<app> eunit` for one application. |
| `make test` | EUnit with PropEr properties (`-DPROPER`). |
| `make gleam-check` | For every Gleam package: the manifest agreement check, `gleam format --check`, then `gleam test`. Skips the Gleam steps without a `gleam` binary. |
| `make xref` | Cross-reference check. |
| `make dialyze`, `make dialyze-changed` | Dialyzer on the applications, or on the files the branch changes (`make build-plt` first). |
| `make fmt` | Formats the changed Erlang files. |
| `make code_checks` | Copyright and license headers, edoc, spelling, raw JSON checks on changed files. |
| `make elvis` | Style lint of the changed Erlang files. |
| `make apis` | Regenerates the schemas, the API reference docs and the document accessor modules from the code, and formats the JSON files; clones kazoo-ast into `applications/ast` on first use. Run it on a normal build, not after `make eunit` (a test build exports test-only functions, which would be listed). The swagger and OpenAPI files are maintained by hand. |
| `make changed` | Lists the files the branch changes against `.base_branch`. |

Gleam tests run against an in-memory fake datastore and broker
(`core/kazoo_gleam`), so they need no CouchDB or broker. Each Gleam package
can also be tested on its own with `gleam test` in its directory.

## The FreeSWITCH module

`freeswitch/mod_reprise` builds against the patched FreeSWITCH that
`docker/freeswitch/Dockerfile` produces (it needs `freeswitch.pc` and
librabbitmq). The easiest way is the image's build stage:

```bash
docker/build.sh freeswitch-dev          # tags reprise/reprise-freeswitch-dev:dev
cd freeswitch/mod_reprise
docker run --rm --platform linux/amd64 -v "$PWD":/usr/src/mod_reprise -w /usr/src/mod_reprise \
  -e PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig \
  reprise/reprise-freeswitch-dev:dev make test
```

With a matching FreeSWITCH installed locally:

```bash
cd freeswitch/mod_reprise
PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig make        # mod_reprise.so
PKG_CONFIG_PATH=/usr/local/freeswitch/lib/pkgconfig make test   # unit tests
```

`make test-call-paths` runs the native call-path regression suites as well;
they also need the matching FreeSWITCH source tree (`FS_SRCDIR`, default
`/usr/src/freeswitch`). See
[freeswitch/mod_reprise/README.md](../freeswitch/mod_reprise/README.md#building).

## Container images

```bash
docker/build.sh                                   # reprise freeswitch kamailio monster-ui
docker/build.sh reprise                           # one image
REGISTRY=ghcr.io/example TAG=5.4.1 docker/build.sh
bash docker/test-security.sh                      # checks the built images
```

`docker/build.sh` tags images `$REGISTRY/reprise[-<image>]:$TAG` (defaults:
`reprise`, `dev`) for linux/amd64, the only platform the images are
built and supported for. On a machine of another architecture the build
and the containers run under emulation, which is slow; the Erlang nodes
then need `ERL_FLAGS="+JMsingle true"`, because the JIT's default memory
mapping does not work under QEMU user-mode emulation (the image's build
stage sets it already). The repository root is the build context. Build arguments for pinning or
replacing sources:

| Image | Arguments |
|---|---|
| `reprise` | `REPRISE_GIT_BASE`, `KZ_VERSION` (default 5.4.1), `GLEAM_VERSION`, `SOUNDS_REPO`, `SOUNDS_REF` |
| `reprise-freeswitch` | `REPRISE_GIT_BASE`, `FS_REPO`, `FS_REF` (v1.11.4), `SOFIA_REPO`, `SOFIA_REF`, `SPANDSP_REPO`, `SPANDSP_REF`, `SOUNDS_REPO`, `SOUNDS_REF` |
| `reprise-kamailio` | `REPRISE_GIT_BASE`, `KAMAILIO_REPO`, `KAMAILIO_REF` |
| `reprise-monster-ui` | `REPRISE_GIT_BASE`, `MONSTER_REF`, `MONSTER_APPS` |

The `reprise` image's Dockerfile builds the dependencies in their own layer,
so changing application code does not refetch them.

## Pitfalls

- **Keep `JOBS=1`** (the default in the `Makefile`). Several core
  applications generate `.erl` files in make rules that race with the
  compile, and each Gleam application installs its dependencies into
  `deps/`, where two parallel installs can collide.
- **A test build is not a release build.** `make eunit` and `make
  compile-test` compile into the same `ebin/` directories with `-DTEST`.
  `make build-release` refuses to run while `.test-compiled/` has entries;
  run `make clean-core clean-apps core apps` first.
- **Changing `REPRISE_GIT_BASE` does not refetch.** The deps stamp
  (`make/.deps.mk.<hash>`) is a hash of `make/repos.mk` and `make/deps.mk`,
  not of the command line. Run `make clean-deps` before `make deps` with a
  different source.
- **`make prerequisites` insists on make 4 and git 2**, exactly those major
  versions.
- **Node names need a resolvable FQDN.** The launcher builds the node name
  from the host's fully qualified name; on a host or container without one
  the node fails to start distribution (`nodistribution`).
- **Gleam missing is not an error.** Without `gleam`, `make` succeeds and
  the release simply lacks `callcenter` and `stir`. Check
  `gleam --version` if they are missing at run time.
