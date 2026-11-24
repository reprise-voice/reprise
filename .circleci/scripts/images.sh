#!/usr/bin/env bash
# Image build and publishing for .circleci/config.yml.
#
#   images.sh tags                    print the version and the tags this pipeline publishes
#   images.sh registry                print the registry namespace the images go to
#   images.sh login                   docker login to the registry's host (see below)
#   images.sh build <image> <arch>    build one image for linux/<arch>, push <ref>:sha-<short>-<arch>
#   images.sh promote                 the candidates -> the published tags
#
# <image>: reprise | freeswitch | kamailio | monster-ui. Candidates are pushed
# as sha-<short>-<arch>; promote runs only after the smoke test. The images
# are built for linux/amd64 only.
#
# Tags: a push to main publishes edge and sha-<short>; a tag v<X.Y.Z> (which
# must equal the VERSION file) publishes X.Y.Z, and for a release without a
# pre-release suffix also X.Y and latest, plus sha-<short>.
#
# The registry namespace is ghcr.io/<owner of the repository being built>
# (CircleCI's CIRCLE_PROJECT_USERNAME, lower case as the registry requires),
# so a fork's pipeline pushes to the fork owner's packages and cannot
# overwrite the images of the repository it was forked from. Outside
# CircleCI it is ghcr.io/reprise-voice. REGISTRY overrides both, and may name
# any registry (gcr.io/<project>, <region>-docker.pkg.dev/<project>/<repo>).
#
# login signs in to the host part of REGISTRY with REGISTRY_USER and
# REGISTRY_TOKEN, or with GHCR_USER and GHCR_TOKEN when those are not set.
#
# Releases can go to a registry of their own: in a v* tag pipeline
# RELEASE_REGISTRY, when set, takes the place of REGISTRY for every command
# (candidates, cache, smoke test, published tags), with RELEASE_REGISTRY_USER
# and RELEASE_REGISTRY_TOKEN if they differ from the ones above.
#
# A fork that releases its own builds of an upstream version sets
# RELEASE_SUFFIX (say acme). Its releases are then the tags
# v<VERSION>-acme.<N>, each published as <VERSION>-acme.<N> and nothing
# else: no X.Y, no latest. A plain v<VERSION> tag is not a release there, so
# an upstream tag that reaches the fork publishes nothing.
set -euo pipefail

cd "$(dirname "$0")/../.."

OWNER=$(printf '%s' "${CIRCLE_PROJECT_USERNAME:-reprise-voice}" | tr '[:upper:]' '[:lower:]')
REGISTRY=${REGISTRY:-ghcr.io/$OWNER}
REGISTRY_USER=${REGISTRY_USER:-${GHCR_USER:-}}
REGISTRY_TOKEN=${REGISTRY_TOKEN:-${GHCR_TOKEN:-}}
SHA=${CIRCLE_SHA1:-$(git rev-parse HEAD)}
SHORT=${SHA:0:7}
GIT_TAG=${CIRCLE_TAG:-}
if [ -n "$GIT_TAG" ] && [ -n "${RELEASE_REGISTRY:-}" ]; then
  REGISTRY=$RELEASE_REGISTRY
  REGISTRY_USER=${RELEASE_REGISTRY_USER:-$REGISTRY_USER}
  REGISTRY_TOKEN=${RELEASE_REGISTRY_TOKEN:-$REGISTRY_TOKEN}
fi
BRANCH=${CIRCLE_BRANCH:-}
VERSION=$(tr -d '[:space:]' < VERSION)
IMAGES=(reprise freeswitch kamailio monster-ui)

die() { echo "images.sh: $*" >&2; exit 1; }

# image name and Dockerfile per image key
image_name() {
  case "$1" in
    reprise) echo reprise ;;
    freeswitch|kamailio|monster-ui) echo "reprise-$1" ;;
    *) die "unknown image '$1'" ;;
  esac
}

# The tags to publish, one per line; sha-<short> comes last on purpose.
# The version a tag pipeline releases. Fails when the tag is not a release
# of this project.
release_version() {
  local suffix=${RELEASE_SUFFIX:-} build
  if [ -z "$suffix" ]; then
    [ "$GIT_TAG" = "v$VERSION" ] \
      || die "tag $GIT_TAG does not match VERSION ($VERSION): tag v$VERSION, or fix VERSION"
    echo "$VERSION"
    return
  fi
  build=${GIT_TAG#"v$VERSION-$suffix."}
  case "$build" in
    "$GIT_TAG"|""|*[!0-9]*)
      die "tag $GIT_TAG is not a release here: tag v$VERSION-$suffix.<N> (VERSION is $VERSION, RELEASE_SUFFIX is $suffix)" ;;
  esac
  echo "$VERSION-$suffix.$build"
}

publish_tags() {
  local release
  if [ -n "$GIT_TAG" ]; then
    release=$(release_version) || exit 1
    echo "$release"
    case "$release" in
      *-*) ;;  # a pre-release or a suffixed build: no moving tags
      *) echo "${release%.*}"; echo latest ;;
    esac
  elif [ "$BRANCH" = main ]; then
    echo edge
  fi
  echo "sha-$SHORT"
}

image_version() {
  if [ -n "$GIT_TAG" ]; then release_version; else echo "$VERSION-dev.$SHORT"; fi
}

# what the Erlang release calls itself: the release on a tag, VERSION otherwise
kz_version() {
  if [ -n "$GIT_TAG" ]; then release_version; else echo "$VERSION"; fi
}

cmd_tags() {
  publish_tags >/dev/null
  echo "version: $(image_version)"
  echo "candidates: sha-$SHORT-amd64"
  echo "publishes:"
  publish_tags | sed 's/^/  /'
}

cmd_login() {
  local host=${REGISTRY%%/*}
  [ -n "$REGISTRY_USER" ] || die "no registry user: set GHCR_USER (context ghcr) or REGISTRY_USER"
  [ -n "$REGISTRY_TOKEN" ] || die "no registry token: set GHCR_TOKEN (context ghcr) or REGISTRY_TOKEN"
  printf '%s' "$REGISTRY_TOKEN" | docker login "$host" -u "$REGISTRY_USER" --password-stdin >/dev/null
  echo "logged in to $host as $REGISTRY_USER"
}

ensure_builder() {
  # a docker-container builder: registry cache import/export needs it
  docker buildx inspect reprise >/dev/null 2>&1 \
    || docker buildx create --name reprise --driver docker-container >/dev/null
  docker buildx use reprise
}

cmd_build() {
  local image=${1:?image} arch=${2:?arch} name
  name=$(image_name "$image")
  local ref="$REGISTRY/$name" args=()
  # make sure a tag build fails before an hour of compiling, not after
  publish_tags >/dev/null
  [ "$image" = reprise ] && args+=(--build-arg "KZ_VERSION=$(kz_version)")
  ensure_builder
  echo "building $ref:sha-$SHORT-$arch ($(image_version))"
  docker buildx build \
    --platform "linux/$arch" \
    --file "docker/$image/Dockerfile" \
    --build-arg "IMAGE_VERSION=$(image_version)" \
    --build-arg "IMAGE_REVISION=$SHA" \
    "${args[@]}" \
    --cache-from "type=registry,ref=$ref:buildcache-$arch" \
    --cache-to "type=registry,ref=$ref:buildcache-$arch,mode=max" \
    --tag "$ref:sha-$SHORT-$arch" \
    --push \
    .
}

cmd_promote() {
  local image name tag
  publish_tags >/dev/null
  for image in "${IMAGES[@]}"; do
    name=$(image_name "$image")
    while read -r tag; do
      echo "$REGISTRY/$name:$tag <- sha-$SHORT-amd64"
      docker buildx imagetools create --tag "$REGISTRY/$name:$tag" "$REGISTRY/$name:sha-$SHORT-amd64"
    done < <(publish_tags)
  done
}

case "${1:-}" in
  tags) cmd_tags ;;
  registry) echo "$REGISTRY" ;;
  login) cmd_login ;;
  build) shift; cmd_build "$@" ;;
  promote) cmd_promote ;;
  *) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
