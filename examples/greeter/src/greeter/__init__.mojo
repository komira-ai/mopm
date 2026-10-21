"""greeter: greetings, as a library."""


def greet(who: String) -> String:
    """Returns a greeting for `who`."""
    return "Hello, " + who + "!"


def greet_twice(who: String) -> String:
    """Returns the greeting for `who`, twice."""
    return greet(who) + " " + greet(who)
