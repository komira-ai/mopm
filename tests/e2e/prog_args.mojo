# Prints the arguments the program was started with (not the program itself), one per line, so a test can see what
# `mopm run <file> -- <args>` hands over.
from std.sys import argv


def main():
    var args = argv()
    print("count", len(args) - 1)
    for i in range(1, len(args)):
        print("arg[" + String(i - 1) + "]=<" + String(args[i]) + ">")
