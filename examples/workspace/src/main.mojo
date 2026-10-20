from core import total
from util import clamp


def main():
    print(clamp(total(40, 5), 0, 42))
