from std.testing import assert_equal

from mathkit import double


def test_double_two() raises:
    assert_equal(double(2), 4)


def test_double_zero() raises:
    assert_equal(double(0), 0)
