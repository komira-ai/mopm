# Uses the package `greet` that `mopm sync` installed (tests/install_e2e/run.py).
# "greet 4242" comes only from libgreet, the native library greet ships.
from greet import answer


def main():
    print("greet", answer())
