#!/bin/sh
# Runs an install.sh against a fake release served from a temporary directory (serve.py), on the
# machine it runs on. It proves, for the script given:
#   - the success path installs a runnable mopm, from an explicit version and from /latest, and
#     with the script on stdin as in `curl | sh`; it touches no file but $MOPM_HOME/bin/mopm;
#   - each platform name the script maps (uname -s / -m) fetches that platform's file;
#   - a tarball whose sha256 is not the one in SHA256SUMS is refused, and an existing install survives;
#   - a SHA256SUMS that does not list the file (or lists it twice), or no SHA256SUMS, is refused;
#   - a binary that does not report the version it was released as is refused;
#   - an unsupported architecture or OS is refused before anything is requested.
#
#   tests/install_script/run.sh [path/to/install.sh]     (default site/static/install.sh)
#
# tests/install_script/mutants.sh runs this against broken copies of the script and demands red.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
install=${1:-$root/site/static/install.sh}
install=$(cd "$(dirname "$install")" && pwd)/$(basename "$install")

work=$(mktemp -d "${TMPDIR:-/tmp}/mopm-install-test.XXXXXX")
server_pid=
cleanup() {
    [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

targets="linux-x86_64 linux-aarch64 macos-arm64 macos-x86_64"

# make_release <dir> <version> <reported-version>: tarballs of a fake mopm for every target, SHA256SUMS.
make_release() {
    rdir=$1; ver=$2; reported=$3
    mkdir -p "$rdir"
    for t in $targets; do
        d=$work/pkg/mopm-$ver-$t
        mkdir -p "$d"
        printf '#!/bin/sh\necho "mopm %s"\n' "$reported" > "$d/mopm"
        chmod 755 "$d/mopm"
        tar -czf "$rdir/mopm-$ver-$t.tar.gz" -C "$work/pkg" "mopm-$ver-$t"
    done
    "$root/tools/release_sums.sh" "$rdir" > /dev/null
}

# serve <dir>: starts serve.py on a free port; sets base
serve() {
    rm -f "$work/port"
    : > "$work/requests"
    python3 -I "$here/serve.py" "$1" "$work/port" "$work/requests" &
    server_pid=$!
    n=0
    while [ ! -s "$work/port" ]; do
        n=$((n + 1))
        [ "$n" -lt 100 ] || { echo "server did not start" >&2; exit 1; }
        sleep 0.1
    done
    base=http://127.0.0.1:$(cat "$work/port")
}
stop() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=
}

# A uname that reports what FAKE_OS / FAKE_ARCH say.
mkdir -p "$work/shim"
cat > "$work/shim/uname" <<'EOS'
#!/bin/sh
case "$1" in
    -s) echo "$FAKE_OS" ;;
    -m) echo "$FAKE_ARCH" ;;
    *) exec /usr/bin/uname "$@" ;;
esac
EOS
chmod 755 "$work/shim/uname"

# run_install <name> [VAR=value ...]: runs the script in a fresh HOME; output in $work/<name>.out,
# exit status in $status.
run_install() {
    name=$1; shift
    rm -rf "$work/home"; mkdir -p "$work/home"
    set +e
    env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work" MOPM_RELEASES_URL="$base" "$@" \
        sh "$install" > "$work/$name.out" 2>&1
    status=$?
    set -e
}

make_release "$work/rel/1.2.3" 1.2.3 1.2.3
make_release "$work/rel/1.0.0" 1.0.0 1.0.0
serve "$work/rel"
home_bin=$work/home/.mopm/bin/mopm

# 1. Success, explicit version (with and without the v).
for v in 1.2.3 v1.2.3; do
    run_install ok1 MOPM_VERSION=$v
    if [ "$status" -eq 0 ] && [ "$("$home_bin" --version)" = "mopm 1.2.3" ]; then ok "install MOPM_VERSION=$v"
    else fail "install MOPM_VERSION=$v (status $status)"; cat "$work/ok1.out" >&2; fi
done
grep -q 'export PATH=' "$work/ok1.out" || fail "the PATH line is not printed"
found=$(cd "$work/home" && find . | sort | tr '\n' ' ')
[ "$found" = ". ./.mopm ./.mopm/bin ./.mopm/bin/mopm " ] || fail "install touched files other than MOPM_HOME/bin/mopm: $found"

# 2. Success, latest (the newest version in the fake release dir is 1.2.3), and MOPM_HOME.
run_install ok2 MOPM_HOME="$work/custom"
if [ "$status" -eq 0 ] && [ "$("$work/custom/bin/mopm" --version)" = "mopm 1.2.3" ]; then ok "install latest into MOPM_HOME"
else fail "install latest (status $status)"; cat "$work/ok2.out" >&2; fi

# 3. Script on stdin, as in curl | sh.
rm -rf "$work/home"; mkdir -p "$work/home"
if env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work" MOPM_RELEASES_URL="$base" MOPM_VERSION=1.0.0 sh < "$install" > "$work/ok3.out" 2>&1 &&
    [ "$("$home_bin" --version)" = "mopm 1.0.0" ]; then ok "install with the script on stdin"
else fail "install with the script on stdin"; cat "$work/ok3.out" >&2; fi

# 4. Each platform fetches its own file.
for row in Linux:x86_64:linux-x86_64 Linux:amd64:linux-x86_64 Linux:aarch64:linux-aarch64 Linux:arm64:linux-aarch64 \
           Darwin:arm64:macos-arm64 Darwin:x86_64:macos-x86_64; do
    os=${row%%:*}; rest=${row#*:}; arch=${rest%%:*}; want=${rest#*:}
    : > "$work/requests"
    run_install plat FAKE_OS=$os FAKE_ARCH=$arch MOPM_VERSION=1.2.3 PATH="$work/shim:$PATH"
    if [ "$status" -eq 0 ] && grep -q "^/download/v1.2.3/mopm-1.2.3-$want.tar.gz\$" "$work/requests"; then ok "$os $arch -> $want"
    else fail "$os $arch should fetch $want (status $status)"; cat "$work/plat.out" >&2; fi
done

# 5. Unsupported platforms: refused, and nothing is requested.
for row in Linux:riscv64 Linux:i686 Darwin:ppc64 FreeBSD:amd64 Linux:armv7l; do
    os=${row%%:*}; arch=${row#*:}
    : > "$work/requests"
    run_install unsup FAKE_OS=$os FAKE_ARCH=$arch MOPM_VERSION=1.2.3 PATH="$work/shim:$PATH"
    if [ "$status" -ne 0 ] && grep -q 'no mopm release for' "$work/unsup.out" && [ ! -s "$work/requests" ] && [ ! -e "$home_bin" ]; then
        ok "$os $arch refused"
    else fail "$os $arch was not refused cleanly (status $status)"; cat "$work/unsup.out" >&2; fi
done
stop

# 6. A tampered tarball (SHA256SUMS is the original's) is refused; an existing install survives.
cp -R "$work/rel" "$work/tampered"
for t in $targets; do
    d=$work/evil/mopm-1.2.3-$t
    mkdir -p "$d"
    printf '#!/bin/sh\necho "mopm 1.2.3"\necho pwned\n' > "$d/mopm"
    chmod 755 "$d/mopm"
    tar -czf "$work/tampered/1.2.3/mopm-1.2.3-$t.tar.gz" -C "$work/evil" "mopm-1.2.3-$t"
done
serve "$work/tampered"
rm -rf "$work/home"; mkdir -p "$work/home/.mopm/bin"
printf '#!/bin/sh\necho previous\n' > "$home_bin"; chmod 755 "$home_bin"
set +e
env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work" MOPM_RELEASES_URL="$base" MOPM_VERSION=1.2.3 sh "$install" > "$work/tamper.out" 2>&1
status=$?
set -e
if [ "$status" -ne 0 ] && grep -q 'sha256 mismatch' "$work/tamper.out" && [ "$("$home_bin")" = previous ]; then ok "tampered tarball refused, previous install kept"
else fail "tampered tarball (status $status)"; cat "$work/tamper.out" >&2; fi
stop

# 7. SHA256SUMS that does not list the tarball, one that lists it twice, and none at all.
cp -R "$work/rel" "$work/nolist"
grep -v 'mopm-1.2.3-' "$work/nolist/1.2.3/SHA256SUMS" > "$work/S" || true
mv "$work/S" "$work/nolist/1.2.3/SHA256SUMS"
cp -R "$work/rel" "$work/twice"
cat "$work/twice/1.2.3/SHA256SUMS" "$work/twice/1.2.3/SHA256SUMS" > "$work/S"
mv "$work/S" "$work/twice/1.2.3/SHA256SUMS"
cp -R "$work/rel" "$work/nosums"
rm "$work/nosums/1.2.3/SHA256SUMS"
for c in nolist twice nosums; do
    serve "$work/$c"
    run_install "$c" MOPM_VERSION=1.2.3
    if [ "$status" -ne 0 ] && [ ! -e "$home_bin" ]; then ok "SHA256SUMS case $c refused"
    else fail "SHA256SUMS case $c was not refused (status $status)"; cat "$work/$c.out" >&2; fi
    stop
done

# 8. A binary that reports another version than the release is refused.
make_release "$work/liar/1.2.3" 1.2.3 9.9.9
serve "$work/liar"
run_install liar MOPM_VERSION=1.2.3
if [ "$status" -ne 0 ] && [ ! -e "$home_bin" ] && grep -q "did not report 'mopm 1.2.3'" "$work/liar.out"; then ok "wrong-version binary refused"
else fail "wrong-version binary (status $status)"; cat "$work/liar.out" >&2; fi
stop

# 9. No release at all: /latest finds nothing.
mkdir "$work/empty"
serve "$work/empty"
run_install empty
if [ "$status" -ne 0 ] && [ ! -e "$home_bin" ]; then ok "no release refused"
else fail "no release (status $status)"; cat "$work/empty.out" >&2; fi
stop

if [ "$failures" -ne 0 ]; then echo "$failures check(s) failed" >&2; exit 1; fi
echo "all install.sh checks passed"
