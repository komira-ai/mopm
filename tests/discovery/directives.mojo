# mopm: not-a-test
def not_a_test_name() raises:
    pass


# mopm: not-a-test

def test_after_blank_line() raises:
    pass


# mopm: ignore "needs network" #123
def test_ignored() raises:
    pass


# mopm: frobnicate
def test_unknown_directive() raises:
    pass


# mopm: not-a-test
comptime X = 1


    # mopm: not-a-test
def test_indented_comment_is_not_a_directive() raises:
    pass


# mopm: not-a-test
@no_inline
def test_marked_helper(n: Int) -> Int:
    return n
