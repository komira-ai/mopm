struct Point(Copyable, Movable):
    var x: Int
    var y: Int

    def __init__(out self, x: Int, y: Int):
        self.x = x
        self.y = y

    def sum(self) -> Int:
        return self.x + self.y


def add(a: Int, b: Int) -> Int:
    return a + b
