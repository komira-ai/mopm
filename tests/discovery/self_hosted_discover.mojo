from std.testing import TestSuite, assert_true


def test_alpha() raises:
    assert_true(True)


def test_beta() raises:
    assert_true(True)


def test_with_argument(x: Int) raises:
    pass


# mopm: not-a-test
def test_helper() raises:
    pass


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
