# The `# mopm: ignore` directive: accepted forms, then each refusal.


# mopm: ignore "needs network" #12
def test_issue_number() raises:
    pass


# mopm: ignore "flaky on macOS" komira-ai/mopm#7
@no_inline
def test_owner_repo_issue() raises:
    pass


# mopm: ignore   "  spaces around are trimmed  "   https://example.com/issues/3
def test_url() raises:
    pass


def test_not_ignored() raises:
    pass


# mopm: ignore "no issue reference"
def test_no_issue() raises:
    pass


# mopm: ignore #13
def test_no_reason() raises:
    pass


# mopm: ignore "" #14
def test_empty_reason() raises:
    pass


# mopm: ignore "not a reference" issue-15
def test_bad_reference() raises:
    pass


# mopm: ignore "a helper" #16
def helper() raises:
    pass


# mopm: ignore "twice" #17
# mopm: ignore "twice" #18
def test_twice() raises:
    pass


# mopm: ignore "and not-a-test" #19
# mopm: not-a-test
def test_marked_both(n: Int) -> Int:
    return n


# mopm: ignore "nothing below" #20

def test_after_blank_line() raises:
    pass
