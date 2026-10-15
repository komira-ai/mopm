# Syntax of Mojo 1.1 only: a leading-dot member reference, resolved against
# the expected type (1.0 has no such form).
struct Color(Copyable, Movable):
    var v: Int

    def __init__(out self, v: Int):
        self.v = v

    @staticmethod
    def make(v: Int) -> Self:
        return Self(v)


def pick() -> Int:
    var c: Color = .make(3)
    return c.v
