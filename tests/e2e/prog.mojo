from greet import answer
from inner import base
from outer import chain


def main():
    print("greet", answer())
    print("base", base())
    print("chain", chain())
