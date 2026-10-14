#!/bin/sh
# Run `mopm link-plan` on each fixture set and diff against tests/golden.
# Usage: tests/run_golden.sh [path-to-mopm]   (run from the repository root)
set -u
mopm=${1:-./zig-out/bin/mopm}
fail=0

# case <name> <expected exit code> <package>...
check() {
    name=$1
    want=$2
    shift 2
    files=""
    for p in "$@"; do files="$files tests/fixtures/$name/$p.mopm.json"; done
    # shellcheck disable=SC2086
    "$mopm" link-plan $files > "golden_$name.out"
    rc=$?
    if [ "$rc" -ne "$want" ]; then
        echo "FAIL $name: exit $rc, want $want"
        fail=1
    fi
    if ! diff -u "tests/golden/$name.txt" "golden_$name.out"; then
        echo "FAIL $name: output differs from tests/golden/$name.txt"
        fail=1
    else
        echo "ok   $name"
    fi
    rm -f "golden_$name.out"
}

check chain 0 http_client crypto
check missing 1 http_client
check dup 1 pkg_a pkg_b
check static 1 staticpkg

# mopm metadata: a manifest that is accepted prints its JSON; one that is refused
# exits non-zero with path:line:column and the message.
if "$mopm" metadata tests/manifest/valid/full.toml > metadata.out; then
    diff -u tests/manifest/valid/full.json metadata.out || { echo "FAIL metadata output"; fail=1; }
else
    echo "FAIL metadata refused tests/manifest/valid/full.toml"; fail=1
fi
rm -f metadata.out
bad=tests/manifest/invalid/duplicate_key
if got=$("$mopm" metadata "$bad.toml" 2>&1 >/dev/null); then
    echo "FAIL metadata accepted $bad.toml"; fail=1
fi
[ "$got" = "mopm: $bad.toml:$(cat "$bad.err")" ] || { echo "FAIL metadata error text: $got"; fail=1; }

# mopm new / init: the trees they make equal tests/new/{lib,bin}; an existing
# package is never overwritten; a Mojo keyword is refused as a name.
work=$(mktemp -d)
abs_mopm=$(cd "$(dirname "$mopm")" && pwd)/$(basename "$mopm")
( cd "$work" && "$abs_mopm" new demo > /dev/null ) || { echo "FAIL new demo"; fail=1; }
diff -r tests/new/lib "$work/demo" || { echo "FAIL new demo: tree differs from tests/new/lib"; fail=1; }
( cd "$work" && "$abs_mopm" new demo > /dev/null 2>&1 ) && { echo "FAIL new over an existing directory"; fail=1; }
mkdir -p "$work/bin/demo"
( cd "$work/bin/demo" && "$abs_mopm" init --bin > /dev/null ) || { echo "FAIL init --bin"; fail=1; }
diff -r tests/new/bin "$work/bin/demo" || { echo "FAIL init --bin: tree differs from tests/new/bin"; fail=1; }
( cd "$work/bin/demo" && "$abs_mopm" init --bin > /dev/null 2>&1 ) && { echo "FAIL init over an existing package"; fail=1; }
( cd "$work" && "$abs_mopm" new async > /dev/null 2>&1 ) && { echo "FAIL new accepted a keyword as a name"; fail=1; }
[ -e "$work/async" ] && { echo "FAIL new made a directory for a refused name"; fail=1; }
rm -rf "$work"

[ "$("$mopm" --version)" = "mopm 0.0.1" ] || { echo "FAIL --version"; fail=1; }
"$mopm" build > /dev/null 2>&1 && { echo "FAIL planned command should exit non-zero"; fail=1; }
"$mopm" build 2>&1 | grep -q "not implemented yet" || { echo "FAIL planned command message"; fail=1; }
exit "$fail"
