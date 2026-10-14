"""A bare test file: no main, so mopm appends one."""
from std.testing import assert_equal


def double(x: Int) -> Int:
    return 2 * x


def test_double() raises:
    assert_equal(double(2), 4)


def test_double_zero() raises:
    assert_equal(double(0), 0)


def testing_is_not_a_test() raises:
    pass


def test_last() raises -> None:
    assert_equal(double(-1), -2)
