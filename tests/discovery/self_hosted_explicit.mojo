from std.testing import TestSuite, assert_true


def test_first() raises:
    assert_true(True)


def check_second() raises:
    assert_true(True)


def test_parameterised(src: String) raises:
    assert_true(len(src) > 0)


def test_with_source() raises:
    test_parameterised("x")


# mopm: not-a-test
def test_helper() raises:
    pass


def main() raises:
    var suite = TestSuite()
    suite.test[test_with_source]()
    suite.test[test_first]()
    # suite.test[test_in_comment]()
    suite.test[check_second]()
    if False:
        suite.test[test_never_runs]()
    suite.test[mod.qualified_name]()
    suite.test[make[Int]]()
    suite^.run()
