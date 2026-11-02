"""A bare test file: no main of its own; mopm test appends one.

def test_in_docstring() raises:
"""
from std.testing import assert_equal

# def test_in_comment() raises:
comptime IN_STRING = "def test_in_string() raises:"


def double(x: Int) -> Int:
    return 2 * x


def test_one() raises:
    assert_equal(double(2), 4)


@no_inline
def test_two_decorated() raises -> None:
    assert_equal(double(3), 6)


def test_multi_line(
) raises:
    assert_equal(double(0), 0)


def test_raises() raises:
    raise Error("faulty: this test always fails")


# mopm: not-a-test
def test_helper(x: Int) -> Int:
    return x + 1


def outer() raises:
    def test_nested() raises:
        pass

    test_nested()


struct Holder:
    def test_method(self) raises:
        pass
