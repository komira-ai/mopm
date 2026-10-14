#!/bin/sh
# Run the built CLI against tests/golden.
#   * `mopm link-plan` on each tests/fixtures/<case> set (tests/golden/<case>.txt).
#   * `mopm build|run|repl --print-cmd` on each environment under
#     tests/fixtures/env/<os>/<case>, for both the Linux and the macOS spelling
#     (tests/golden/cmd/<os>/<case>.<command>.txt).
#   * `mopm build|run|repl` without --print-cmd on tests/fixtures/env/exec,
#     whose bin/mojo is a script that prints what it was given and exits 7
#     (tests/golden/exec): argv, environment, stdin and exit status pass
#     through. The real mojo runs in tests/e2e.
#   * `mopm test --list` on tests/discovery (tests/golden/test): the test
#     files a package root holds, the tests each one has, and the refusals.
#     The scanner's per-file goldens are unit tests (src/core/test_scan.zig);
#     building and listing real harnesses is tests/e2e/test_discovery.sh.
# The repository root is written as @ROOT@ in the golden files.
# Usage: tests/run_golden.sh [path-to-mopm]   (run from the repository root)
set -u
mopm=${1:-./zig-out/bin/mopm}
root=$(pwd -P)
fail=0

# check <name> <expected exit code> <package>...
check() {
    name=$1
    want=$2
    shift 2
    files=""
    for p in "$@"; do files="$files tests/fixtures/$name/$p.mopm.json"; done
    # shellcheck disable=SC2086
    "$mopm" link-plan $files > "golden_$name.out"
    rc=$?
    if [ "$rc" -ne "$want" ]; then
        echo "FAIL $name: exit $rc, want $want"
        fail=1
    fi
    if ! diff -u "tests/golden/$name.txt" "golden_$name.out"; then
        echo "FAIL $name: output differs from tests/golden/$name.txt"
        fail=1
    else
        echo "ok   $name"
    fi
    rm -f "golden_$name.out"
}

check chain 0 http_client crypto
check missing 1 http_client
check dup 1 pkg_a pkg_b
check static 1 staticpkg

# mopm metadata: a manifest that is accepted prints its JSON; one that is refused
# exits non-zero with path:line:column and the message.
if "$mopm" metadata tests/manifest/valid/full.toml > metadata.out; then
    diff -u tests/manifest/valid/full.json metadata.out || { echo "FAIL metadata output"; fail=1; }
else
    echo "FAIL metadata refused tests/manifest/valid/full.toml"; fail=1
fi
rm -f metadata.out
bad=tests/manifest/invalid/duplicate_key
if got=$("$mopm" metadata "$bad.toml" 2>&1 >/dev/null); then
    echo "FAIL metadata accepted $bad.toml"; fail=1
fi
[ "$got" = "mopm: $bad.toml:$(cat "$bad.err")" ] || { echo "FAIL metadata error text: $got"; fail=1; }

# cmd <label> <golden file> <expected exit code> <mopm args>...
# Runs with CONDA_PREFIX and MODULAR_HOME unset unless the args set them
# through env(1), and stdin from $golden_stdin; stdout and stderr are
# compared together.
golden_stdin=/dev/null
cmd() {
    label=$1
    gold=$2
    want=$3
    shift 3
    env -u CONDA_PREFIX -u MODULAR_HOME "$@" < "$golden_stdin" > golden_cmd.raw 2>&1
    rc=$?
    sed "s|$root|@ROOT@|g" golden_cmd.raw > golden_cmd.out
    if [ "$rc" -ne "$want" ]; then
        echo "FAIL $label: exit $rc, want $want"
        fail=1
    fi
    if ! diff -u "$gold" golden_cmd.out; then
        echo "FAIL $label: output differs from $gold"
        fail=1
    else
        echo "ok   $label"
    fi
    rm -f golden_cmd.raw golden_cmd.out
}

# want <case> <command>: the expected exit code.
want() {
    case "$1.$2" in
        chain.*) echo 0 ;;
        static.build) echo 0 ;;
        *) echo 1 ;;
    esac
}

for os in linux macos; do
    for c in chain missing dup static; do
        env=tests/fixtures/env/$os/$c
        g=tests/golden/cmd/$os/$c
        cmd "$os/$c build" "$g.build.txt" "$(want $c build)" \
            "$mopm" build hello.mojo -o hello --prefix "$env" --os "$os" --print-cmd
        cmd "$os/$c run" "$g.run.txt" "$(want $c run)" \
            "$mopm" run hello.mojo --prefix "$env" --os "$os" --print-cmd
        cmd "$os/$c repl" "$g.repl.txt" "$(want $c repl)" \
            "$mopm" repl --prefix="$env" --os="$os" --print-cmd
    done
done

# A library the metadata names but the environment lacks.
cmd "linux/nofile build" tests/golden/cmd/linux/nofile.build.txt 1 \
    "$mopm" build hello.mojo -o hello --prefix tests/fixtures/env/linux/nofile --os linux --print-cmd

# Where the environment comes from: --prefix, then CONDA_PREFIX, then
# MODULAR_HOME. Each source points at the chain environment while every
# lower-ranked one points at the dup environment, which is refused, so a
# wrong order changes the output.
chain=$root/tests/fixtures/env/linux/chain
dup=$root/tests/fixtures/env/linux/dup
g=tests/golden/cmd/linux/chain.repl.txt
cmd "prefix: --prefix beats both variables" "$g" 0 \
    env CONDA_PREFIX="$dup" MODULAR_HOME="$dup/share/max" "$mopm" repl --prefix "$chain" --os linux --print-cmd
cmd "prefix: CONDA_PREFIX beats MODULAR_HOME" "$g" 0 \
    env CONDA_PREFIX="$chain" MODULAR_HOME="$dup/share/max" "$mopm" repl --os linux --print-cmd
cmd "prefix: MODULAR_HOME minus /share/max" "$g" 0 \
    env MODULAR_HOME="$chain/share/max" "$mopm" repl --os linux --print-cmd
cmd "prefix: an empty CONDA_PREFIX counts as unset" "$g" 0 \
    env CONDA_PREFIX= MODULAR_HOME="$chain/share/max" "$mopm" repl --os linux --print-cmd
cmd "prefix: none" tests/golden/cmd/no_prefix.txt 1 \
    "$mopm" repl --os linux --print-cmd
cmd "prefix: MODULAR_HOME of another shape" tests/golden/cmd/bad_modular_home.txt 1 \
    env MODULAR_HOME="$chain" "$mopm" repl --os linux --print-cmd
cmd "prefix: not a Mojo environment" tests/golden/cmd/not_mojo_env.txt 1 \
    "$mopm" repl --prefix tests/fixtures/env --os linux --print-cmd

# Without --print-cmd mopm execs <prefix>/bin/mojo. The stand-in exits 7, so
# exit 7 means mopm handed over mojo's status. Its MODULAR_HOME must be the
# prefix's even when the caller's points elsewhere; other variables pass.
exec_env=tests/fixtures/env/exec
case "$(uname -s)" in Darwin) host=macos ;; *) host=linux ;; esac
cmd "exec: run" tests/golden/exec/run.txt 7 \
    env MODULAR_HOME="$dup/share/max" MOPM_GOLDEN_MARK=kept "$mopm" run hello.mojo --prefix "$exec_env"
cmd "exec: build" "tests/golden/exec/build.$host.txt" 7 \
    "$mopm" build hello.mojo -o hello --prefix "$exec_env"
golden_stdin=tests/golden/exec/repl.stdin
cmd "exec: repl reads stdin" "tests/golden/exec/repl.$host.txt" 7 \
    "$mopm" repl --prefix "$exec_env"
golden_stdin=/dev/null
cmd "exec: no bin/mojo in the environment" tests/golden/exec/no_mojo.txt 127 \
    "$mopm" run hello.mojo --prefix "$chain"
"$mopm" run hello.mojo --prefix "$exec_env" --os linux > golden_cmd.raw 2>&1
rc=$?
if [ "$rc" -ne 2 ] || ! head -n 1 golden_cmd.raw | grep -q -- "--os applies only with --print-cmd"; then
    echo "FAIL exec: --os without --print-cmd: exit $rc, want 2 and a usage message"
    fail=1
else
    echo "ok   exec: --os without --print-cmd is a usage error"
fi
rm -f golden_cmd.raw

# mopm test --list. A package root (one passed as a path, and the current
# directory); a file named twice is listed once; explicit files; a file
# whose tests do not conform (exit 2, nothing listed); a self-hosted file
# with nothing mopm can read (a warning, exit 0); usage errors. Then the
# refusals of `mopm test` (running) that need no Mojo: no environment (exit
# 5), no tests (exit 2, or 0 with --allow-empty). Running real tests is
# tests/e2e/test_supervisor.sh.
g=tests/golden/test
cmd "test --list: a package root" "$g/tree.txt" 0 \
    "$mopm" test --list tests/discovery/tree
cmd "test --list: a file under the root named again is listed once" "$g/tree.txt" 0 \
    "$mopm" test --list tests/discovery/tree tests/discovery/tree/tests/test_bare.mojo
mopm_abs=$(cd "$(dirname "$mopm")" && pwd -P)/$(basename "$mopm")
(cd tests/discovery/tree && "$mopm_abs" test --list) > golden_cmd.out 2>&1
rc=$?
if [ "$rc" -ne 0 ] || ! diff -u "$g/tree_dot.txt" golden_cmd.out; then
    echo "FAIL test --list: the current directory (exit $rc)"
    fail=1
else
    echo "ok   test --list: the current directory"
fi
rm -f golden_cmd.out
cmd "test --list: explicit files" "$g/files.txt" 0 \
    "$mopm" test --list tests/discovery/self_hosted_explicit.mojo tests/discovery/bare_basic.mojo
cmd "test --list: nonconforming tests are refused" "$g/nonconforming.txt" 2 \
    "$mopm" test --list tests/discovery/nonconforming.mojo tests/discovery/bare_basic.mojo
cmd "test --list: a self-hosted file without readable registrations" "$g/self_hosted_none.txt" 0 \
    "$mopm" test --list tests/discovery/self_hosted_none.mojo
cmd "test --list: --prefix without --check" "$g/check_only.txt" 2 \
    "$mopm" test --list --prefix /nowhere
cmd "test --list: a flag that applies only to running tests" "$g/list_run_flag.txt" 2 \
    "$mopm" test --list --timeout 5
cmd "test: running with no environment" "$g/no_env.txt" 5 \
    "$mopm" test --prefix /nowhere tests/discovery/tree
cmd "test: no tests at all" "$g/no_tests.txt" 2 \
    "$mopm" test tests/discovery/none.mojo
cmd "test: no tests at all, --allow-empty" "$g/empty.txt" 0 \
    "$mopm" test --allow-empty tests/discovery/none.mojo
cmd "test --list: a path that does not exist" "$g/missing.txt" 2 \
    "$mopm" test --list tests/discovery/no_such_dir

# Selection (src/core/test_filter.zig) over the fixture package of
# tests/e2e/test_flaky.sh: 11 tests in 3 files, test_alpha_one in two of
# them, test_ignored_fails marked `# mopm: ignore`. --list prints exactly
# what a run would run; tests/e2e/test_flaky.sh shows a run runs exactly
# that. The last cases select nothing to run, so they need no Mojo: exit 2,
# or 0 with --allow-empty; an ignored test is still reported, as SKIP.
fx=tests/e2e/flaky
fxt=$fx/tests
cmd "test --list: no filter (the ignored test is not listed)" "$g/filter_none.txt" 0 \
    "$mopm" test --list "$fx"
cmd "test --list: a substring of <file>::<test>" "$g/filter_substring.txt" 0 \
    "$mopm" test --list "$fx" -- alpha
cmd "test --list: globs, on the name or the whole id" "$g/filter_glob.txt" 0 \
    "$mopm" test --list "$fx" -- 'test_?eta' "$fxt/sub/*::test_g*"
cmd "test --list: --exact takes the whole id" "$g/filter_exact.txt" 0 \
    "$mopm" test --list --exact "$fx" -- "$fxt/test_names.mojo::test_alpha_one"
cmd "test --list: --exact with a bare name selects nothing" "$g/filter_exact_name.txt" 0 \
    "$mopm" test --list --exact "$fx" -- test_alpha_one
cmd "test --list: --skip, twice" "$g/filter_skip.txt" 0 \
    "$mopm" test --list "$fx" --skip alpha --skip=fails
cmd "test --list: --ignored lists only the ignored test" "$g/filter_ignored.txt" 0 \
    "$mopm" test --list --ignored "$fx"
cmd "test --list: --include-ignored with patterns" "$g/filter_include_ignored.txt" 0 \
    "$mopm" test --list --include-ignored "$fx" -- ignored steady
cmd "test: patterns that leave nothing to run" "$g/filter_none_selected.txt" 2 \
    "$mopm" test --ignored "$fx" -- alpha
cmd "test: only an ignored test selected (SKIP, nothing to run)" "$g/filter_only_ignored.txt" 2 \
    "$mopm" test "$fx" -- ignored
cmd "test: only an ignored test selected, --allow-empty" "$g/filter_only_ignored_allow.txt" 0 \
    "$mopm" test --allow-empty "$fx" -- ignored

[ "$("$mopm" --version)" = "mopm 0.0.1" ] || { echo "FAIL --version"; fail=1; }
"$mopm" add > /dev/null 2>&1 && { echo "FAIL planned command should exit non-zero"; fail=1; }
"$mopm" add 2>&1 | grep -q "not implemented yet" || { echo "FAIL planned command message"; fail=1; }
exit "$fail"
