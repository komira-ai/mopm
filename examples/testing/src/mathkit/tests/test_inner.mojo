from std.testing import assert_equal

from mathkit import square


def test_inner_square() raises:
    assert_equal(square(7), 49)
