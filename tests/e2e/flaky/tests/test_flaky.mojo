"""Fixtures of the retry end-to-end test (tests/drivers/test_flaky_test.zig).

Each test counts its own attempts in a state file under the working
directory (mopm test runs tests in the directory it was started in, here a
fresh copy of this package): `attempt` appends one byte to
target/flaky-state/<test> and returns how many attempts there have been,
this one included. So in a fresh copy every verdict below is fixed: the
same binary, run with the same argv, fails on its first attempt(s) and
passes after, which is exactly what FLAKY means. The comment above each
test names its verdict under `mopm test --retries 2`.
"""
from std.ffi import external_call
from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path
from std.testing import assert_equal


def attempt(name: String) raises -> Int:
    """Record one more attempt of test `name`; the attempt number, from 1."""
    var dir = String("target/flaky-state")
    makedirs(dir, exist_ok=True)
    var path = dir + String("/") + name
    var seen = String("")
    if exists(path):
        seen = Path(path).read_text()
    var count = seen + String("x")
    var f = open(path, "w")
    f.write_bytes(count.as_bytes())
    f.close()
    return count.byte_length()


# PASS, one attempt
def test_steady() raises:
    assert_equal(attempt(String("test_steady")), 1)


# FLAKY: attempt 1 FAIL, attempt 2 PASS
def test_fails_once() raises:
    if attempt(String("test_fails_once")) == 1:
        raise Error("faulty failure on the first attempt")


# FLAKY: attempt 1 CRASH (SIGABRT), attempt 2 PASS
def test_crashes_once() raises:
    if attempt(String("test_crashes_once")) == 1:
        external_call["abort", NoneType]()


# FLAKY: attempts 1 and 2 FAIL, attempt 3 PASS (FAIL under --retries 1)
def test_fails_twice() raises:
    if attempt(String("test_fails_twice")) <= 2:
        raise Error("faulty failure on the first two attempts")


# FAIL: every attempt fails
def test_always_fails() raises:
    _ = attempt(String("test_always_fails"))
    raise Error("faulty failure on every attempt")


# SKIP; with --ignored or --include-ignored, FAIL
# mopm: ignore "faulty: fails when run" https://github.com/komira-ai/mopm/blob/main/docs/mopm-test.md
def test_ignored_fails() raises:
    raise Error("faulty failure of an ignored test")
