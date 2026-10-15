"""Fixtures of the supervisor end-to-end test (tests/e2e/test_supervisor.sh),
run with `mopm test --timeout 6`. The script asserts each test's exact
verdict; the comment above each test names it. Tests run in source order, so
test_after_crashes runs after two crashes.
"""
from std.ffi import external_call
from std.testing import assert_equal
from std.time import perf_counter_ns


def spin_for(seconds: Int):
    """Burn one CPU for `seconds` of wall time."""
    var start = Int(perf_counter_ns())
    var n = 0
    while Int(perf_counter_ns()) - start < seconds * 1_000_000_000:
        n += 1


# PASS
def test_pass() raises:
    assert_equal(2 + 2, 4)


# FAIL: an assertion
def test_assert_fails() raises:
    assert_equal(2 + 2, 5, "planted assertion")


# FAIL: an error raised by the test
def test_raises() raises:
    raise Error("planted raise")


# CRASH, SIGABRT: libc abort()
def test_abort() raises:
    external_call["abort", NoneType]()
    raise Error("abort() returned")


# CRASH, SIGSEGV: a read through a null pointer, inside libc
def test_segfault() raises:
    _ = external_call["strlen", Int](Int(0))
    raise Error("strlen(NULL) returned")


# PASS: runs after the two crashes, so a crash did not lose it
def test_after_crashes() raises:
    assert_equal(3 * 3, 9)


# TIMEOUT, hung: sleeps; and leaves a process behind in its process group
# (`sleep 7919`, started with fork and execlp: the build farm has no /bin/sh
# for system()), which the deadline kill of the group must take too
def test_hang() raises:
    var prog = String("sleep")
    var arg = String("7919")
    var pid = external_call["fork", Int32]()
    if pid == 0:
        _ = external_call["execlp", Int32](
            prog.as_c_string_slice().unsafe_ptr(),
            prog.as_c_string_slice().unsafe_ptr(),
            arg.as_c_string_slice().unsafe_ptr(),
            Int(0),
        )
        external_call["_exit", NoneType](Int32(127))
    _ = external_call["sleep", UInt32](UInt32(300))
    raise Error("woke up")


# PASS: computes for 4 s, past half of the 6 s deadline, and ends in time
def test_slow_ok() raises:
    spin_for(4)
    assert_equal(1, 1)


# TIMEOUT, slow: still computing at the deadline
def test_spin_forever() raises:
    spin_for(3600)


# FAIL: exit status 0, but the process ended before the test finished
def test_exits_early() raises:
    external_call["_exit", NoneType](Int32(0))
