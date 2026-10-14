from std.ffi import external_call


def answer() -> Int:
    return Int(external_call["greet_answer", Int32]())
