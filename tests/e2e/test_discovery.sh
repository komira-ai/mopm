#!/bin/sh
# Superseded by //:discovery (tests/drivers/test_discovery_test.zig) on the build farm, which has no shell, Python or pixi;
# kept for ci.yml until farm.yml has matched it. Change both together.
# End-to-end test of `mopm test --list` against the real Mojo toolchain. Run
# from the repository root:
#
#   tests/e2e/test_discovery.sh <mopm binary> <Mojo environment prefix> <work dir>
#
# tests/e2e/testpkg is a package with three test files, one of each kind:
# a bare file (mopm generates its main), a self-hosted file registering its
# tests explicitly, and a self-hosted file using TestSuite.discover_tests;
# plus files outside the convention. testpkg/expected.txt is the list.
#
#   1. `mopm test --list` (sources only) prints exactly expected.txt;
#   2. `mopm test --list --check --strict-discovery` builds every file (the
#      bare one through its generated harness) with `mopm build`, runs each
#      binary with --skip-all, finds no difference and prints the same list;
#   3. independently of mopm's own comparison, this script runs each built
#      binary with --skip-all itself and compares the names with
#      expected.txt; and checks the harness starts with the test file
#      unchanged;
#   4. the harness runs one test per `--only <name>`: `--only test_one`
#      passes and runs nothing else; `--only test_raises` fails; no argument
#      runs all four (one fails);
#   5. tests/e2e/testpkg_mismatch registers a test only at run time, so the
#      scan lists a test the binary does not: --check warns (exit 0) and
#      --check --strict-discovery refuses (exit 2, nothing on stdout).
set -u

if [ $# -ne 3 ]; then
    echo "usage: tests/e2e/test_discovery.sh <mopm> <mojo env prefix> <work dir>" >&2
    exit 2
fi
mopm=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
prefix=$(cd "$2" && pwd -P)
mkdir -p "$3"
work=$(cd "$3" && pwd -P)
here=$(pwd -P)/tests/e2e
fail=0
esc=$(printf '\033')

pass() { echo "ok   $*"; }
flunk() {
    echo "FAIL $*"
    fail=1
}
# show <file>: indented, without colour codes or the crash-reporter notice.
show() {
    plain < "$1" | grep -v "Failed to initialize Crashpad" | sed 's/^/     | /'
}
plain() {
    sed "s/${esc}\[[0-9;]*m//g"
}

echo "== mojo: $(MODULAR_HOME="$prefix/share/max" "$prefix/bin/mojo" --version 2>&1)"

[ -d "$work/testpkg" ] && { echo "work dir $work already holds testpkg" >&2; exit 2; }
cp -R "$here/testpkg" "$work/testpkg"
cp -R "$here/testpkg_mismatch" "$work/testpkg_mismatch"
cd "$work/testpkg" || exit 1
expected=$work/testpkg/expected.txt

# ---------------------------------------------------------------- 1
"$mopm" test --list > list.out 2> list.err
rc=$?
if [ "$rc" -eq 0 ] && diff -u "$expected" list.out && [ ! -s list.err ]; then
    pass "mopm test --list prints expected.txt"
else
    flunk "mopm test --list (exit $rc); stderr:"
    show list.err
fi

# ---------------------------------------------------------------- 2
"$mopm" test --list --check --strict-discovery --prefix "$prefix" > check.out 2> check.err
rc=$?
if [ "$rc" -eq 0 ] && diff -u "$expected" check.out; then
    pass "mopm test --list --check --strict-discovery: built, listed, no difference"
else
    flunk "mopm test --list --check --strict-discovery (exit $rc); stderr:"
    show check.err
fi

# ---------------------------------------------------------------- 3
# bin <stem>: the binary mopm built for the test file named <stem>.mojo.
bin() {
    n=$(find target/mopm/bin -type f -name "$1" | wc -l | tr -d ' ')
    if [ "$n" = 1 ]; then find target/mopm/bin -type f -name "$1"; fi
}

for f in tests/test_bare.mojo tests/sub/test_registered.mojo src/testpkg/tests/test_discovered.mojo; do
    stem=$(basename "$f" .mojo)
    b=$(bin "$stem")
    if [ -z "$b" ]; then
        flunk "$f: no single built binary named $stem under target/mopm/bin"
        continue
    fi
    "$b" --skip-all > "skip_$stem.out" 2>&1
    rc=$?
    plain < "skip_$stem.out" | sed -n 's/^ *SKIP \[ [0-9.]* \] //p' | sort > "skip_$stem.names"
    grep "^$f::" "$expected" | sed 's/.*:://' | sort > "want_$stem.names"
    if [ "$rc" -eq 0 ] && [ -s "want_$stem.names" ] && cmp -s "want_$stem.names" "skip_$stem.names"; then
        pass "$f: the binary's own --skip-all lists exactly the expected tests"
    else
        flunk "$f: --skip-all (exit $rc) differs from expected.txt; output:"
        show "skip_$stem.out"
    fi
done

harness=$(find target/mopm/gen -type f -name test_bare.mojo | head -n 1)
src_lines=$(wc -l < tests/test_bare.mojo | tr -d ' ')
if [ -n "$harness" ] && head -n "$src_lines" "$harness" | cmp -s - tests/test_bare.mojo &&
    grep -q "^    suite.test\[test_raises\]()$" "$harness" && ! grep -q "suite.test\[test_helper\]" "$harness"; then
    pass "the harness is the bare file unchanged, then a main registering its tests"
else
    flunk "the harness ($harness) does not start with tests/test_bare.mojo or registers the wrong functions"
fi
[ -z "$(find target/mopm/gen -type f -name 'test_registered.mojo')" ] ||
    flunk "a harness was generated for a self-hosted file"

# ---------------------------------------------------------------- 4
bare=$(bin test_bare)
# count <file> <PASS|FAIL>: result lines of that kind.
count() {
    plain < "$1" | grep -c "^ *$2 \[ "
}
if [ -n "$bare" ]; then
    "$bare" --only test_one > only_one.out 2>&1
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$(count only_one.out PASS)" -eq 1 ] && [ "$(count only_one.out FAIL)" -eq 0 ] &&
        plain < only_one.out | grep -q "^ *PASS \[ [0-9.]* \] test_one$"; then
        pass "harness --only test_one runs that one test and passes"
    else
        flunk "harness --only test_one (exit $rc); output:"
        show only_one.out
    fi
    "$bare" --only test_raises > only_raises.out 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$(count only_raises.out PASS)" -eq 0 ] &&
        plain < only_raises.out | grep -q "^ *FAIL \[ [0-9.]* \] test_raises$" && grep -q "planted" only_raises.out; then
        pass "harness --only test_raises runs that one test and fails"
    else
        flunk "harness --only test_raises (exit $rc, want non-zero); output:"
        show only_raises.out
    fi
    "$bare" > all.out 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$(count all.out PASS)" -eq 3 ] && [ "$(count all.out FAIL)" -eq 1 ]; then
        pass "the harness with no argument runs all four tests (three pass, one fails)"
    else
        flunk "harness without arguments (exit $rc); output:"
        show all.out
    fi
else
    flunk "no binary for tests/test_bare.mojo"
fi

# ---------------------------------------------------------------- 5
cd "$work/testpkg_mismatch" || exit 1
f=tests/test_hidden_registration.mojo
"$mopm" test --list --check --prefix "$prefix" > warn.out 2> warn.err
rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat warn.out)" = "$(printf '%s\n' "$f::test_listed" "$f::test_never_registered")" ] &&
    grep -q "^mopm test: warning: $f: the scan and the \`--skip-all\` listing of the built file differ" warn.err &&
    grep -q "only in the scan: *test_never_registered$" warn.err; then
    pass "a self-hosted file whose listing differs: a warning, the scanned list, exit 0"
else
    flunk "mismatch without --strict-discovery (exit $rc, want 0); stdout and stderr:"
    show warn.out
    show warn.err
fi
"$mopm" test --list --check --strict-discovery --prefix "$prefix" > strict.out 2> strict.err
rc=$?
if [ "$rc" -eq 2 ] && [ ! -s strict.out ] &&
    grep -q "^mopm test: $f: the scan and the \`--skip-all\` listing of the built file differ" strict.err &&
    grep -q "only in the scan: *test_never_registered$" strict.err; then
    pass "the same file with --strict-discovery: refused, exit 2, nothing listed"
else
    flunk "mismatch with --strict-discovery (exit $rc, want 2); stdout and stderr:"
    show strict.out
    show strict.err
fi

exit "$fail"
