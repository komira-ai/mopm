"""Fixture of the supervisor end-to-end test: a self-hosted file (its own
main registers its tests), run through mopm test like a bare one."""
from std.testing import TestSuite, assert_true


# PASS
def test_registered_pass() raises:
    assert_true(1 < 2)


def main() raises:
    var suite = TestSuite()
    suite.test[test_registered_pass]()
    suite^.run()
