from probe_neutral import Point, add


def main():
    var p = Point(2, 3)
    print("probe ok", add(p.x, p.y), p.sum())
