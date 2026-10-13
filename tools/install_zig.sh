#!/bin/sh
# Install the pinned Zig into the directory given as $1 and print its bin dir.
# The tarball is checked against a pinned sha256 before it is unpacked.
set -eu
ver=0.12.0
dest=${1:?usage: tools/install_zig.sh <dest-dir>}

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        triple=linux-x86_64
        sha=c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad ;;
    Linux-aarch64|Linux-arm64)
        triple=linux-aarch64
        sha=754f1029484079b7e0ca3b913a0a2f2a6afd5a28990cb224fe8845e72f09de63 ;;
    Darwin-arm64)
        triple=macos-aarch64
        sha=294e224c14fd0822cfb15a35cf39aa14bd9967867999bf8bdfe3db7ddec2a27f ;;
    *) echo "install_zig: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

name=zig-$triple-$ver
mkdir -p "$dest"
curl -fsSL --retry 3 -o "$dest/zig.tar.xz" "https://ziglang.org/download/$ver/$name.tar.xz"
if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$dest/zig.tar.xz" | cut -d' ' -f1)
else
    got=$(shasum -a 256 "$dest/zig.tar.xz" | cut -d' ' -f1)
fi
if [ "$got" != "$sha" ]; then
    echo "install_zig: sha256 mismatch: got $got, want $sha" >&2
    exit 1
fi
tar -xJf "$dest/zig.tar.xz" -C "$dest"
echo "$dest/$name"
