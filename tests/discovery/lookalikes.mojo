"""Text that looks like a test but is not one.

def test_in_module_docstring() raises:
    pass
"""
from std.testing import assert_true

# def test_in_comment() raises:
#def test_in_comment_no_space() raises:
comptime IN_STRING = "def test_in_string() raises:"
comptime IN_SINGLE = 'def test_in_single() raises:'
comptime IN_RAW = r"\" def test_in_raw() raises:"
comptime IN_ESCAPED = "quote \" def test_after_escape() raises:"
comptime IN_TRIPLE = '''
def test_in_triple() raises:
    pass
'''
comptime IN_F = f"{1} def test_in_fstring() raises:"
comptime IN_T = t"def test_in_tstring() raises:"
comptime test_alias = 3


def outer() raises:
    def test_nested() raises:
        pass

    test_nested()


struct Holder:
    def test_method(self) raises:
        pass

    @staticmethod
    def test_static() raises:
        pass


comptime if True:
    def test_under_comptime_if() raises:
        pass


def test_real() raises:
    assert_true("""
def test_inside_a_call() raises:
""" != "")


def test() raises:
    pass


def Test_capital() raises:
    pass


def xtest_prefixed() raises:
    pass


def test_after_everything() raises:
    pass
