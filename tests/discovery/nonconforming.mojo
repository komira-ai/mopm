async def test_async() raises:
    pass


def test_takes_argument(x: Int) raises:
    pass


def test_generic[T: AnyType]() raises:
    pass


def test_does_not_raise():
    pass


def test_typed_error() raises CustomError:
    pass


def test_returns_value() raises -> Int:
    return 1


def test_capturing() capturing raises:
    pass


# mopm: not-a-test
def test_helper(x: Int) -> Int:
    return x


def test_fine() raises:
    pass
