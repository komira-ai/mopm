from std.testing import TestSuite, assert_equal

from calc import double


def test_double() raises:
    assert_equal(double(2), 4)


def test_double_negative() raises:
    assert_equal(double(-3), -6)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
