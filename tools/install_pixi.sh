#!/bin/sh
# Install the pinned pixi into the directory given as $1 and print that
# directory (it holds the pixi binary). The tarball is checked against a
# pinned sha256 before it is unpacked. Used by CI to create the Mojo
# environment the end-to-end tests run in (tests/e2e).
set -eu
ver=0.79.0
dest=${1:?usage: tools/install_pixi.sh <dest-dir>}

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        triple=x86_64-unknown-linux-musl
        sha=b9b6dd2bdf4e0043c2c0cd6d15334a26c6851121bf5ae16c39b69add598bafdc ;;
    Linux-aarch64|Linux-arm64)
        triple=aarch64-unknown-linux-musl
        sha=a402a2a3e2c785b7855c482db46d65a915c0ac04fdf041410f218980a5247290 ;;
    Darwin-arm64)
        triple=aarch64-apple-darwin
        sha=652d1d8380fa40feaa75b4ccee3a1f0b32e20a6fa2fdd84bb8e3c52962b8dc34 ;;
    *) echo "install_pixi: unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$dest"
curl -fsSL --retry 3 -o "$dest/pixi.tar.gz" "https://github.com/prefix-dev/pixi/releases/download/v$ver/pixi-$triple.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$dest/pixi.tar.gz" | cut -d' ' -f1)
else
    got=$(shasum -a 256 "$dest/pixi.tar.gz" | cut -d' ' -f1)
fi
if [ "$got" != "$sha" ]; then
    echo "install_pixi: sha256 mismatch: got $got, want $sha" >&2
    exit 1
fi
tar -xzf "$dest/pixi.tar.gz" -C "$dest"
rm -f "$dest/pixi.tar.gz"
echo "$dest"
