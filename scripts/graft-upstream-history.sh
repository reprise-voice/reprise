#!/usr/bin/env bash
# scripts/graft-upstream-history.sh [--undo] [--archive URL] [--ref REV]
#
# Connects the baseline commits of this repository to the upstream Kazoo
# history they were taken from, so that `git blame` and `git log` walk into
# 2600Hz's commits. Run it inside a clone of this repository.
#
# Each baseline commit's message lists its sources, one per line:
#   Upstream: <prefix> <repository URL> <commit SHA>
# The script fetches those commits from the Kazoo archive (default
# https://github.com/reprise-voice/kazoo-archive, which mirrors
# 2600hz/kazoo5 and the component repositories at exactly those commits)
# and uses `git replace --graft` to give each baseline commit its upstream
# commits as additional parents.
#
# Only local refs change: refs/replace/* (not pushed or fetched by default)
# and refs/upstream-archive/* holding the fetched history. --undo removes
# both. Nothing is pushed.
#
# Across a prefix (a component's root becoming applications/<name>/) git
# follows a file by exact rename detection, which needs no raised rename
# limit because the baseline content is byte-identical to upstream.
# `git blame <file>` works as is; for `git log --follow` add -m, because the
# grafted baseline commits are merges:  git log --follow -m -- <file>
set -euo pipefail

archive=${KAZOO_ARCHIVE_URL:-https://github.com/reprise-voice/kazoo-archive}
ref=HEAD
undo=0
while [ $# -gt 0 ]; do
  case $1 in
    --undo) undo=1 ;;
    --archive) archive=$2; shift ;;
    --ref) ref=$2; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

git rev-parse --git-dir >/dev/null

if [ $undo = 1 ]; then
  n=0
  for r in $(git for-each-ref --format='%(refname)' refs/replace/); do
    git update-ref -d "$r"; n=$((n+1))
  done
  for r in $(git for-each-ref --format='%(refname)' refs/upstream-archive/); do
    git update-ref -d "$r"
  done
  echo "removed $n replace refs and the fetched archive refs"
  exit 0
fi

# Baseline commits: those whose message carries Upstream: lines.
# (--no-replace-objects: read the original commits even if grafted before.)
mapfile -t baselines < <(git --no-replace-objects log --format=%H --grep='^Upstream: ' "$ref")
[ ${#baselines[@]} -gt 0 ] || { echo "no commit with Upstream: lines in $ref" >&2; exit 1; }

declare -A parents_of
shas=()
for c in "${baselines[@]}"; do
  ups=$(git --no-replace-objects log -1 --format=%B "$c" |
        awk '$1=="Upstream:" && NF==4 && $4 ~ /^[0-9a-f]{40}$/ {print $4}')
  parents_of[$c]=$ups
  shas+=($ups)
done

missing=()
for s in "${shas[@]}"; do git cat-file -e "$s^{commit}" 2>/dev/null || missing+=("$s"); done
if [ ${#missing[@]} -gt 0 ]; then
  echo "fetching ${#missing[@]} upstream commits from $archive" >&2
  git fetch --no-tags "$archive" '+refs/heads/*:refs/upstream-archive/*'
  for s in "${missing[@]}"; do
    git cat-file -e "$s^{commit}" 2>/dev/null || { echo "ERROR: $s not in $archive" >&2; exit 1; }
  done
fi

for c in "${baselines[@]}"; do
  own=$(git --no-replace-objects log -1 --format=%P "$c")
  # shellcheck disable=SC2086
  git replace -f --graft "$c" $own ${parents_of[$c]}
  echo "grafted ${c:0:12} <- $(echo ${parents_of[$c]} | wc -w) upstream commit(s)"
done
echo "done; undo with: $0 --undo"
