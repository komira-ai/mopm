from std.ffi import external_call


def chain() -> Int:
    return Int(external_call["outer_chain", Int32]())
