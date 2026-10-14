#!/bin/sh
# End-to-end test of `mopm test --retries`, `--deny-flaky` and the name
# filters, against the real Mojo toolchain. Run from the repository root:
#
#   tests/e2e/test_flaky.sh <mopm binary> <Mojo environment prefix> <work dir>
#
# tests/e2e/flaky is a package. Its tests/test_flaky.mojo tests count their
# own attempts in target/flaky-state/ under the directory mopm test runs in
# (see the file), so each fails on its first attempt(s) and passes after:
# deterministic in a fresh state directory, which `fresh` below makes
# before every run. tests/test_names.mojo and tests/sub/test_more.mojo hold
# passing tests with names the filters select (test_alpha_one is in both).
#
#   1. --retries 2 on test_flaky.mojo, JSON and JUnit: exit 1 (one test
#      fails every attempt); check_flaky.py checks every verdict, every
#      attempt and the JUnit flaky/rerun elements. Then the checker itself
#      must reject copies of the results with one verdict or attempt
#      changed.
#   2. The same two flaky tests (`-- once`) with no --retries: FAIL and
#      CRASH, exit 1. So the fixtures do fail first, and with --retries 0
#      (the default) nothing is retried.
#   3. --retries 2 -- once: both FLAKY, exit 0 and a warning on stderr.
#   4. The same plus --deny-flaky: exit 1. Same inputs as 3; only the flag
#      differs, so the flag is what fails the run.
#   5. --retries 1 -- test_fails_twice: FAIL after two attempts.
#   6. --ignored on the package: only the ignored test runs (and fails).
#   7. --exact with two ids, in a fresh copy: exactly those two tests run,
#      and only their two files are built.
set -u

if [ $# -ne 3 ]; then
    echo "usage: tests/e2e/test_flaky.sh <mopm> <mojo env prefix> <work dir>" >&2
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
# A fresh state directory: every fixture test starts again at attempt 1.
fresh() {
    rm -r target/flaky-state 2> /dev/null
    [ ! -e target/flaky-state ] || die "cannot remove target/flaky-state"
}
# expect <label> <want exit> <got exit> <out> <err> <grep pattern on out>...
expect() {
    label=$1
    want=$2
    got=$3
    out=$4
    err=$5
    shift 5
    ok=1
    [ "$got" -eq "$want" ] || ok=0
    for pat in "$@"; do
        grep -q "$pat" "$out" || {
            ok=0
            echo "     missing: $pat"
        }
    done
    if [ "$ok" -eq 1 ]; then
        pass "$label"
    else
        flunk "$label (exit $got, want $want); stdout and stderr:"
        show "$out"
        show "$err"
    fi
}

echo "== mojo: $(MODULAR_HOME="$prefix/share/max" "$prefix/bin/mojo" --version 2>&1)"
[ -d "$work/flaky" ] && die "work dir $work already holds flaky"
cp -R "$here/flaky" "$work/flaky"
cd "$work/flaky" || exit 1
F=tests/test_flaky.mojo

# ---------------------------------------------------------------- 1
fresh
"$mopm" test --prefix "$prefix" --retries 2 --format json --junit "$work/r1.xml" "$F" > "$work/r1.json" 2> "$work/r1.err"
rc=$?
echo "     stderr:"
show "$work/r1.err"
[ "$rc" -eq 1 ] && pass "--retries 2: exit 1 (test_always_fails)" || flunk "--retries 2: exit $rc, want 1"
if python3 -I "$here/check_flaky.py" retries "$work/r1.json" "$work/r1.xml" "$work/flaky"; then
    pass "--retries 2: every verdict, attempt and JUnit element is the expected one"
else
    flunk "--retries 2: the results differ (above); the JSON:"
    show "$work/r1.json"
fi
grep -q "^mopm test: warning: 3 FLAKY test(s)" "$work/r1.err" &&
    pass "--retries 2: the FLAKY warning on stderr" || flunk "--retries 2: no FLAKY warning on stderr"

# mutant <label> <test name> <sed expression on that test's JSON line>
mutant() {
    sed "/\"name\": \"$2\"/$3" "$work/r1.json" > "$work/mutant.json"
    if cmp -s "$work/r1.json" "$work/mutant.json"; then
        flunk "checker self-test ($1): the edit changed nothing"
    elif python3 -I "$here/check_flaky.py" retries "$work/mutant.json" "$work/r1.xml" "$work/flaky" > "$work/mutant.out" 2>&1; then
        flunk "checker self-test ($1): the checker accepted it"
    else
        pass "checker self-test ($1): rejected ($(grep -c '^FAIL' "$work/mutant.out") failed checks)"
    fi
}
mutant "a flaky test reported as PASS" test_fails_once 's/"status": "flaky"/"status": "pass"/'
mutant "a test failing every attempt reported as FLAKY" test_always_fails 's/"status": "fail"/"status": "flaky"/'
mutant "a failed attempt recorded as passed" test_fails_twice 's/"attempt": 2, "status": "fail"/"attempt": 2, "status": "pass"/'
mutant "the first attempt's crash recorded as a failure" test_crashes_once 's/"attempt": 1, "status": "crash"/"attempt": 1, "status": "fail"/'
mutant "the ignored test reported as run" test_ignored_fails 's/"status": "skip"/"status": "pass"/'
mutant "a retry dropped from the attempts" test_always_fails 's/, {"attempt": 3, [^}]*}\]/]/'
xmutant() {
    sed "$2" "$work/r1.xml" > "$work/mutant.xml"
    if cmp -s "$work/r1.xml" "$work/mutant.xml"; then
        flunk "checker self-test ($1): the edit changed nothing"
    elif python3 -I "$here/check_flaky.py" retries "$work/r1.json" "$work/mutant.xml" "$work/flaky" > "$work/mutant.out" 2>&1; then
        flunk "checker self-test ($1): the checker accepted it"
    else
        pass "checker self-test ($1): rejected"
    fi
}
xmutant "JUnit: a flaky crash recorded as a flaky failure" 's/<flakyError type="CRASH"/<flakyFailure type="CRASH"/; s/<\/flakyError>/<\/flakyFailure>/'
xmutant "JUnit: the skipped count" 's/skipped="1"/skipped="0"/'

# ---------------------------------------------------------------- 2
fresh
"$mopm" test --prefix "$prefix" "$F" -- once > "$work/r2.out" 2> "$work/r2.err"
expect "no --retries: the same two tests are FAIL and CRASH, never retried" 1 $? "$work/r2.out" "$work/r2.err" \
    "^FAIL  *$F::test_fails_once ([0-9]* ms): exit status [0-9]*$" \
    "^CRASH  *$F::test_crashes_once ([0-9]* ms): killed by SIGABRT" \
    "^mopm test: 2 tests: 0 passed, 1 failed, 1 crashed, 0 timed out, 0 out of memory, 0 not built, 0 flaky, 0 ignored; 4 filtered out$"
[ "$(cat target/flaky-state/test_fails_once target/flaky-state/test_crashes_once)" = "xx" ] &&
    pass "no --retries: each test ran exactly once" || flunk "no --retries: attempts recorded: $(cat target/flaky-state/* | tr '\n' ' ')"

# ---------------------------------------------------------------- 3
fresh
"$mopm" test --prefix "$prefix" --retries 2 "$F" -- once > "$work/r3.out" 2> "$work/r3.err"
expect "--retries 2 -- once: both FLAKY, exit 0" 0 $? "$work/r3.out" "$work/r3.err" \
    "^FLAKY  *$F::test_fails_once ([0-9]* ms): attempt 1 FAIL (exit status [0-9]*), attempt 2 PASS$" \
    "^FLAKY  *$F::test_crashes_once ([0-9]* ms): attempt 1 CRASH (killed by SIGABRT (signal 6)), attempt 2 PASS$" \
    "^---- $F::test_fails_once: FLAKY: " \
    "^  attempt 1: FAIL: exit status [0-9]*$" \
    "^mopm test: 2 tests: 0 passed, 0 failed, 0 crashed, 0 timed out, 0 out of memory, 0 not built, 2 flaky, 0 ignored; 4 filtered out$"
grep -q "^mopm test: warning: 2 FLAKY test(s): each failed and then passed, same binary and argv; the run still passes (--deny-flaky fails it)$" "$work/r3.err" &&
    pass "--retries 2 -- once: the FLAKY warning" || flunk "--retries 2 -- once: no FLAKY warning"

# ---------------------------------------------------------------- 4
fresh
"$mopm" test --prefix "$prefix" --retries 2 --deny-flaky "$F" -- once > "$work/r4.out" 2> "$work/r4.err"
expect "--deny-flaky: the same run is red, exit 1" 1 $? "$work/r4.out" "$work/r4.err" \
    "^FLAKY  *$F::test_fails_once (" \
    "^FLAKY  *$F::test_crashes_once ("
grep -q "^mopm test: 2 FLAKY test(s): each failed and then passed, same binary and argv; --deny-flaky fails the run$" "$work/r4.err" &&
    pass "--deny-flaky: says why the run failed" || flunk "--deny-flaky: no FLAKY line on stderr"

# ---------------------------------------------------------------- 5
fresh
"$mopm" test --prefix "$prefix" --retries 1 "$F" -- test_fails_twice > "$work/r5.out" 2> "$work/r5.err"
expect "--retries 1: two attempts, both FAIL" 1 $? "$work/r5.out" "$work/r5.err" \
    "^FAIL  *$F::test_fails_twice ([0-9]* ms): attempt 1 FAIL (exit status [0-9]*), attempt 2 FAIL (exit status [0-9]*)$"

# ---------------------------------------------------------------- 6
fresh
"$mopm" test --prefix "$prefix" --ignored --format json > "$work/r6.json" 2> "$work/r6.err"
rc=$?
if [ "$rc" -eq 1 ] && python3 -I "$here/check_flaky.py" ignored "$work/r6.json"; then
    pass "--ignored: only the ignored test ran"
else
    flunk "--ignored (exit $rc, want 1); stdout and stderr:"
    show "$work/r6.json"
    show "$work/r6.err"
fi

# ---------------------------------------------------------------- 7
cd "$work" || exit 1
cp -R "$here/flaky" "$work/exact"
cd "$work/exact" || exit 1
"$mopm" test --prefix "$prefix" --format json --exact -- tests/test_names.mojo::test_alpha_one tests/sub/test_more.mojo::test_gamma > "$work/r7.json" 2> "$work/r7.err"
rc=$?
if [ "$rc" -eq 0 ] && python3 -I "$here/check_flaky.py" exact "$work/r7.json"; then
    pass "--exact: exactly the two named tests ran"
else
    flunk "--exact (exit $rc, want 0); stdout and stderr:"
    show "$work/r7.json"
    show "$work/r7.err"
fi
built=$(find target/mopm/bin -type f | sed 's|.*/||' | sort | tr '\n' ' ')
[ "$built" = "test_more test_names " ] &&
    pass "--exact: only the two files with a selected test were built" || flunk "--exact: built '$built', want 'test_more test_names '"

exit "$fail"
