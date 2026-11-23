# CircleCI

`config.yml` has two workflows, and a pipeline runs exactly one of them:

| Workflow | When | Jobs |
|---|---|---|
| `checks` | pushes and pull requests on every branch but `main`, unless the run sets the `images` parameter | `lint` (shellcheck, the compose files, sipp scenarios, VERSION/tag agreement, docs checks that need no build), `gleam` (`make gleam-check`), `erlang-build` (`make prerequisites deps core apps xref`, warnings are errors; elvis on the changed files. `make fmt` is not checked: it needs Emacs, so format locally), then `eunit` (`make eunit`, JUnit results in the Tests tab) and `schemas` (`make apis` leaves the tree clean) |
| `images` | pushes to `main`, `v*` tags, or a run with the `images` pipeline parameter | every job of `checks`, then the four images for linux/amd64, pushed as `sha-<short>-amd64` candidates; `mod-reprise-tests` (the module's `make test-call-paths` in the freeswitch build stage); `smoke` (the candidates through `deploy/compose`: `docker/test-security.sh`, `docker compose up`, `bootstrap.sh`, then `deploy/compose/smoke/smoke.sh`: two devices register and one calls the other; the services' logs as artifacts, pass or fail); `publish` (main and tags only), which requires `lint`, `gleam`, `eunit`, `schemas`, `mod-reprise-tests` and `smoke` of the same pipeline, so nothing is published from a commit with a failing check |

## Why the jobs run where they do

- Erlang and Gleam jobs use the official `erlang:28` image: the same moving
  tag as the release's build stage (`docker/reprise/Dockerfile`), so the
  tests run on the OTP the image is built with (change both together), and
  it ships rebar3, which `gleam test` needs to
  compile the Erlang hex packages. Gleam 1.18.1 is installed from the release
  tarball with the checksum the Dockerfile pins. Building that Dockerfile's
  stage instead would cost the whole dependency build on every run; the image
  starts in seconds and `deps/` is cached on a hash of `make/deps.mk`,
  `make/repos.mk` and `make/erlang_version`.
- Image jobs use the machine executor (a real Docker daemon, needed for
  buildx and for the compose smoke test). Layer caching goes through the
  registry (`<image>:buildcache-<arch>` tags, `mode=max`), so it works without
  CircleCI's Docker Layer Caching; turn on `docker_layer_caching: true` in the
  `machine-*` executors as well if the plan includes it.
- One job per image, in parallel. The Erlang release and FreeSWITCH take the
  longest (tens of minutes cold); `resource_class: xlarge` on `machine-amd64`
  shortens the FreeSWITCH build, which compiles with `-j$(nproc)`.

## Tags

`images.sh tags` prints what a pipeline publishes:

| Trigger | Published to `ghcr.io/reprise-voice/<image>` |
|---|---|
| push to `main` | `edge`, `sha-<short>` |
| tag `vX.Y.Z` | `X.Y.Z`, `X.Y`, `latest`, `sha-<short>` (a pre-release `vX.Y.Z-rc.N` gets only its own tag and `sha-<short>`) |

The tag must equal `v` + the `VERSION` file, or every image job fails before
building. Candidates (`sha-<short>-amd64`) and the `buildcache-*`
tags also live in the packages; prune them with GHCR's retention settings if
they pile up.

The images are `reprise`, `reprise-freeswitch`, `reprise-kamailio` and
`reprise-monster-ui`. Their `org.opencontainers.image.source` label links each
package to this repository.

## What to set up once

1. **Project**: follow the repository in CircleCI (GitHub App or OAuth
   integration).
2. **Context `ghcr`** (Organization Settings > Contexts) with two variables:
   - `GHCR_USER`: the GitHub user (or bot account) that owns the token
   - `GHCR_TOKEN`: a classic personal access token with `write:packages`
     (and `read:packages`), authorised for the `reprise-voice` organisation;
     or a fine-grained token with package write access to the organisation.

   Restrict the context to the project, and with an expression restriction to
   `main` and `v*` tags if branch runs with `images=true` are not wanted.
   Scripts never print the token (`docker login --password-stdin`).
3. **After the first push to `main`**: each of the four packages is created
   private. Make each one public once (GitHub > the organisation > Packages >
   the package > Package settings > Change visibility), and check that it
   shows this repository as linked (the source label does that; "Connect
   repository" in the same page otherwise). Until then the compose quick
   start cannot pull anonymously.
4. **Branch protection** on GitHub: require the `checks` workflow's jobs as
   status checks for pull requests.
5. Optional: a scheduled pipeline (Project Settings > Triggers) on `main`
   with `images: true` rebuilds the images regularly for base-image security
   updates.

To build and smoke-test the images of a branch before merging, trigger a
pipeline on it with the parameter `images` set to `true` (Trigger Pipeline in
the CircleCI UI). It pushes candidates but publishes nothing.

Validate edits with `circleci config validate` (`make ci-config` downloads the
CLI).
