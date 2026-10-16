#!/bin/sh
# Superseded by //:autolink (tests/drivers/test_autolink_test.zig) on the build farm, which has no shell, Python or pixi;
# kept for ci.yml until farm.yml has matched it. Change both together.
# End-to-end test of `mopm build`, `mopm run` and `mopm repl` against the real
# Mojo toolchain. Run from the repository root:
#
#   tests/e2e/run.sh <mopm binary> <Mojo environment prefix> <work dir>
#
# The Mojo environment is the one `mopm sync` installs from tests/e2e/mopm.toml
# and mopm.lock (the pinned `mojo`; no pixi). This script:
#
#   1. builds three C shared libraries with the host C compiler: libgreet;
#      libinner; and libouter, linked against libinner with no run path of
#      its own, so libinner loads only if something names it;
#   2. precompiles the Mojo packages greet, inner and outer (tests/e2e/pkgs),
#      each calling its library through external_call, with that mojo;
#   3. installs them into two environments laid out as spec/channel.md says
#      (lib/mojo/<name>.mojoc, lib/mojo/<name>.mopm.json, natives in lib/),
#      with outer's metadata declaring that libouter needs libinner:
#        * "pixi": the Mojo environment itself, which is what a user has;
#        * "split": a separate prefix whose bin/mojo hands over to the real
#          mojo and whose modular.cfg imports from the split lib/mojo. Here
#          the libraries are NOT in the directory mojo's own run path covers,
#          so libinner loads only because mopm names it: this is the layout
#          in which a missing transitive entry is visible;
#   4. in each environment checks that the built binary (run with an empty
#      environment), `mopm run`, and `mopm repl` fed tests/e2e/repl.stdin
#      all print "greet 4242", "base 1000" and "chain 1234", which only the
#      native code can produce;
#   5. the transitive case, in each environment: tests/e2e/prog_outer.mojo
#      (and tests/e2e/repl_outer.stdin) import ONLY outer. inner is there
#      only as outer's dependency (outer's deps, and libouter's needs), and
#      the program never names inner. The built binary, `mopm run` and
#      `mopm repl` must still print "chain 1234", which libouter computes
#      by calling libinner;
#   6. in the split environment checks controls: stock `mojo run` and
#      `mojo repl` given greet and outer but not inner must NOT print the
#      values (and `mojo run` must fail naming libinner), for prog.mojo and
#      for the outer-only program, so the transitive entry is proven
#      load-bearing in that layout.
set -u

if [ $# -ne 3 ]; then
    echo "usage: tests/e2e/run.sh <mopm> <mojo env prefix> <work dir>" >&2
    exit 2
fi
mopm=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
mojo_env=$(cd "$2" && pwd -P)
mkdir -p "$3"
work=$(cd "$3" && pwd -P)
here=$(pwd -P)/tests/e2e
fail=0

case "$(uname -s)" in
    Darwin) os=macos ext=dylib ;;
    *) os=linux ext=so ;;
esac

die() {
    echo "FAIL $*"
    exit 1
}

# macOS 14 (Darwin 23): the debugserver in the mojo 1.0.0 package crashes
# (SIGSEGV in dyld4::FileRecord::getPath) when the REPL starts, and the REPL
# then prints "couldn't find a REPL for mojo". Point lldb at Xcode's
# debugserver there; macOS 15 runs the packaged one. This is the toolchain on
# this OS, not mopm: mopm passes the variable through like any other.
if [ "$os" = macos ] && [ "$(uname -r | cut -d. -f1)" -le 23 ]; then
    LLDB_DEBUGSERVER_PATH=$(xcode-select -p)/../SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver
    [ -x "$LLDB_DEBUGSERVER_PATH" ] || die "macOS 14: no Xcode debugserver at $LLDB_DEBUGSERVER_PATH"
    export LLDB_DEBUGSERVER_PATH
    echo "note: macOS 14, LLDB_DEBUGSERVER_PATH=$LLDB_DEBUGSERVER_PATH"
fi

mojo_real() {
    MODULAR_HOME="$mojo_env/share/max" "$mojo_env/bin/mojo" "$@"
}

echo "== mojo: $(mojo_real --version 2>&1)"

# ---------------------------------------------------------------- natives
natives=$work/natives
mkdir -p "$natives"
# shlib <name> [link args]: lib<name>.<ext> from native/<name>.c, with its
# soname (macOS install name @rpath/lib<name>.dylib) and no run path.
shlib() {
    name=$1
    shift
    out=$natives/lib$name.$ext
    if [ "$os" = macos ]; then
        cc -dynamiclib -install_name "@rpath/lib$name.$ext" -o "$out" "$here/native/$name.c" "$@" ||
            die "cc lib$name"
    else
        cc -shared -fPIC -Wl,-soname,"lib$name.$ext" -o "$out" "$here/native/$name.c" "$@" ||
            die "cc lib$name"
    fi
}
shlib greet
shlib inner
shlib outer -L"$natives" -linner

# The fixture must have the shape the test depends on: libouter needs
# libinner by name and carries no run path that would find it.
if [ "$os" = macos ]; then
    otool -L "$natives/libouter.dylib" | grep -q "@rpath/libinner.dylib" ||
        die "fixture: libouter.dylib does not load @rpath/libinner.dylib"
    if otool -l "$natives/libouter.dylib" | grep -q LC_RPATH; then
        die "fixture: libouter.dylib has an LC_RPATH"
    fi
else
    readelf -d "$natives/libouter.so" | grep -q "NEEDED.*\[libinner.so\]" ||
        die "fixture: libouter.so does not need libinner.so"
    if readelf -d "$natives/libouter.so" | grep -q "RPATH\|RUNPATH"; then
        die "fixture: libouter.so has a run path"
    fi
fi
echo "ok   fixture: libouter needs libinner and has no run path"

# ---------------------------------------------------------------- packages
pkgs=$work/pkgs
mkdir -p "$pkgs"
for p in greet inner outer; do
    mojo_real precompile "$here/pkgs/$p" -o "$pkgs/$p.mojoc" || die "mojo precompile $p"
done

# meta <name> <deps json> <needs json>: lib/mojo/<name>.mopm.json content.
meta() {
    printf '{"schema": 1, "name": "%s", "version": "1.0.0", "deps": %s,\n' "$1" "$2"
    printf ' "native": [{"id": "%s", "soname": "lib%s.%s", "file": "../lib%s.%s", "needs": %s}]}\n' \
        "$1" "$1" "$ext" "$1" "$ext" "$3"
}

# install <prefix>: the three packages, as spec/channel.md lays them out.
install() {
    mkdir -p "$1/lib/mojo"
    for p in greet inner outer; do
        cp "$natives/lib$p.$ext" "$1/lib/"
        cp "$pkgs/$p.mojoc" "$1/lib/mojo/"
    done
    meta greet '[]' '[]' > "$1/lib/mojo/greet.mopm.json"
    meta inner '[]' '[]' > "$1/lib/mojo/inner.mopm.json"
    meta outer '[{"name": "inner"}]' "[\"libinner.$ext\"]" > "$1/lib/mojo/outer.mopm.json"
}

# ---------------------------------------------------------------- checks
# The program under test, and the lines only its native code can produce.
# (want_for <program>: those lines, one per line.)
want_for() {
    case $1 in
        prog) printf '%s\n' "greet 4242" "base 1000" "chain 1234" ;;
        prog_outer) printf '%s\n' "chain 1234" ;;
    esac
}

# The outer-only program must not reach inner by itself: if it named inner,
# libinner would be planned for its own sake and the transitive case would
# prove nothing.
if grep -q "inner" "$here/repl_outer.stdin" || grep -v "^#" "$here/prog_outer.mojo" | grep -q "inner"; then
    die "fixture: the outer-only program names inner"
fi

# expect <label> <exit code> <output file> [program]: exit 0 and every line
# want_for the program (default prog) gives.
expect() {
    ok=1
    [ "$2" -eq 0 ] || { echo "     exit $2, want 0"; ok=0; }
    wants=$(want_for "${4:-prog}")
    while IFS= read -r want; do
        grep -q "$want" "$3" || { echo "     no '$want' in the output"; ok=0; }
    done <<EOF_WANTS
$wants
EOF_WANTS
    if [ "$ok" -eq 1 ]; then
        echo "ok   $1; output:"
    else
        echo "FAIL $1; output:"
        fail=1
    fi
    show "$3"
}

# show <file>: the output, without the toolchain's crash-reporter notice.
show() {
    grep -v "Failed to initialize Crashpad" "$1" | sed 's/^/     | /'
}

# refuse <label> <exit code> <output file> <must fail: 1|0>: none of the
# lines, and (when asked) a non-zero exit status.
refuse() {
    ok=1
    if [ "$4" -eq 1 ] && [ "$2" -eq 0 ]; then
        echo "     exit 0, want non-zero"
        ok=0
    fi
    for want in "greet 4242" "base 1000" "chain 1234"; do
        if grep -q "$want" "$3"; then
            echo "     '$want' in the output"
            ok=0
        fi
    done
    if [ "$ok" -eq 1 ]; then
        echo "ok   $1; output:"
    else
        echo "FAIL $1; output:"
        fail=1
    fi
    show "$3"
}

# layout <name> <prefix> <program> <repl stdin>: build, run and repl through
# mopm. <program> is prog or prog_outer (tests/e2e/<program>.mojo).
layout() {
    name=$1
    prefix=$2
    prog=$3
    stdin=$here/$4
    out=$work/$name/$prog
    mkdir -p "$out"
    for t in build run repl; do
        case $t in
            build) set -- build "$here/$prog.mojo" -o "$out/prog" ;;
            run) set -- run "$here/$prog.mojo" ;;
            repl) set -- repl ;;
        esac
        echo "     $name, $prog: $("$mopm" "$@" --prefix "$prefix" --print-cmd 2>&1)"
    done

    "$mopm" build "$here/$prog.mojo" -o "$out/prog" --prefix "$prefix" > "$out/build.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $name, $prog: mopm build exit $rc; output:"
        show "$out/build.log"
        fail=1
    else
        env -i "$out/prog" > "$out/binary.log" 2>&1
        expect "$name, $prog: mopm build, then the binary in an empty environment" $? "$out/binary.log" "$prog"
    fi

    "$mopm" run "$here/$prog.mojo" --prefix "$prefix" > "$out/run.log" 2>&1
    expect "$name, $prog: mopm run" $? "$out/run.log" "$prog"

    # The REPL check asserts the values, never the absence of loader noise.
    # On macOS the output carries "dyld[...]: terminating because inserted
    # dylib '<lib>' could not be loaded ... incompatible architecture (have
    # 'arm64', need 'arm64e')". That line is not from the JIT process:
    # DYLD_INSERT_LIBRARIES also reaches an arm64e system helper the
    # debugger starts; that helper cannot take an arm64 library, and the
    # REPL does not depend on it. The JIT process (arm64, like the
    # libraries) loads them, which is why the values print.
    "$mopm" repl --prefix "$prefix" < "$stdin" > "$out/repl.log" 2>&1
    expect "$name, $prog: mopm repl, stdin with a blank line between expressions" $? "$out/repl.log" "$prog"
}

# The split environment: a prefix of its own, borrowing the toolchain.
split=$work/split
mkdir -p "$split/bin" "$split/lib/mojo" "$split/share/max"
{
    echo '#!/bin/sh'
    echo "exec \"$mojo_env/bin/mojo\" \"\$@\""
} > "$split/bin/mojo"
chmod 755 "$split/bin/mojo"
sed "s|^import_path = .*|import_path = $split/lib/mojo|" "$mojo_env/share/max/modular.cfg" > "$split/share/max/modular.cfg"
grep -q "^import_path = $split/lib/mojo\$" "$split/share/max/modular.cfg" ||
    die "split: modular.cfg has no import_path line to point at $split/lib/mojo"
for f in "$mojo_env"/lib/mojo/*.mojoc; do
    ln -s "$f" "$split/lib/mojo/"
done
install "$split"
[ ! -e "$mojo_env/lib/libinner.$ext" ] || die "split: libinner is already in the toolchain's lib"

# Controls (split only): libinner named nowhere, so libouter cannot load.
lib=$split/lib
MODULAR_HOME="$split/share/max" "$split/bin/mojo" run \
    -Xlinker "$lib/libgreet.$ext" -Xlinker "$lib/libouter.$ext" "$here/prog.mojo" > "$work/control-run.log" 2>&1
refuse "control, split: mojo run without libinner fails" $? "$work/control-run.log" 1
grep -q "libinner" "$work/control-run.log" || {
    echo "FAIL control, split: the mojo run failure does not name libinner"
    fail=1
}
if [ "$os" = macos ]; then var=DYLD_INSERT_LIBRARIES; else var=LD_PRELOAD; fi
MODULAR_HOME="$split/share/max" "$split/bin/mojo" repl \
    -O "settings set target.env-vars $var=$lib/libgreet.$ext:$lib/libouter.$ext" < "$here/repl.stdin" > "$work/control-repl.log" 2>&1
echo "     control repl exit status: $?"
refuse "control, split: mojo repl without libinner preloaded prints nothing" 1 "$work/control-repl.log" 0
MODULAR_HOME="$split/share/max" "$split/bin/mojo" run \
    -Xlinker "$lib/libouter.$ext" "$here/prog_outer.mojo" > "$work/control-run-outer.log" 2>&1
refuse "control, split: mojo run of the outer-only program without libinner fails" $? "$work/control-run-outer.log" 1
grep -q "libinner" "$work/control-run-outer.log" || {
    echo "FAIL control, split: the outer-only mojo run failure does not name libinner"
    fail=1
}

layout split "$split" prog repl.stdin
layout split "$split" prog_outer repl_outer.stdin

install "$mojo_env"
layout pixi "$mojo_env" prog repl.stdin
layout pixi "$mojo_env" prog_outer repl_outer.stdin

exit "$fail"
