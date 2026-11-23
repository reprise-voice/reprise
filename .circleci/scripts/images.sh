#!/usr/bin/env bash
# Image build and publishing for .circleci/config.yml.
#
#   images.sh tags                    print the version and the tags this pipeline publishes
#   images.sh registry                print the registry namespace the images go to
#   images.sh login                   docker login ghcr.io with GHCR_USER / GHCR_TOKEN
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
# CircleCI it is ghcr.io/reprise-voice. REGISTRY overrides both.
set -euo pipefail

cd "$(dirname "$0")/../.."

OWNER=$(printf '%s' "${CIRCLE_PROJECT_USERNAME:-reprise-voice}" | tr '[:upper:]' '[:lower:]')
REGISTRY=${REGISTRY:-ghcr.io/$OWNER}
SHA=${CIRCLE_SHA1:-$(git rev-parse HEAD)}
SHORT=${SHA:0:7}
GIT_TAG=${CIRCLE_TAG:-}
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
publish_tags() {
  if [ -n "$GIT_TAG" ]; then
    [ "$GIT_TAG" = "v$VERSION" ] \
      || die "tag $GIT_TAG does not match VERSION ($VERSION): tag v$VERSION, or fix VERSION"
    echo "$VERSION"
    case "$VERSION" in
      *-*) ;;  # a pre-release: no moving tags
      *) echo "${VERSION%.*}"; echo latest ;;
    esac
  elif [ "$BRANCH" = main ]; then
    echo edge
  fi
  echo "sha-$SHORT"
}

image_version() {
  if [ -n "$GIT_TAG" ]; then echo "$VERSION"; else echo "$VERSION-dev.$SHORT"; fi
}

cmd_tags() {
  publish_tags >/dev/null
  echo "version: $(image_version)"
  echo "candidates: sha-$SHORT-amd64"
  echo "publishes:"
  publish_tags | sed 's/^/  /'
}

cmd_login() {
  : "${GHCR_USER:?GHCR_USER is not set (CircleCI context ghcr)}"
  : "${GHCR_TOKEN:?GHCR_TOKEN is not set (CircleCI context ghcr)}"
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
  echo "logged in to ghcr.io as $GHCR_USER"
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
  [ "$image" = reprise ] && args+=(--build-arg "KZ_VERSION=$VERSION")
  # make sure a tag build fails before an hour of compiling, not after
  publish_tags >/dev/null
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
