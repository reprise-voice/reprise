#!/bin/bash
# ./check-gleam-manifests.bash [manifest.toml ...]
# Fails when two Gleam packages in this tree lock a package they both depend
# on to different versions. Each Gleam application installs its whole shipment
# into deps/<app>, so a disagreement means the last application built decides
# which version the release runs. Reads the checked-in manifests only; needs
# no gleam binary.

set -euo pipefail

if [ "$#" -lt 2 ]; then
    exit 0
fi

awk '
/^packages = \[/ { in_packages = 1; next }
in_packages && /^\]/ { in_packages = 0; next }
!in_packages { next }

{
    if (!match($0, /name = "[^"]+"/)) { next }
    name = substr($0, RSTART + 8, RLENGTH - 9)

    if (!match($0, /version = "[^"]+"/)) { next }
    version = substr($0, RSTART + 11, RLENGTH - 12)

    if (!(name in locked)) {
        locked[name] = version
        first[name] = FILENAME
        next
    }

    if (locked[name] != version) {
        printf "%s: locked at %s by %s and at %s by %s\n" \
            ,name, locked[name], first[name], version, FILENAME
        disagreed = 1
    }
}

END {
    if (disagreed) {
        print ""
        print "The Gleam packages disagree on a shared dependency. Line up the"
        print "requirements in the gleam.toml files, re-resolve with"
        print "`gleam update <package>` in each, and commit the manifests."
        exit 1
    }
}
' "$@"
