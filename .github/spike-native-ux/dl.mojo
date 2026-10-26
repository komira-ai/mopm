from std.ffi import OwnedDLHandle
from std.sys import argv


def main() raises:
    var name = String(argv()[1])
    var lib = OwnedDLHandle(name)
    print(name, "LZ4_versionNumber =", lib.call["LZ4_versionNumber", Int32]())
