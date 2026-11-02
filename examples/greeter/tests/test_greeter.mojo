from std.testing import TestSuite, assert_equal

from greeter import greet, greet_twice


def test_greet() raises:
    assert_equal(greet("Mojo"), "Hello, Mojo!")


def test_greet_twice() raises:
    assert_equal(greet_twice("Mojo"), "Hello, Mojo! Hello, Mojo!")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
