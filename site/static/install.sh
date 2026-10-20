#!/bin/sh
# mopm installer: https://mopm.dev/install.sh
#
#   curl -fsSL https://mopm.dev/install.sh | sh
#
# Downloads the mopm release for this machine from GitHub releases, checks its
# sha256 against the release's SHA256SUMS, and installs it as
# $MOPM_HOME/bin/mopm (default ~/.mopm/bin/mopm). It needs no root, edits no
# shell startup file, and stops without installing anything if a check fails.
#
#   MOPM_VERSION       install this version (1.2.3 or v1.2.3) instead of the latest
#   MOPM_HOME          install under this directory instead of ~/.mopm
#   MOPM_RELEASES_URL  where releases are read from (for a mirror or a test);
#                      default https://github.com/komira-ai/mopm/releases
#
# To check a download further (the release notes repeat this; RELEASING.md has the details), for a file F of the release:
#   gh attestation verify F -R komira-ai/mopm --signer-workflow komira-ai/mopm/.github/workflows/release.yml
#   cosign verify-blob --bundle F.sigstore.json --certificate-identity \
#     https://github.com/komira-ai/mopm/.github/workflows/release.yml@refs/heads/main \
#     --certificate-oidc-issuer https://token.actions.githubusercontent.com F
# This script checks the sha256 only. macOS binaries are not yet code-signed or notarized by Apple.
#
# Needs curl, tar, awk and sha256sum or shasum. Linux (x86_64, aarch64; static
# binaries) and macOS (arm64, x86_64).
set -eu

releases=${MOPM_RELEASES_URL:-https://github.com/komira-ai/mopm/releases}
home=${MOPM_HOME:-${HOME:?HOME is not set; set MOPM_HOME}/.mopm}

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

for tool in curl tar awk; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required but was not found"
done

# The platform, as the release files name it.
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-amd64) target=linux-x86_64 ;;
    Linux-aarch64|Linux-arm64) target=linux-aarch64 ;;
    Darwin-arm64) target=macos-arm64 ;;
    Darwin-x86_64) target=macos-x86_64 ;;
    *) die "no mopm release for $(uname -s) $(uname -m); there are releases for Linux and macOS on x86_64 and arm64" ;;
esac

# The version: MOPM_VERSION, else the tag that <releases>/latest redirects to.
if [ -n "${MOPM_VERSION:-}" ]; then
    tag=v${MOPM_VERSION#v}
else
    url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$releases/latest") ||
        die "could not look up the latest release at $releases/latest"
    tag=${url##*/}
fi
case "$tag" in
    v[0-9]*) ;;
    *) die "no mopm release found (got '$tag'); name one with MOPM_VERSION" ;;
esac
case "$tag" in
    *[!0-9A-Za-z.+_-]*) die "'$tag' is not a version" ;;
esac
version=${tag#v}
name=mopm-$version-$target
asset=$name.tar.gz

tmp=$(mktemp -d "${TMPDIR:-/tmp}/mopm-install.XXXXXX") || die "could not make a temporary directory"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "Installing mopm $version ($target)"
curl -fsSL --retry 3 -o "$tmp/$asset" "$releases/download/$tag/$asset" ||
    die "could not download $releases/download/$tag/$asset"
curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" "$releases/download/$tag/SHA256SUMS" ||
    die "could not download $releases/download/$tag/SHA256SUMS"

# The sha256 the release lists for this file: exactly one 64-digit hex entry.
want=$(awk -v f="$asset" '$2 == f { print $1 }' "$tmp/SHA256SUMS")
case "$want" in
    ""|*[!0-9a-f]*) die "SHA256SUMS does not list $asset exactly once" ;;
esac
[ "${#want}" -eq 64 ] || die "SHA256SUMS has a malformed entry for $asset"

if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$tmp/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "$tmp/$asset" | awk '{ print $1 }')
else
    die "sha256sum or shasum is required to check the download"
fi
[ "$got" = "$want" ] || die "sha256 mismatch for $asset: got $got, SHA256SUMS says $want; nothing was installed"

mkdir "$tmp/x"
tar -xzf "$tmp/$asset" -C "$tmp/x" || die "could not unpack $asset"
[ -f "$tmp/x/$name/mopm" ] || die "$asset does not contain $name/mopm"

mkdir -p "$home/bin"
cp "$tmp/x/$name/mopm" "$home/bin/.mopm.new.$$"
chmod 755 "$home/bin/.mopm.new.$$"
if [ "$("$home/bin/.mopm.new.$$" --version 2>/dev/null)" != "mopm $version" ]; then
    rm -f "$home/bin/.mopm.new.$$"
    die "the downloaded binary did not report 'mopm $version'; nothing was installed"
fi
mv -f "$home/bin/.mopm.new.$$" "$home/bin/mopm"

echo "Installed $home/bin/mopm"
case ":$PATH:" in
    *":$home/bin:"*) ;;
    *)
        echo "Add it to your PATH (put this line in your shell's startup file):"
        echo "  export PATH=\"$home/bin:\$PATH\""
        ;;
esac
