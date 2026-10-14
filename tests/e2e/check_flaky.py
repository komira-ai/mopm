"""Check the results of `mopm test` on tests/e2e/flaky against the exact
verdicts and attempts each fixture test must get (tests/e2e/test_flaky.sh
runs it).

    python3 -I tests/e2e/check_flaky.py retries <run.json> <junit.xml> <package dir>
    python3 -I tests/e2e/check_flaky.py ignored <run.json>
    python3 -I tests/e2e/check_flaky.py exact <run.json>

`retries`: `mopm test --retries 2 tests/test_flaky.mojo`, JSON and JUnit.
`ignored`: `mopm test --ignored`. `exact`: the two tests selected with
--exact. Prints one line per check; exits 1 if any check fails.
"""
import json
import os
import sys
import xml.etree.ElementTree as ET

F = "tests/test_flaky.mojo"
N = "tests/test_names.mojo"
M = "tests/sub/test_more.mojo"
ISSUE = "https://github.com/komira-ai/mopm/blob/main/docs/mopm-test.md"

# --retries 2: id -> (verdict, the verdict of each attempt, in order).
RETRIES = [
    (F + "::test_steady", "pass", ["pass"]),
    (F + "::test_fails_once", "flaky", ["fail", "pass"]),
    (F + "::test_crashes_once", "flaky", ["crash", "pass"]),
    (F + "::test_fails_twice", "flaky", ["fail", "fail", "pass"]),
    (F + "::test_always_fails", "fail", ["fail", "fail", "fail"]),
    (F + "::test_ignored_fails", "skip", []),
]
RETRIES_SUMMARY = {"tests": 6, "pass": 1, "fail": 1, "crash": 0, "timeout": 0, "oom": 0, "compile_error": 0,
                   "flaky": 3, "skip": 1, "filtered_out": 0}
# JUnit: id -> the child elements of its <testcase>, as (tag, type).
JUNIT = {
    F + "::test_steady": [],
    F + "::test_fails_once": [("flakyFailure", "FAIL")],
    F + "::test_crashes_once": [("flakyError", "CRASH")],
    F + "::test_fails_twice": [("flakyFailure", "FAIL"), ("flakyFailure", "FAIL")],
    F + "::test_always_fails": [("failure", "FAIL"), ("rerunFailure", "FAIL"), ("rerunFailure", "FAIL")],
    F + "::test_ignored_fails": [("skipped", None)],
}
TEST_KEYS = {"id", "file", "name", "status", "ms", "cpu_ms", "peak_rss_bytes", "exit_code", "signal",
             "signal_name", "timeout", "leftover_processes", "message", "stdout", "stderr",
             "ignore", "binary_sha256", "attempts"}
ATTEMPT_KEYS = TEST_KEYS - {"id", "file", "name", "ignore", "binary_sha256", "attempts"} | {"attempt"}

failures = 0


def check(ok, what):
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures += 1


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def output_of(pkg, a):
    text = ""
    for p in (a.get("stdout"), a.get("stderr")):
        if p:
            with open(os.path.join(pkg, p), encoding="utf-8", errors="replace") as f:
                text += f.read()
    return text


def check_retries(run_json, junit_xml, pkg):
    doc = load(run_json)
    check(doc.get("exit_code") == 1, "json: exit_code 1 (test_always_fails; FLAKY alone does not fail without --deny-flaky)")
    st = doc.get("settings", {})
    check(st.get("retries") == 2 and st.get("deny_flaky") is False, "json: settings retries 2, deny_flaky false (got %r)" % st)
    check(doc.get("summary") == RETRIES_SUMMARY, "json: summary %r" % doc.get("summary"))
    tests = doc.get("tests", [])
    check([t.get("id") for t in tests] == [e[0] for e in RETRIES],
          "json: exactly the tests of test_flaky.mojo, in order (got %r)" % [t.get("id") for t in tests])
    by_id = {t.get("id"): t for t in tests}
    shas = set()
    for tid, status, want in RETRIES:
        t = by_id.get(tid)
        if t is None:
            check(False, "%s: missing" % tid)
            continue
        check(set(t) == TEST_KEYS, "%s: the documented fields (got %r)" % (tid, sorted(t)))
        check(t.get("status") == status, "%s: status %s (got %s: %s)" % (tid, status, t.get("status"), t.get("message")))
        att = t.get("attempts")
        got = [a.get("status") for a in att or []]
        check(got == want, "%s: attempts %r (got %r)" % (tid, want, got))
        check([a.get("attempt") for a in att or []] == list(range(1, len(want) + 1)), "%s: attempts numbered from 1" % tid)
        if status == "skip":
            check(t.get("ignore") == {"reason": "planted: fails when run", "issue": ISSUE},
                  "%s: ignore reason and issue (got %r)" % (tid, t.get("ignore")))
            check(t.get("stdout") is None and t.get("binary_sha256") is None, "%s: never ran" % tid)
            check("ignored: planted: fails when run" in t.get("message", ""), "%s: message says ignored and why" % tid)
            continue
        check(t.get("ignore") is None, "%s: not ignored" % tid)
        shas.add(t.get("binary_sha256"))
        paths = set()
        for k, a in enumerate(att or [], 1):
            check(set(a) == ATTEMPT_KEYS, "%s attempt %d: the documented fields (got %r)" % (tid, k, sorted(a)))
            for p in (a.get("stdout"), a.get("stderr")):
                check(p is not None and os.path.isfile(os.path.join(pkg, p)), "%s attempt %d: output file %r exists" % (tid, k, p))
                paths.add(p)
            if k > 1:
                check(".attempt%d." % k in (a.get("stdout") or ""), "%s attempt %d: its own output file (got %r)" % (tid, k, a.get("stdout")))
            text = output_of(pkg, a)
            if a.get("status") == "fail":
                check("planted failure" in text, "%s attempt %d: its output holds the planted failure" % (tid, k))
            if a.get("status") == "crash":
                check(a.get("signal_name") == "SIGABRT" and a.get("exit_code") is None,
                      "%s attempt %d: SIGABRT (got %r)" % (tid, k, a.get("signal_name")))
            if a.get("status") == "pass":
                check(a.get("exit_code") == 0 and a.get("message") == "", "%s attempt %d: exit 0, no message" % (tid, k))
        check(len(paths) == 2 * len(want), "%s: every attempt has output files of its own" % tid)
        last = (att or [{}])[-1]
        check(all(t.get(k) == last.get(k) for k in ("exit_code", "signal", "stdout", "stderr")),
              "%s: the test's fields are its last attempt's" % tid)
        if len(want) > 1:
            plain = t.get("message", "")
            for k, s in enumerate(want, 1):
                check(("attempt %d %s" % (k, s.upper())) in plain, "%s: message names attempt %d %s (got %r)" % (tid, k, s.upper(), plain))
    check(len(shas) == 1 and all(isinstance(s, str) and len(s) == 64 for s in shas),
          "json: one binary, one sha256, for every attempt of every test (got %r)" % shas)

    root = ET.parse(junit_xml).getroot()
    check((root.get("tests"), root.get("failures"), root.get("errors"), root.get("skipped")) == ("6", "1", "0", "1"),
          "junit: tests=6 failures=1 errors=0 skipped=1 (got %r)"
          % ((root.get("tests"), root.get("failures"), root.get("errors"), root.get("skipped")),))
    cases = {}
    for suite in root.findall("testsuite"):
        for c in suite.findall("testcase"):
            cases[c.get("classname") + "::" + c.get("name")] = c
    check(sorted(cases) == sorted(JUNIT), "junit: exactly the expected test cases (got %r)" % sorted(cases))
    for tid, want in JUNIT.items():
        c = cases.get(tid)
        if c is None:
            continue
        got = [(k.tag, k.get("type")) for k in c]
        check(got == want, "junit: %s holds %r (got %r)" % (tid, want, got))
        for k in c:
            if k.tag.startswith("flaky") or k.tag.startswith("rerun"):
                check((k.get("message") or "").startswith("attempt "), "junit: %s <%s> names its attempt" % (tid, k.tag))


def check_ignored(run_json):
    doc = load(run_json)
    tests = doc.get("tests", [])
    check([(t.get("id"), t.get("status")) for t in tests] == [(F + "::test_ignored_fails", "fail")],
          "--ignored: only the ignored test ran, and failed (got %r)" % [(t.get("id"), t.get("status")) for t in tests])
    check(doc.get("summary", {}).get("filtered_out") == 10, "--ignored: the 10 others filtered out (got %r)" % doc.get("summary"))
    check(doc.get("exit_code") == 1, "--ignored: exit_code 1")


def check_exact(run_json):
    doc = load(run_json)
    tests = doc.get("tests", [])
    want = [(M + "::test_gamma", "pass"), (N + "::test_alpha_one", "pass")]
    got = [(t.get("id"), t.get("status")) for t in tests]
    check(got == want, "--exact: exactly the two named tests ran, and passed (got %r)" % got)
    check(doc.get("summary", {}).get("filtered_out") == 9, "--exact: the 9 others filtered out (got %r)" % doc.get("summary"))
    check(doc.get("exit_code") == 0, "--exact: exit_code 0")


def main():
    mode = sys.argv[1]
    if mode == "retries":
        check_retries(*sys.argv[2:5])
    elif mode == "ignored":
        check_ignored(sys.argv[2])
    elif mode == "exact":
        check_exact(sys.argv[2])
    else:
        sys.exit("unknown mode " + mode)
    print("%d check(s) failed" % failures if failures else "all checks passed")
    sys.exit(1 if failures else 0)


main()
