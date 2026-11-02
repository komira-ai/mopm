from util import clamp


def total(a: Int, b: Int) -> Int:
    """The sum of `a` and `b`, held between 0 and a million."""
    return clamp(a + b, 0, 1000000)
