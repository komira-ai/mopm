from std.testing import TestSuite, assert_true


def test_first() raises:
    assert_true(True)


def check_second() raises:
    assert_true(True)


def main() raises:
    var suite = TestSuite()
    suite.test[test_first]()
    suite.test[check_second]()
    suite^.run()
