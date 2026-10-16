#!/bin/sh
# Write <dir>/SHA256SUMS for every mopm-*.tar.gz in <dir>, then check it. Used by release.yml and
# its dry run (release-check.yml), and by tests/install_script to build a fake release.
set -eu
dir=${1:?usage: tools/release_sums.sh <dir>}
cd "$dir"
set -- mopm-*.tar.gz
[ -f "$1" ] || { echo "release_sums: no mopm-*.tar.gz in $dir" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" > SHA256SUMS
    sha256sum -c SHA256SUMS
else
    shasum -a 256 "$@" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
fi
