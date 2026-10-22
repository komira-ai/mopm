<!-- What this changes and why. -->

## If this is a dependency update (Dependabot or another bot)

A green bot-pinned dependency pull request is **not** a reviewed dependency. The pin proves the bytes match what the
registry said; it does not prove they are safe. Read the lockfile diff. The farm did not build this branch: a Dependabot
branch gets no farm login, and `pin-verify` stands in for the build only as far as the pin tables go.

## If this touches `.github/`

The bot never pins a pull request that touches `.github/`, and `pin-verify` (a required check) runs from the pull request's own
copy of its workflow, so a green check on such a pull request means nothing. A person must read the workflow change.
