from std.ffi import external_call


def base() -> Int:
    return Int(external_call["inner_base", Int32]())
