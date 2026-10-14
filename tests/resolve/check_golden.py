#!/usr/bin/env python3
"""Checks the locks mopm's unit tests write against the lock contract.

    python -I tests/resolve/check_golden.py      (from the repository root)

Each tests/resolve/golden/*.lock is the exact output of a Zig unit test
(src/core/install_plan.zig compares the bytes). Here each one must pass
spec/lock.schema.json and the rules of spec/lock.md that the schema cannot
express (tests/contract/validate.py's lock_problems).

So that this check is shown to be able to fail, each golden is also broken in
the ways a faulty lock writer would break it, and every broken copy must be
refused. Needs the packages in tests/contract/requirements.txt.
"""

import copy
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "contract"))

from jsonschema import Draft202012Validator  # noqa: E402

import validate  # noqa: E402

failures = []


def problems(validator, doc):
    found = [e.message[:160] for e in validator.iter_errors(doc)]
    if not found:
        found = validate.lock_problems(doc)
    return found


def first(doc, pred):
    return next(p for p in doc["packages"] if pred(p))


def mutants(doc):
    """(what a faulty writer does, the broken lock)."""
    out = []

    def mutant(what, change):
        d = copy.deepcopy(doc)
        change(d)
        out.append((what, d))

    mutant("writes packages out of order", lambda d: d["packages"].reverse())
    mutant("writes an entry twice", lambda d: d["packages"].append(copy.deepcopy(d["packages"][0])))
    mutant("drops a sha256", lambda d: d["packages"][0].pop("sha256"))
    mutant("writes a sha256 in upper case", lambda d: d["packages"][0].update(sha256=d["packages"][0]["sha256"].upper()))
    mutant("builds the url from the wrong version",
           lambda d: d["packages"][0].update(url=d["packages"][0]["url"].replace(d["packages"][0]["version"], "9.9.9")))
    mutant("pins a build for another mojo", lambda d: d["packages"][0].update(mojo="9.9.9"))
    mutant("names a dependency it did not lock",
           lambda d: first(d, lambda p: p.get("deps")).update(deps=["not_locked"]))
    mutant("writes a channel the project does not list", lambda d: d.update(channels=["https://conda.example/"]))
    mutant("writes lock_version 2", lambda d: d.update(lock_version=2))
    return out


def main():
    schema = validate.load_json(validate.SPEC / "lock.schema.json")
    validator = Draft202012Validator(schema)
    goldens = sorted((ROOT / "tests" / "resolve" / "golden").glob("*.lock"))
    if not goldens:
        failures.append("no golden locks under tests/resolve/golden")
    for path in goldens:
        rel = path.relative_to(ROOT)
        doc = validate.load_json(path)
        for p in problems(validator, doc):
            failures.append("%s: %s" % (rel, p))
        print("ok   %s passes the schema and the lock rules" % rel)
        for what, broken in mutants(doc):
            if problems(validator, broken):
                print("ok   %s refused when the writer %s" % (rel, what))
            else:
                failures.append("%s: a writer that %s would pass this check" % (rel, what))
    for f in failures:
        print("FAIL " + f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
