from std.sys.info import CompilationTarget

def where() -> String:
    comptime if CompilationTarget.is_linux():
        return "MARK_LINUX"
    elif CompilationTarget.is_macos():
        return "MARK_MACOS"
    else:
        return "MARK_OTHER"


def arch() -> String:
    comptime if CompilationTarget.is_x86():
        return "ARCH_X86"
    elif CompilationTarget.has_neon():
        return "ARCH_ARM"
    else:
        return "ARCH_OTHER"
