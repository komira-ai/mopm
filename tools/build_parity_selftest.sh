#!/bin/sh
# Shows tools/build_parity.sh can fail: it passes on this repository's build.zig
# and BUCK, and goes red, with the reason, on each of these mutants (copies in a
# scratch directory; the repository is only read):
#   a test added to build.zig and not to BUCK
#   a zig_test removed from BUCK
#   a zig_test that no unit_tests list names
#   an executable renamed in BUCK
#   a module whose root file differs between the two
# Usage: tools/build_parity_selftest.sh   (from any directory)
set -u
here=$(cd "$(dirname "$0")/.." && pwd -P)
parity=$here/tools/build_parity.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mopm_parity_selftest.XXXXXX") || exit 1
trap 'rm -rf "$scratch"' EXIT
fail=0

if sh "$parity" "$here/build.zig" "$here/BUCK" "$here" > "$scratch/clean.out" 2>&1; then
    echo "ok   the repository's build.zig and BUCK agree"
else
    cat "$scratch/clean.out"
    echo "FAIL the repository's build.zig and BUCK are reported to disagree"
    fail=1
fi

# red <name> <pattern>: build.zig is $scratch/build.zig and BUCK $scratch/BUCK;
# the run must exit non-zero and its output must match <pattern> (grep -E).
red() {
    if sh "$parity" "$scratch/build.zig" "$scratch/BUCK" "$here" > "$scratch/out" 2>&1; then
        echo "FAIL $1: build_parity.sh passed"
        fail=1
    elif ! grep -Eq -- "$2" "$scratch/out"; then
        cat "$scratch/out"
        echo "FAIL $1: build_parity.sh failed, but not with /$2/"
        fail=1
    else
        echo "ok   $1: red"
    fi
}

fresh() {
    cp "$here/build.zig" "$scratch/build.zig"
    cp "$here/BUCK" "$scratch/BUCK"
}

fresh
sed '$d' "$here/build.zig" > "$scratch/build.zig"
cat >> "$scratch/build.zig" <<'ZIG'

    const toml_tests = b.addTest(.{
        .root_source_file = b.path("src/core/toml.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&b.addRunArtifact(toml_tests).step);
}
ZIG
red "a test in build.zig and not in BUCK" '^-test src/core/toml\.zig$'

fresh
awk '
/^zig_test\(/ { buf = $0; hold = 1; next }
hold { buf = buf "\n" $0; if ($0 ~ /name = "cli_test"/) drop = 1; if ($0 ~ /^\)/) { if (!drop) print buf; hold = 0; drop = 0 } ; next }
{ print }
' "$here/BUCK" > "$scratch/BUCK"
red "a zig_test removed from BUCK" '^-test src/cli/main\.zig$'

fresh
sed 's/":fake_test"/":nothing"/' "$here/BUCK" > "$scratch/BUCK"
red "a zig_test no unit_tests list names" 'zig_test fake_test is in no unit_tests list'

fresh
sed 's/name = "mopm-fake-registry"/name = "mopm-fake"/' "$here/BUCK" > "$scratch/BUCK"
red "an executable renamed in BUCK" '^-exe mopm-fake-registry '

fresh
awk '!d && /src\/core\/mopm_core\.zig/ { sub(/mopm_core\.zig/, "toml.zig"); d = 1 } { print }' "$here/build.zig" > "$scratch/build.zig"
red "a module root that differs" '^[-+]module mopm_core '

exit "$fail"
