from std.sys.info import os_is_linux, os_is_macos, is_x86, has_neon

def where() -> String:
    @parameter
    if os_is_linux():
        return "MARK_LINUX"
    elif os_is_macos():
        return "MARK_MACOS"
    else:
        return "MARK_OTHER"


def arch() -> String:
    @parameter
    if is_x86():
        return "ARCH_X86"
    elif has_neon():
        return "ARCH_ARM"
    else:
        return "ARCH_OTHER"
