"""A self-hosted file using the stdlib's reflection-based discovery."""
from std.testing import TestSuite, assert_equal


def test_alpha() raises:
    assert_equal(1, 1)


def test_beta() raises:
    assert_equal(2, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
