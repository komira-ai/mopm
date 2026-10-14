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

[ "$("$mopm" --version)" = "mopm 0.0.1" ] || { echo "FAIL --version"; fail=1; }
"$mopm" add > /dev/null 2>&1 && { echo "FAIL planned command should exit non-zero"; fail=1; }
"$mopm" add 2>&1 | grep -q "not implemented yet" || { echo "FAIL planned command message"; fail=1; }
exit "$fail"
