#!/bin/sh
# Copyright (C) 2026 Vonix LLC
# SPDX-License-Identifier: MPL-2.0
# Run inside a Linux FreeSWITCH dev environment. The source stays untouched.
set -eu
reprise_source=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
reprise_build=$(mktemp -d)
trap 'rm -rf "$reprise_build"' EXIT HUP INT TERM
mkdir -p "$reprise_build/tests"
cp -R "$reprise_source/src" "$reprise_source/Makefile" "$reprise_build/"
cp "$reprise_source"/tests/*.c "$reprise_source"/tests/*.h "$reprise_build/tests/"
cp -R "$reprise_source/tests/fixtures" "$reprise_source/tests/conf" "$reprise_build/tests/"
cd "$reprise_build"
# libfreeswitch is not instrumented; this checks module code and intercepted
# allocations, not the entire dependency stack. Leak checking is a separate run.
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1}"
reprise_cc="${CC:-gcc} -g -O1 -fno-omit-frame-pointer -fsanitize=address,undefined -DREPRISE_ALLOC_TEST -Wl,--wrap=realloc"
make -j2 CC="$reprise_cc" reprise_test reprise_endpoint_test
make CC="$reprise_cc" test
