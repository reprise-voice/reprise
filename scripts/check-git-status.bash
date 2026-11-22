#!/bin/bash
# ./check-git-status.bash [directories]
# Prints the porcelain status of the given directories (absolute paths)

set -e

pushd "$(dirname "$0")" > /dev/null

ROOT=$(cd "$(pwd -P)"/.. && pwd -P)

statuses=""
for directory in "$@"; do
    if [ -d "$directory" ]; then
        dir_status=$(git -C "$ROOT" status --porcelain -uno -- "$directory")
        if [ -n "$dir_status" ]; then
            statuses+="$directory:\n$dir_status\n"
        fi
    fi
done

echo -e "$statuses"
