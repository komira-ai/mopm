"""Fixture of the supervisor end-to-end test: run with `--memory 512`."""
from std.ffi import external_call


# OOM: touches 1 GiB, then waits; the 512 MiB cap must stop it long before
# the deadline
def test_oom() raises:
    var n = 1 << 30
    var p = external_call["malloc", Int](n)
    if p == 0:
        raise Error("malloc failed")
    _ = external_call["memset", Int](p, Int32(1), n)
    _ = external_call["sleep", UInt32](UInt32(300))
    external_call["free", NoneType](p)
