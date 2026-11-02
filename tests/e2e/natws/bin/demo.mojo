from nativeapp import plus_one
from shimlib import shim_answer


def main():
    print("shim", shim_answer())
    print("app", plus_one())
