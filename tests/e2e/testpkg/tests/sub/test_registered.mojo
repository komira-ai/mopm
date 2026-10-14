"""A self-hosted file: its own main registers its tests explicitly."""
from std.testing import TestSuite, assert_true


def test_first() raises:
    assert_true(True)


def check_second() raises:
    assert_true(1 < 2)


def test_takes_argument(x: Int) raises:
    assert_true(x > 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_first]()
    suite.test[check_second]()
    suite^.run()
