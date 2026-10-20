from std.testing import TestSuite, assert_equal

from mathkit import clamp


def test_clamp_low() raises:
    assert_equal(clamp(-5, 0, 10), 0)


def test_clamp_high() raises:
    assert_equal(clamp(50, 0, 10), 10)


# mopm: ignore "needs the network" #12
def test_clamp_remote() raises:
    assert_equal(clamp(1, 0, 10), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
