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

[ "$("$mopm" --version)" = "mopm 0.0.1" ] || { echo "FAIL --version"; fail=1; }
"$mopm" build > /dev/null 2>&1 && { echo "FAIL planned command should exit non-zero"; fail=1; }
"$mopm" build 2>&1 | grep -q "not implemented yet" || { echo "FAIL planned command message"; fail=1; }
exit "$fail"
