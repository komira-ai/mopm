#!/bin/sh
# End-to-end test of `mopm test` running tests, against the real Mojo
# toolchain. Run from the repository root:
#
#   tests/e2e/test_supervisor.sh <mopm binary> <Mojo environment prefix> <work dir>
#
# tests/e2e/supervise is a package whose tests each must get one exact
# verdict (the comment above each test names it): pass, an assertion and a
# raise (FAIL), libc abort (CRASH SIGABRT), a null read (CRASH SIGSEGV), a
# test after the crashes (PASS), a sleep (TIMEOUT hung) that also leaves a
# `sleep 7919` behind in its process group, 4 s of computing under a 6 s
# deadline (PASS), endless computing (TIMEOUT slow), an early _exit(0)
# (FAIL), 1 GiB touched under a 512 MiB cap (OOM), a test calling a native
# library (PASS), and a self-hosted file (PASS).
#
#   1. installs the package greet (libgreet, as in tests/e2e/run.sh) into
#      the environment, so test_native.mojo links only if mopm test builds
#      with the link arguments of `mopm build`;
#   2. runs `mopm test --timeout 6 --memory 512 --format json --junit` on
#      the package: exit 1, and tests/e2e/check_supervisor.py checks every
#      verdict, field and count of the JSON and the JUnit XML;
#   3. checks that the checker itself fails on a wrong verdict: it is run
#      on copies of the results with one verdict changed, and must fail;
#   4. checks that no `sleep 7919` survived (the group kill), and that the
#      native test's binary names libgreet;
#   5. human output: the memory file with --memory 0 --timeout 3 (no cap:
#      the same test is now TIMEOUT hung, so the OOM above was the cap's),
#      and the self-hosted file alone (exit 0);
#   6. supervisor self-test: test_verdicts.mojo with the test-only
#      --test-only-no-group-kill. The `sleep 7919` must now survive, and
#      mopm must notice and exit 5, so the check in 4 is shown to fail when
#      the group kill is broken.
set -u

if [ $# -ne 3 ]; then
    echo "usage: tests/e2e/test_supervisor.sh <mopm> <mojo env prefix> <work dir>" >&2
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
die() {
    echo "FAIL $*"
    exit 1
}
show() {
    sed "s/${esc}\[[0-9;]*m//g" < "$1" | grep -v "Failed to initialize Crashpad" | sed 's/^/     | /'
}
leftovers() {
    pgrep -f "sleep 7919" | tr '\n' ' '
}

case "$(uname -s)" in
    Darwin) ext=dylib ;;
    *) ext=so ;;
esac

echo "== mojo: $(MODULAR_HOME="$prefix/share/max" "$prefix/bin/mojo" --version 2>&1)"
[ -z "$(leftovers)" ] || die "a 'sleep 7919' is running before the test: $(leftovers)"

# ---------------------------------------------------------------- 1
natives=$work/natives
mkdir -p "$natives"
if [ "$ext" = dylib ]; then
    cc -dynamiclib -install_name "@rpath/libgreet.dylib" -o "$natives/libgreet.dylib" "$here/native/greet.c" || die "cc libgreet"
else
    cc -shared -fPIC -Wl,-soname,libgreet.so -o "$natives/libgreet.so" "$here/native/greet.c" || die "cc libgreet"
fi
MODULAR_HOME="$prefix/share/max" "$prefix/bin/mojo" precompile "$here/pkgs/greet" -o "$natives/greet.mojoc" ||
    die "mojo precompile greet"
mkdir -p "$prefix/lib/mojo"
cp "$natives/libgreet.$ext" "$prefix/lib/"
cp "$natives/greet.mojoc" "$prefix/lib/mojo/"
printf '{"schema": 1, "name": "greet", "version": "1.0.0", "deps": [],\n "native": [{"id": "greet", "soname": "libgreet.%s", "file": "../libgreet.%s", "needs": []}]}\n' \
    "$ext" "$ext" > "$prefix/lib/mojo/greet.mopm.json"
echo "ok   installed greet (libgreet.$ext) into the environment"

[ -d "$work/supervise" ] && die "work dir $work already holds supervise"
cp -R "$here/supervise" "$work/supervise"
cd "$work/supervise" || exit 1

# ---------------------------------------------------------------- 2
start=$(date +%s)
"$mopm" test --prefix "$prefix" --timeout 6 --memory 512 --format json --junit "$work/junit.xml" > "$work/run.json" 2> "$work/run.err"
rc=$?
echo "     mopm test took $(($(date +%s) - start)) s (builds included); stderr:"
show "$work/run.err"
if [ "$rc" -eq 1 ]; then
    pass "mopm test on the fixtures: exit 1 (tests did not pass, everything built)"
else
    flunk "mopm test on the fixtures: exit $rc, want 1; stdout:"
    show "$work/run.json"
fi
if python3 -I "$here/check_supervisor.py" "$work/run.json" "$work/junit.xml" "$work/supervise"; then
    pass "every verdict, JSON field and JUnit count is the expected one"
else
    flunk "the results differ from the expected verdicts (above); the JSON:"
    show "$work/run.json"
fi

# ---------------------------------------------------------------- 3
# mutant <label> <test name> <sed expression on that test's JSON line>
mutant() {
    sed "/\"name\": \"$2\"/$3" "$work/run.json" > "$work/mutant.json"
    if cmp -s "$work/run.json" "$work/mutant.json"; then
        flunk "checker self-test ($1): the edit changed nothing"
    elif python3 -I "$here/check_supervisor.py" "$work/mutant.json" "$work/junit.xml" "$work/supervise" > "$work/mutant.out" 2>&1; then
        flunk "checker self-test ($1): the checker accepted a wrong verdict"
    else
        pass "checker self-test ($1): rejected ($(grep -c '^FAIL' "$work/mutant.out") failed checks)"
    fi
}
mutant "a crash reported as a failure" test_segfault 's/"status": "crash"/"status": "fail"/'
mutant "a hung test reported as slow" test_hang 's/"timeout": "hung"/"timeout": "slow"/'
mutant "a slow test that passed reported as a timeout" test_slow_ok 's/"status": "pass"/"status": "timeout"/'
mutant "the wrong signal" test_abort 's/"signal_name": "SIGABRT"/"signal_name": "SIGILL"/'
mutant "an early exit reported as a pass" test_exits_early 's/"status": "fail"/"status": "pass"/'
sed 's/failures="3"/failures="2"/' "$work/junit.xml" > "$work/mutant.xml"
if python3 -I "$here/check_supervisor.py" "$work/run.json" "$work/mutant.xml" "$work/supervise" > "$work/mutant.out" 2>&1; then
    flunk "checker self-test (a wrong JUnit count): accepted"
else
    pass "checker self-test (a wrong JUnit count): rejected"
fi

# ---------------------------------------------------------------- 4
sleep 1
if [ -z "$(leftovers)" ]; then
    pass "no 'sleep 7919' left behind: the deadline kill took the hung test's whole process group"
else
    flunk "a 'sleep 7919' survived the run: $(leftovers)"
    pkill -f "sleep 7919"
fi
nbin=$(find target/mopm/bin -type f -name test_native)
if [ "$ext" = dylib ]; then
    otool -L "$nbin" | grep -q "@rpath/libgreet.dylib"
else
    readelf -d "$nbin" | grep -q "NEEDED.*\[libgreet.so\]"
fi && pass "the native test's binary ($nbin) names libgreet" || flunk "the native test's binary ($nbin) does not name libgreet"

# ---------------------------------------------------------------- 5
"$mopm" test --prefix "$prefix" --memory 0 --timeout 3 tests/test_memory.mojo > "$work/nocap.out" 2> "$work/nocap.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -q "^TIMEOUT  *tests/test_memory.mojo::test_oom ([0-9]* ms): hung at the 3 s deadline" "$work/nocap.out" &&
    grep -q "^---- tests/test_memory.mojo::test_oom: TIMEOUT" "$work/nocap.out" &&
    grep -q "^mopm test: 1 tests: 0 passed, 0 failed, 0 crashed, 1 timed out, 0 out of memory, 0 not built$" "$work/nocap.out"; then
    pass "human output: with --memory 0 the same test is TIMEOUT hung (so the OOM came from the cap)"
else
    flunk "--memory 0 --timeout 3 on test_memory.mojo (exit $rc, want 1); stdout and stderr:"
    show "$work/nocap.out"
    show "$work/nocap.err"
fi
"$mopm" test --prefix "$prefix" tests/test_self_hosted.mojo > "$work/self.out" 2> "$work/self.err"
rc=$?
if [ "$rc" -eq 0 ] && grep -q "^PASS  *tests/test_self_hosted.mojo::test_registered_pass ([0-9]* ms)$" "$work/self.out" &&
    grep -q "^mopm test: 1 tests: 1 passed, 0 failed" "$work/self.out"; then
    pass "human output: a self-hosted file that passes, exit 0"
else
    flunk "the self-hosted file alone (exit $rc, want 0); stdout and stderr:"
    show "$work/self.out"
    show "$work/self.err"
fi

# ---------------------------------------------------------------- 6
"$mopm" test --prefix "$prefix" --timeout 6 --memory 512 --test-only-no-group-kill tests/test_verdicts.mojo > "$work/nokill.out" 2> "$work/nokill.err"
rc=$?
survivors=$(leftovers)
if [ "$rc" -eq 5 ] && [ -n "$survivors" ] &&
    grep -q "^mopm test: tests/test_verdicts.mojo::test_hang: process group [0-9]* still has processes after the test ended$" "$work/nokill.err"; then
    pass "self-test: without the group kill the 'sleep 7919' survives ($survivors), and mopm reports it and exits 5"
else
    flunk "self-test with --test-only-no-group-kill (exit $rc, want 5; survivors: '$survivors'); stdout and stderr:"
    show "$work/nokill.out"
    show "$work/nokill.err"
fi
[ -n "$survivors" ] && pkill -f "sleep 7919"
if grep -q "^TIMEOUT  *tests/test_verdicts.mojo::test_hang (" "$work/nokill.out" &&
    grep -q "^CRASH  *tests/test_verdicts.mojo::test_segfault (" "$work/nokill.out"; then
    pass "self-test run: the verdicts are unchanged"
else
    flunk "self-test run: verdicts changed; stdout:"
    show "$work/nokill.out"
fi

exit "$fail"
