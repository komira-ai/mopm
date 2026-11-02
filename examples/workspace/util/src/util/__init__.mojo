def clamp(x: Int, low: Int, high: Int) -> Int:
    """`x`, held between `low` and `high`."""
    if x < low:
        return low
    if x > high:
        return high
    return x
