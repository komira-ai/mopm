from std.testing import TestSuite, assert_equal

from demo import greet


def test_greet() raises:
    assert_equal(greet("Mojo"), "Hello, Mojo!")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
