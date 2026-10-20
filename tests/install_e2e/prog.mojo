# Uses the package `greet` that `mopm sync` installed (tests/drivers/install_e2e_test.zig).
# "greet 4242" comes only from libgreet, the native library greet ships.
from greet import answer


def main():
    print("greet", answer())
