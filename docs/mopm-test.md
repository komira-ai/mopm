# mopm test

`mopm test` finds the tests of a Mojo package, builds each test file once,
and runs every test in a process of its own under a supervisor. This page is
the reference for its flags, its verdicts, its JSON output and its exit
codes. The code is `src/cli/test_cmd.zig` and `src/core/test_*.zig`.

```text
mopm test [<path>...] [--prefix <dir>] [--timeout <seconds>] [--memory <MiB>]
          [--opt-level <0-3>] [--format human|json] [--junit <file>]
          [--allow-empty] [--strict-discovery] [--retries <n>] [--deny-flaky]
          [<selection>] [-- <pattern>...]
mopm test --list [--check [--strict-discovery] [--prefix <dir>]]
          [<selection>] [<path>...] [-- <pattern>...]
<selection>: [--skip <pattern>]... [--exact] [--ignored | --include-ignored]
```

## What it does

1. **Discovery.** A `<path>` that is a directory is a package root: its test
   files are `tests/**/test_*.mojo` and `src/**/tests/test_*.mojo` (hidden
   directories skipped). A `<path>` that is a file is a test file as given.
   The default is `.`. The tests of a file are read from its source
   (`src/core/test_scan.zig`): the top-level `def test_*() raises` functions
   of a file without `main` ("bare"), or what the `main` of a "self-hosted"
   file registers.
2. **Build, once per file.** A bare file is built through a generated
   harness (`target/mopm/gen/<hash>/<file>.mojo`: the file unchanged, then a
   `main` registering each test with `std.testing.TestSuite`). The command is
   the `mojo build` line of `mopm build` (the same environment, the same
   native link arguments, so a test of a package with native libraries links
   them exactly as `mopm build` does), plus `-D ASSERT=all` and
   `--optimization-level 1` (`--opt-level` changes the level), and `-I <root>/src` when the package has a `src/`
   directory, so that a test can import the package it belongs to (`from my_pkg import f`, as `mopm new` writes
   it). The binary is
   `target/mopm/bin/<hash>/<stem>`.
3. **Listing check.** Each binary runs once with `--skip-all`, and the names
   it lists are compared with the scan. For a generated harness a difference
   is an error; for a self-hosted file it is a warning, an error with
   `--strict-discovery`.
4. **Selection** (below): only the tests the patterns select run, and only
   files with a test to run are built (step 2 and 3 apply to them alone).
5. **Run, one process per test**: `<binary> --only <test>`, stdin from
   `/dev/null`, stdout and stderr to
   `target/mopm/test/<hash>/<test>.stdout` and `.stderr`. Tests run one at a
   time, files in path order and tests in source order. A crash ends only
   its own process, so it never loses another test's result. With
   `--retries` a test that did not pass runs again (below).

## Selection

A test's id is `<file>::<test>`, the file as listed (relative to the
current directory). The patterns are everything after `--` (so a pattern
can never be taken for a path or an option):

* a pattern holding `*`, `?` or `[` is a glob (`*` any run of characters,
  `/` and `:` included; `?` one character; `[abc]`, `[a-z]`, `[!a]` one
  character of a set), matched against the whole id or against the test
  name alone: `-- 'test_parse_*'`, `-- 'tests/net/*'`;
* any other pattern selects the tests whose id contains it: `-- parse`;
* `--exact`: a pattern selects only the test whose id it equals:
  `--exact -- tests/test_parse.mojo::test_bom`.

No pattern selects every test; several select any test one of them
selects. `--skip <pattern>` (repeatable, same rules, `--exact` included)
removes the tests it selects. `--list` prints exactly the tests a run with
the same selection would run. The tests left out are counted as "filtered
out" in the summary and in the JSON, and do not appear otherwise.

**Ignored tests.** A comment line directly above a test (or above its
decorators) marks it ignored:

```mojo
# mopm: ignore "needs network" #123
def test_download() raises:
    ...
```

The reason (in double quotes, not empty) and an issue reference (`#<n>`,
`<owner>/<repo>#<n>`, or an https URL) are both required, so every ignored
test says why and where that is tracked; a directive without them is a
discovery error (exit 2). An ignored test stays in its file's generated
harness, so it compiles whenever the file is built, but a file whose only
selected tests are ignored is not built. By default an ignored test does
not run and is reported as SKIP with its reason; `--ignored` runs only the ignored tests,
`--include-ignored` runs every test.

When nothing is left to run (everything filtered out or ignored) the run
exits 2, like a package without tests, unless `--allow-empty`.

## Retries and FLAKY

`--retries <n>` (0 to 100, default 0) runs a test that did not pass (FAIL,
CRASH, TIMEOUT, OOM) again, up to `n` more times, stopping at the first
pass. Every attempt runs the same binary (its sha256 is in the JSON) with
the same argv, in the same environment and directory, so the inputs mopm
controls are the same:

* a test that did not pass and then passed is **FLAKY**, never PASS: the
  same inputs both passed and failed;
* a test that never passed gets the verdict of its last attempt;
* every attempt is recorded: in the JSON (`attempts`), in JUnit (below), in
  its own output files (attempt 1 `<test>.stdout`, attempt `k`
  `<test>.attempt<k>.stdout`, the same for stderr), and in the human
  output (`attempt 1 FAIL (exit status 1), attempt 2 PASS`, then the
  output tail of each attempt that did not pass).

A FLAKY test does not fail the run on its own: the run exits 0 with a
warning on stderr. `--deny-flaky` makes any FLAKY test fail the run (exit
1); use it in CI, so a retry never turns a failure into a silent green.
There is no flake history across runs yet.

## The supervisor

Each test process is the leader of a new process group. The supervisor
polls it every 20 ms.

* **Deadline** (`--timeout`, whole seconds, default 60): when it passes, the
  whole process group is killed with SIGKILL and the verdict is TIMEOUT,
  qualified by liveness. `hung`: the test process used less than 5% of one
  CPU over the last window before the deadline (window = min(1 s, deadline
  / 2)). `slow`: it was still computing. `unknown`: its CPU time could not
  be read.
* **Memory cap** (`--memory`, MiB, default min(4096, physical memory); `0`
  turns it off): when a sample of the test process's resident size is above
  the cap, the group is killed and the verdict is OOM. Applied on Linux
  (resident size from `/proc/<pid>/status`, `VmRSS`) and on macOS (physical
  footprint from `proc_pid_rusage`, the number the macOS memory limiter
  uses). It is a sampled cap, not a kernel limit: a spike shorter than one
  poll can pass it, and only the test process itself is measured, not
  processes it starts. An address-space rlimit is not used: it would also
  refuse address space the Mojo runtime reserves without touching, and macOS
  does not enforce RLIMIT_AS or RLIMIT_RSS.
* **Cleanup.** After the test process ends, for any reason, the group is
  killed again, so a process the test started does not outlive it. The
  supervisor then checks for two seconds that the group is empty; if it is
  not, it says so on stderr and the run exits 5.

`--test-only-no-group-kill` exists for the supervisor's own end-to-end
self-test (`tests/e2e/test_supervisor.sh`): it signals only the test process
and skips the cleanup kill, so the self-test can show that a process left
behind is detected. Do not use it otherwise.

## Verdicts

The first rule that applies:

| verdict | when |
|---|---|
| OOM | mopm killed the test: its resident size passed the memory cap |
| TIMEOUT | mopm killed the test at the deadline (`hung`, `slow` or `unknown`) |
| CRASH | the test process died by a signal; the signal is reported (SIGABRT for `abort()`, SIGSEGV for a bad memory access) |
| FAIL | the test process exited non-zero (an assertion or an error raised by the test), or exited 0 without printing the TestSuite line `PASS [ <time> ] <test>`: a test that ends the process early has not passed |
| PASS | exit status 0 and that `PASS` line |
| COMPILE-ERROR | every test of a file that did not build |
| FLAKY | with `--retries`: an attempt did not pass, and a later one passed |
| SKIP | a test marked `# mopm: ignore`, not asked for with `--ignored` or `--include-ignored`; it did not run |

With retries, the rules above give the verdict of each attempt.

## Output

Human (the default): one line per test as it finishes,
`<VERDICT> <file>::<test> (<ms> ms)[: <why>]`; then, for each test that did
not pass, the last lines of its stdout and stderr; then a summary line.
Discovery and build messages go to stderr.

`--junit <file>` writes JUnit XML: one `<testsuite>` per test file, one
`<testcase classname="<file>" name="<test>" time="<s>">` per test. FAIL is a
`<failure type="FAIL">`; CRASH, TIMEOUT, OOM and COMPILE-ERROR are an
`<error type="<VERDICT>">`; SKIP is a `<skipped message="<reason>"/>`. The
element's `message` is the reason, its text the end of the test's output.
`failures` counts FAIL, `errors` CRASH, TIMEOUT, OOM and COMPILE-ERROR,
`skipped` SKIP. Attempts are recorded the way Maven Surefire records reruns:
a FLAKY test is a passed `<testcase>` holding one `<flakyFailure>` (FAIL) or
`<flakyError>` (the other verdicts) per attempt that did not pass; a test
that never passed holds its `<failure>`/`<error>` (the last attempt) and one
`<rerunFailure>`/`<rerunError>` per earlier attempt. Their `message` starts
with `attempt <k>: `.

`--format json` prints one JSON document on stdout (nothing else goes to
stdout). Schema 1:

```json
{
  "schema": 1,
  "exit_code": 1,
  "settings": {"timeout_ms": 60000, "memory_cap_bytes": 4294967296,
               "memory_enforcement": "rss-sampled", "opt_level": 1, "assert": "all",
               "retries": 0, "deny_flaky": false},
  "summary": {"tests": 2, "pass": 1, "fail": 0, "crash": 1, "timeout": 0,
              "oom": 0, "compile_error": 0, "flaky": 0, "skip": 0, "filtered_out": 0},
  "tests": [
    {"id": "tests/test_x.mojo::test_a", "file": "tests/test_x.mojo", "name": "test_a",
     "status": "pass", "ms": 41, "cpu_ms": 30, "peak_rss_bytes": 31457280,
     "exit_code": 0, "signal": null, "signal_name": null, "timeout": null,
     "leftover_processes": false, "message": "",
     "stdout": "target/mopm/test/1a2b3c4d5e6f7a8b/test_a.stdout",
     "stderr": "target/mopm/test/1a2b3c4d5e6f7a8b/test_a.stderr",
     "ignore": null, "binary_sha256": "<64 hex digits>",
     "attempts": [{"attempt": 1, "status": "pass", "ms": 41, "cpu_ms": 30,
                   "peak_rss_bytes": 31457280, "exit_code": 0, "signal": null,
                   "signal_name": null, "timeout": null, "leftover_processes": false,
                   "message": "", "stdout": "target/mopm/test/1a2b3c4d5e6f7a8b/test_a.stdout",
                   "stderr": "target/mopm/test/1a2b3c4d5e6f7a8b/test_a.stderr"}]}
  ]
}
```

| field | meaning |
|---|---|
| `schema` | 1. A field is never removed or changed in meaning without a new number; new fields may appear. |
| `exit_code` | the exit status of this run (below) |
| `settings.memory_cap_bytes` | the cap, or `null` with `--memory 0` |
| `settings.memory_enforcement` | `"rss-sampled"`, or `"none"` when there is no cap |
| `settings.retries`, `deny_flaky` | `--retries` (0 without it) and `--deny-flaky` |
| `summary.flaky`, `skip` | FLAKY and SKIP tests (both are in `tests`) |
| `summary.filtered_out` | tests the selection left out (not in `tests`) |
| `tests[].status` | `pass`, `fail`, `crash`, `timeout`, `oom`, `compile-error`, `flaky` or `skip` |
| `tests[].ms`, `cpu_ms` | wall time; CPU time (user + system) of the test process |
| `tests[].peak_rss_bytes` | the largest sampled resident size, or `null` |
| `tests[].exit_code` | the exit status, or `null` when the process died by a signal |
| `tests[].signal`, `signal_name` | the signal that ended the process (`9`, `"SIGKILL"` after a TIMEOUT or OOM kill), or `null` |
| `tests[].timeout` | `"hung"`, `"slow"` or `"unknown"` for TIMEOUT, else `null` |
| `tests[].leftover_processes` | the test's process group outlived it (see Cleanup) |
| `tests[].message` | one line saying why it did not pass; empty for PASS |
| `tests[].stdout`, `stderr` | the files holding its output, or `null` when it did not run |
| `tests[].ignore` | `{"reason": ..., "issue": ...}` for a test marked `# mopm: ignore`, else `null` |
| `tests[].binary_sha256` | sha256 of the binary every attempt ran, or `null` when it did not run |
| `tests[].attempts` | every attempt in order, each `{"attempt": <k from 1>, "status": ...}` plus the fields `ms` to `stderr`; `[]` for SKIP and COMPILE-ERROR. The test's own `ms` to `stderr` are its last attempt's |

## Exit status

| code | meaning |
|---|---|
| 0 | every test that ran passed, FLAKY included (without `--deny-flaky`) |
| 1 | a test did not pass (FAIL, CRASH, TIMEOUT, OOM), or FLAKY with `--deny-flaky` |
| 2 | a usage error, a discovery error, a `--skip-all` listing that differs from the scan, a test file that did not build, or no test to run (unless `--allow-empty`) |
| 5 | a mopm or toolchain problem: no usable environment, a `--skip-all` listing mopm cannot read (a Mojo whose `TestSuite` prints another shape), or a process group that outlived its test |

When several apply, the highest wins.

## Not yet

Running tests in parallel (`--jobs`), a flake history across runs, the
`should-abort`, `timeout` and `serial` directives, `--failed`,
`--partition`, `--shuffle`, the result cache, and a watchdog for a compile
that hangs.
