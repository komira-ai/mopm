# Superseded by //:supervisor (tests/drivers/test_supervisor_test.zig) on the build farm, which has no shell, Python or pixi;
# kept for ci.yml until farm.yml has matched it. Change both together.
"""Check the results of `mopm test` on tests/e2e/supervise against the exact
verdict each fixture test must get (tests/e2e/test_supervisor.sh runs it).

    python3 -I tests/e2e/check_supervisor.py <run.json> <junit.xml> <package dir>

<package dir> is where mopm test ran (the stdout/stderr paths in the JSON
are relative to it). Prints one line per check; exits 1 if any check fails.
"""
import json
import os
import sys
import xml.etree.ElementTree as ET

V = "tests/test_verdicts.mojo"
M = "tests/test_memory.mojo"
N = "tests/test_native.mojo"
S = "tests/test_self_hosted.mojo"

# id -> (status, extra checks). Order is the order the run must report.
EXPECTED = [
    (M + "::test_oom", "oom", {"signal_name": "SIGKILL", "timeout": None}),
    (N + "::test_native", "pass", {"exit_code": 0}),
    (S + "::test_registered_pass", "pass", {"exit_code": 0}),
    (V + "::test_pass", "pass", {"exit_code": 0, "message": ""}),
    (V + "::test_assert_fails", "fail", {"signal": None, "output": "planted assertion"}),
    (V + "::test_raises", "fail", {"signal": None, "output": "planted raise"}),
    (V + "::test_abort", "crash", {"signal_name": "SIGABRT", "exit_code": None}),
    (V + "::test_segfault", "crash", {"signal_name": "SIGSEGV", "exit_code": None}),
    (V + "::test_after_crashes", "pass", {"exit_code": 0}),
    (V + "::test_hang", "timeout", {"timeout": "hung", "signal_name": "SIGKILL", "ms": (6000, 9000)}),
    (V + "::test_slow_ok", "pass", {"exit_code": 0, "ms": (4000, 6000)}),
    (V + "::test_spin_forever", "timeout", {"timeout": "slow", "signal_name": "SIGKILL", "ms": (6000, 9000)}),
    (V + "::test_exits_early", "fail", {"exit_code": 0, "message_has": "no PASS line"}),
]
SUMMARY = {"tests": 13, "pass": 5, "fail": 3, "crash": 2, "timeout": 2, "oom": 1, "compile_error": 0,
           "flaky": 0, "skip": 0, "filtered_out": 0}
JUNIT_TYPE = {"fail": ("failure", "FAIL"), "crash": ("error", "CRASH"), "timeout": ("error", "TIMEOUT"), "oom": ("error", "OOM")}

failures = 0


def check(ok, what):
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures += 1


def main():
    run_json, junit_xml, pkg = sys.argv[1:4]
    with open(run_json, encoding="utf-8") as f:
        doc = json.load(f)
    check(doc.get("schema") == 1, "json: schema is 1")
    check(doc.get("exit_code") == 1, "json: exit_code is 1 (got %r)" % doc.get("exit_code"))
    st = doc.get("settings", {})
    check(st.get("timeout_ms") == 6000 and st.get("memory_cap_bytes") == 512 << 20
          and st.get("memory_enforcement") == "rss-sampled" and st.get("opt_level") == 1
          and st.get("assert") == "all", "json: settings %r" % st)
    check(doc.get("summary") == SUMMARY, "json: summary %r" % doc.get("summary"))
    tests = doc.get("tests", [])
    got_ids = [t.get("id") for t in tests]
    want_ids = [e[0] for e in EXPECTED]
    check(got_ids == want_ids, "json: exactly the expected tests, in order (got %r)" % got_ids)
    by_id = {t.get("id"): t for t in tests}
    keys = {"id", "file", "name", "status", "ms", "cpu_ms", "peak_rss_bytes", "exit_code", "signal",
            "signal_name", "timeout", "leftover_processes", "message", "stdout", "stderr",
            "ignore", "binary_sha256", "attempts"}
    for tid, status, extra in EXPECTED:
        t = by_id.get(tid)
        if t is None:
            check(False, "%s: missing" % tid)
            continue
        check(set(t) == keys, "%s: the documented fields (got %r)" % (tid, sorted(t)))
        check(t.get("status") == status, "%s: status %s (got %s: %s)" % (tid, status, t.get("status"), t.get("message")))
        check(t.get("file") + "::" + t.get("name") == tid, "%s: file and name" % tid)
        check(t.get("leftover_processes") is False, "%s: no leftover processes" % tid)
        # No --retries: exactly one attempt, and the test's fields are its fields.
        att = t.get("attempts") or []
        check(len(att) == 1 and att[0].get("attempt") == 1 and att[0].get("status") == status
              and all(att[0].get(k) == t.get(k) for k in ("exit_code", "signal", "timeout", "message", "stdout", "stderr")),
              "%s: one attempt, the same as the test (got %r)" % (tid, att))
        sha = t.get("binary_sha256")
        check(isinstance(sha, str) and len(sha) == 64, "%s: binary_sha256 is a sha256 (got %r)" % (tid, sha))
        check(isinstance(t.get("ms"), int) and isinstance(t.get("cpu_ms"), int), "%s: ms and cpu_ms are integers" % tid)
        check((status == "pass") == (t.get("message") == ""), "%s: a message exactly when it did not pass" % tid)
        for k, v in extra.items():
            if k == "ms":
                check(v[0] <= t.get("ms", -1) < v[1], "%s: %d <= ms < %d (got %r)" % (tid, v[0], v[1], t.get("ms")))
            elif k == "message_has":
                check(v in t.get("message", ""), "%s: message mentions %r (got %r)" % (tid, v, t.get("message")))
            elif k == "output":
                text = ""
                for p in (t.get("stdout"), t.get("stderr")):
                    if p:
                        with open(os.path.join(pkg, p), encoding="utf-8", errors="replace") as f:
                            text += f.read()
                check(v in text, "%s: its captured output holds %r" % (tid, v))
            else:
                check(t.get(k) == v, "%s: %s is %r (got %r)" % (tid, k, v, t.get(k)))
        for p in (t.get("stdout"), t.get("stderr")):
            check(p is not None and os.path.isfile(os.path.join(pkg, p)), "%s: output file %r exists" % (tid, p))

    root = ET.parse(junit_xml).getroot()
    check(root.tag == "testsuites", "junit: root is <testsuites>")
    check((root.get("tests"), root.get("failures"), root.get("errors")) == ("13", "3", "5"),
          "junit: tests=13 failures=3 errors=5 (got %r)" % ((root.get("tests"), root.get("failures"), root.get("errors")),))
    cases = {}
    for suite in root.findall("testsuite"):
        sc = suite.findall("testcase")
        check(suite.get("tests") == str(len(sc)), "junit: suite %s counts its %d cases" % (suite.get("name"), len(sc)))
        for c in sc:
            cases[c.get("classname") + "::" + c.get("name")] = c
    check(sorted(cases) == sorted(want_ids), "junit: exactly the expected test cases")
    for tid, status, _ in EXPECTED:
        c = cases.get(tid)
        if c is None:
            continue
        kids = list(c)
        if status == "pass":
            check(kids == [], "junit: %s has no failure or error" % tid)
        else:
            elem, typ = JUNIT_TYPE[status]
            check(len(kids) == 1 and kids[0].tag == elem and kids[0].get("type") == typ,
                  "junit: %s is <%s type=%s>" % (tid, elem, typ))
    print("%d check(s) failed" % failures if failures else "all checks passed")
    sys.exit(1 if failures else 0)


main()
