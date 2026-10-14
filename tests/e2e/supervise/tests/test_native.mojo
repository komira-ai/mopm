"""Fixture of the supervisor end-to-end test: a test of code that calls a
native library (libgreet, installed with the package greet). mopm test must
build it with the link arguments of `mopm build`, or it does not link."""
from greet import answer
from std.testing import assert_equal


# PASS
def test_native() raises:
    assert_equal(answer(), 4242)
