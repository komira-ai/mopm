#!/bin/sh
# Build the mopm CLI for one release target and package it. Run from the repository root with the
# pinned Zig (tools/install_zig.sh) on PATH.
#
#   tools/release_package.sh <version> <target> <zig-target> <outdir>
#
#   version     what `mopm --version` must report (1.2.3, no leading v); the build is refused otherwise
#   target      the name in the file: linux-x86_64, linux-aarch64, macos-arm64, macos-x86_64
#   zig-target  zig's -Dtarget (x86_64-linux-musl, aarch64-linux-musl, aarch64-macos, x86_64-macos)
#   outdir      receives mopm-<version>-<target>.tar.gz, holding mopm-<version>-<target>/{mopm,LICENSE}
#
# RUN_PREFIX, if set, is put before the binary to run it (arch -x86_64 for the Intel macOS build on
# an arm64 runner). Nothing here uploads anything.
set -eu
version=${1:?usage: tools/release_package.sh <version> <target> <zig-target> <outdir>}
target=${2:?target}
zig_target=${3:?zig-target}
outdir=${4:?outdir}

name=mopm-$version-$target
stage=$outdir/stage
mkdir -p "$outdir" "$stage/$name"

zig build -Doptimize=ReleaseSafe -Dtarget="$zig_target" -Dstrip=true -p "$stage/prefix"
cp "$stage/prefix/bin/mopm" "$stage/$name/mopm"
cp LICENSE "$stage/$name/LICENSE"

# shellcheck disable=SC2086 # RUN_PREFIX is a command prefix of several words
reported=$(${RUN_PREFIX:-} "$stage/$name/mopm" --version)
if [ "$reported" != "mopm $version" ]; then
    echo "release_package: the binary reports '$reported', not 'mopm $version'; refusing to package" >&2
    exit 1
fi

tar -cf - -C "$stage" "$name" | gzip -n > "$outdir/$name.tar.gz"
rm -rf "$stage"
echo "packaged $outdir/$name.tar.gz ($reported)"
