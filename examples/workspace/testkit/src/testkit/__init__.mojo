def approx(a: Int, b: Int, within: Int) -> Bool:
    """Whether `a` and `b` differ by at most `within`."""
    return a - b <= within and b - a <= within
