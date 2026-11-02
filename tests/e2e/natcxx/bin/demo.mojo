from cxxapp import plus_one
from cxxlib import cxx_answer


def main():
    print("cxx", cxx_answer())
    print("app", plus_one())
