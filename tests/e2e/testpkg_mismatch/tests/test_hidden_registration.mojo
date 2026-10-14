"""A self-hosted file whose main registers a test only when a condition
holds at run time. The scan cannot know that and lists both tests; the
binary's --skip-all lists one. mopm test --list --check must say so."""
from std.testing import TestSuite, assert_true


def test_listed() raises:
    assert_true(True)


def test_never_registered() raises:
    assert_true(True)


def main() raises:
    var suite = TestSuite()
    suite.test[test_listed]()
    if len(String("")) > 0:
        suite.test[test_never_registered]()
    suite^.run()
