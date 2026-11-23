#!/bin/bash
# Build one or more images locally from this tree.
#   docker/build.sh [reprise|freeswitch|freeswitch-dev|kamailio|monster-ui ...]
# Images are tagged $REGISTRY/reprise[-<image>]:$TAG (defaults: local registry
# prefix "reprise", tag "dev"); the CircleCI pipeline (.circleci/) builds the
# same images for ghcr.io/reprise-voice with the release version. "kazoo" is
# accepted as an older name for "reprise".
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="${REGISTRY:-reprise}"
TAG="${TAG:-dev}"
# The images are built and supported for linux/amd64 only. On a machine of
# another architecture the build runs under emulation, which is slow.
PLATFORM="${PLATFORM:-linux/amd64}"
# REPRISE_GIT_BASE (see make/repos.mk): when set, every image fetches its
# reprise-voice source repositories from there instead of GitHub.
BUILD_ARGS=()
[ -n "${REPRISE_GIT_BASE:-}" ] && BUILD_ARGS+=(--build-arg "REPRISE_GIT_BASE=$REPRISE_GIT_BASE")

IMAGES=("$@")
[ ${#IMAGES[@]} -eq 0 ] && IMAGES=(reprise freeswitch kamailio monster-ui)

for img in "${IMAGES[@]}"; do
  case "$img" in
    reprise|kazoo) name=reprise;                        file=docker/reprise/Dockerfile;    target="" ;;
    freeswitch)            name=reprise-freeswitch;     file=docker/freeswitch/Dockerfile; target="" ;;
    freeswitch-dev)        name=reprise-freeswitch-dev; file=docker/freeswitch/Dockerfile; target="--target build" ;;
    kamailio)              name=reprise-kamailio;       file=docker/kamailio/Dockerfile;   target="" ;;
    monster-ui)            name=reprise-monster-ui;     file=docker/monster-ui/Dockerfile; target="" ;;
    *) echo "unknown image: $img" >&2; exit 1 ;;
  esac
  echo "=== $name:$TAG"
  # shellcheck disable=SC2086
  docker build --platform "$PLATFORM" $target ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} -f "$ROOT/$file" -t "$REGISTRY/$name:$TAG" "$ROOT"
done
