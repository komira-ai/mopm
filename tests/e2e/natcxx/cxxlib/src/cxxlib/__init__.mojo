from std.ffi import external_call


def cxx_answer() -> Int:
    return Int(external_call["cxx_answer", Int32]())
