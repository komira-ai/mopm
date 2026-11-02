def repeat_text(s: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += s
    return out
