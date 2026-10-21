"""slug: turn a title into a URL slug."""

from text_tools import lower_ascii


def slugify(title: String) -> String:
    return lower_ascii(title).replace(" ", "-")
