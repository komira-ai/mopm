@fieldwise_init
struct Point(Writable):
    var x: Int
    var y: Int

    def move_by(mut self, dx: Int, dy: Int):
        self.x += dx
        self.y += dy

    def write_to[W: Writer](self, mut writer: W):
        writer.write("(", self.x, ", ", self.y, ")")


def main():
    var p = Point(1, 2)
    print(p)
    p.move_by(3, 4)
    print(p)
    print(p.x + p.y)
