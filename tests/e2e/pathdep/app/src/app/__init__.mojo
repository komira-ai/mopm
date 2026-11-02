"""app: a library that imports a path dependency."""

from greetlib import greeting


def shout(who: String) -> String:
    return greeting(who) + "!"
