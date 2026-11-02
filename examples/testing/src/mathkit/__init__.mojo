def double(x: Int) -> Int:
    return x * 2


def square(x: Int) -> Int:
    return x * x


def clamp(x: Int, low: Int, high: Int) -> Int:
    if x < low:
        return low
    if x > high:
        return high
    return x
