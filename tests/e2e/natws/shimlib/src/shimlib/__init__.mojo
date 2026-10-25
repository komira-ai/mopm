from std.ffi import external_call


def shim_answer() -> Int:
    return Int(external_call["shim_answer", Int32]())
