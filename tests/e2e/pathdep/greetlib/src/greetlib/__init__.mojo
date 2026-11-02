"""greetlib: a path dependency of app that itself has a path dependency."""

from basepkg import prefix


def greeting(who: String) -> String:
    return prefix() + who
