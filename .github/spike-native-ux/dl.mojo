from sys.ffi import OwnedDLHandle
from sys import CompilationTarget


def main() raises:
    comptime name = "liblz4.dylib" if CompilationTarget.is_macos() else "liblz4.so.1"
    var lib = OwnedDLHandle(name)
    print(name, "LZ4_versionNumber =", lib.call["LZ4_versionNumber", Int32]())
