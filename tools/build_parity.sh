' "$buckfile" > "$scratch/buck.raw" || exit 1
canon "$scratch/buck.raw" > "$scratch/buck.canon"' "$zigfile" > "$scratch/zig.raw" || exit 1
canon "$scratch/zig.raw" > "$scratch/zig.canon"#!/bin/sh
# Fails if build.zig and the BUCK file describe different builds.
#
# `zig build` (build.zig) is a contributor's quick path; Buck2 (BUCK) is what
# the farm builds. Both name the same Zig root files, executables, modules and
# unit tests, and a change to one without the other would let them drift:
# a test that `zig build test` runs but no Buck2 target does, or the reverse.
# This script reads both files, writes what each one says in one form, and
# diffs the two. It also checks that every zig_test in BUCK is welded (listed
# in the `unit_tests` of something), and that every root file exists.
#
# The canonical lines:
#   exe <name> <root>        an executable and its root source file
#   module <name> <root>     a module imported by name, and its root
#   test <root>              one unit-test binary of that root (repeats count)
#   import <root> <name>     the file at <root> imports the module <name>
#
# It reads the files as they are written today: build.zig with one
# `b.addExecutable(.{`, `b.addTest(.{` or `b.createModule(.{` per block, a
# `.name` and a `.root_source_file = b.path("...")` inside it, and
# `<var>.root_module.addImport("<name>", <module var>)`; BUCK with one
# `zig_exe(`, `zig_module(` or `zig_test(` call per block, `name = "..."` and
# `src = "..."` on lines of their own, `deps = [":name", ...]` and
# `unit_tests = [":name", ...]` each on one line. A form it does not
# understand is an error, not a pass: a block without a root source file, a
# loop or a macro in place of a call is reported.
#
# Usage: tools/build_parity.sh [build.zig [BUCK [root]]]   (from any directory;
# `root` is the directory the root source files are relative to, by default
# the one holding build.zig)
# Needs a POSIX sh with awk, sort, diff and mktemp (busybox has them).
set -eu

here=$(cd "$(dirname "$0")/.." && pwd -P)
zigfile=${1:-$here/build.zig}
buckfile=${2:-$here/BUCK}
srcroot=${3:-$(dirname "$zigfile")}

# Sorted; a line twice is one, except `test` (two test binaries of one root
# are two). A module imported by two files is one `module` line.
canon() {
    { grep -v '^test ' "$1" | sort -u || true; grep '^test ' "$1" || true; } | sort
}

scratch=$(mktemp -d "${TMPDIR:-/tmp}/mopm_parity.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

# ---- build.zig ---------------------------------------------------------
awk '
function quoted(s, key,    t) {          # the "..." after `key`
    t = s
    sub(".*" key "[^\"]*\"", "", t)
    sub("\".*", "", t)
    return t
}
function fail(msg) { print "build_parity: " FILENAME ":" NR ": " msg > "/dev/stderr"; bad = 1 }
/b\.(addExecutable|addTest|createModule)\(\.\{/ {
    if (inblock) fail("a block inside a block")
    kind = ($0 ~ /addExecutable/) ? "exe" : ($0 ~ /addTest/) ? "test" : "module"
    var = $0; sub(/^[ \t]*const[ \t]+/, "", var); sub(/[ \t]*=.*/, "", var)
    if (var == "" || var ~ /[^A-Za-z0-9_]/) var = "?" NR
    name = ""; root = ""; inblock = 1; next
}
inblock && /\.name[ \t]*=/ { name = quoted($0, "\\.name[ \t]*=[ \t]*") }
inblock && /\.root_source_file[ \t]*=/ { root = quoted($0, "b\\.path\\(") }
inblock && /^[ \t]*\}\);[ \t]*$/ {
    inblock = 0
    if (root == "") { fail(kind " block " var " has no .root_source_file = b.path(\"...\")"); next }
    if (kind == "exe" && name == "") { fail("executable " var " has no .name"); next }
    varroot[var] = root
    if (kind == "exe") print "exe " name " " root
    else if (kind == "test") print "test " root
    next
}
/\.root_module\.addImport\(/ {
    importer = $0; sub(/^[ \t]*/, "", importer); sub(/\.root_module.*/, "", importer)
    args = $0; sub(/.*\.root_module\.addImport\(/, "", args)
    iname = args; sub(/^"/, "", iname); sub(/".*/, "", iname)
    mvar = args; sub(/^[^,]*,[ \t]*/, "", mvar); sub(/\).*/, "", mvar)
    if (!(importer in varroot) || !(mvar in varroot)) { fail("addImport of " iname ": " importer " or " mvar " is not a block of this file"); next }
    print "import " varroot[importer] " " iname
    print "module " iname " " varroot[mvar]
}
END { if (inblock) fail("a block never closes"); exit bad }
' "$zigfile" > "$scratch/zig.raw" || exit 1
canon "$scratch/zig.raw" > "$scratch/zig.canon"

# ---- BUCK --------------------------------------------------------------
awk '
function quoted(s,    t) { t = s; sub(/^[^"]*"/, "", t); sub(/".*/, "", t); return t }
function names(s,    t, n, i, parts, out, p) {   # [":a", ":b"] -> " a b"
    t = s; sub(/^[^\[]*\[/, "", t); sub(/\].*/, "", t)
    n = split(t, parts, ",")
    out = ""
    for (i = 1; i <= n; i++) {
        p = parts[i]; gsub(/[ \t"]/, "", p); sub(/^:/, "", p)
        if (p != "") out = out " " p
    }
    return out
}
function fail(msg) { print "build_parity: " FILENAME ":" NR ": " msg > "/dev/stderr"; bad = 1 }
/^[ \t]*for[ \t]/ || /^\[/ { fail("a loop or comprehension: this script reads only plain calls") }
/^zig_(exe|module|test)\(/ {
    kind = $0; sub(/^zig_/, "", kind); sub(/\(.*/, "", kind)
    name = ""; src = ""; deps = ""; incall = 1; next
}
incall && /^[ \t]*name[ \t]*=/ { name = quoted($0) }
incall && /^[ \t]*src[ \t]*=/ { src = quoted($0) }
incall && /^[ \t]*deps[ \t]*=/ { deps = names($0) }
incall && /^[ \t]*unit_tests[ \t]*=/ { u = names($0); n = split(u, us, " "); for (i = 1; i <= n; i++) welded[us[i]] = 1 }
incall && /^\)/ {
    incall = 0
    if (name == "" || src == "") { fail(kind " call without name or src"); next }
    if (kind == "test") { print "test " src; testname[name] = 1 }
    else print kind " " name " " src
    n = split(deps, ds, " ")
    for (i = 1; i <= n; i++) print "import " src " " ds[i]
}
END {
    for (t in testname) if (!(t in welded)) { print "build_parity: BUCK: zig_test " t " is in no unit_tests list, so nothing waits for it" > "/dev/stderr"; bad = 1 }
    if (incall) { print "build_parity: BUCK: a call never closes" > "/dev/stderr"; bad = 1 }
    exit bad
}
' "$buckfile" > "$scratch/buck.raw" || exit 1
canon "$scratch/buck.raw" > "$scratch/buck.canon"

# ---- compare -----------------------------------------------------------
status=0
if ! diff -u "$scratch/zig.canon" "$scratch/buck.canon" > "$scratch/diff"; then
    echo "build_parity: build.zig and BUCK disagree (- only in build.zig, + only in BUCK):" >&2
    grep '^[-+][^-+]' "$scratch/diff" >&2
    status=1
fi

# Every root file named exists.
roots=$(awk '$1 == "exe" || $1 == "module" { print $3 } $1 == "test" || $1 == "import" { print $2 }' "$scratch/zig.canon" | sort -u)
for root in $roots; do
    if [ ! -f "$srcroot/$root" ]; then
        echo "build_parity: $root is named by build.zig and is not a file" >&2
        status=1
    fi
done

if [ "$status" -eq 0 ]; then
    echo "build_parity: build.zig and BUCK agree: $(grep -c '^test ' "$scratch/zig.canon") test binaries, $(grep -c '^exe ' "$scratch/zig.canon") executables, $(grep -c '^module ' "$scratch/zig.canon") modules"
fi
exit "$status"
