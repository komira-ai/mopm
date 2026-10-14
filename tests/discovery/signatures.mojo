from std.testing import assert_true


@no_inline
def test_decorated() raises:
    assert_true(True)


@always_inline
@no_inline
def test_two_decorators() raises:
    assert_true(True)


@some_decorator(
    "with arguments over",
    "several lines",
)
# a comment between the decorator and the def
def test_decorator_with_arguments() raises:
    pass


def test_multi_line_signature(
) raises:
    pass


def test_returns_none(
    # nothing here
) raises -> None:
    pass


def test_continued() \
    raises:
    pass


def test_one_line() raises: pass


def test_dict_in_body() raises:
    var d = {"a": 1}
