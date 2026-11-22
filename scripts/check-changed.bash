#!/bin/bash
# ./check-changed.bash [directories]
# Prints the files changed against the base branch (.base_branch at the root)
# under the given directories (absolute paths), one tree: this is a monorepo.
# Prints nothing (quietly) outside a git checkout, e.g. in a docker build.

set -e

pushd "$(dirname "$0")" > /dev/null

ROOT=$(cd "$(pwd -P)"/.. && pwd -P)

_ci_debug() {
    msg="$1"
    if [ -n "${DEBUG}" ]; then
        echo "${msg}" >&2
    elif [ -n "${CIRCLECI}" ]; then
        echo "${msg}" >&2
    fi
}

git -C "$ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1 || exit 0

base_branch=$(<"$ROOT/.base_branch")
_ci_debug "Checking for any changed files (base_branch=${base_branch})"
_ci_debug "ROOT=${ROOT}"

if ! git -C "$ROOT" rev-parse --verify --quiet "$base_branch" > /dev/null; then
    _ci_debug "base branch ${base_branch} is not available, nothing to compare against"
    exit 0
fi

changed=""
for file in $(git -C "$ROOT" --no-pager diff --name-only HEAD "$base_branch"); do
    path="$ROOT/$file"
    for directory in "$@"; do
        case "$path" in
            "${directory%/}"/*) changed+=" $path"; break ;;
        esac
    done
done

echo "$changed"
