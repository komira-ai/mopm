#!/bin/sh
# End-to-end test of `mopm build`, `mopm run` and `mopm repl` against the real
# Mojo toolchain. Run from the repository root:
#
#   tests/e2e/run.sh <mopm binary> <Mojo environment prefix> <work dir>
#
# The Mojo environment is a pixi environment holding the pinned `mojo`
# (tests/e2e/pixi.toml). This script:
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
#   5. in the split environment checks two controls: stock `mojo run` and
#      `mojo repl` given greet and outer but not inner must NOT print them
#      (and `mojo run` must fail naming libinner), so the transitive entry
#      is proven load-bearing in that layout.
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
# expect <label> <exit code> <output file>: exit 0 and the three lines.
expect() {
    ok=1
    [ "$2" -eq 0 ] || { echo "     exit $2, want 0"; ok=0; }
    for want in "greet 4242" "base 1000" "chain 1234"; do
        grep -q "$want" "$3" || { echo "     no '$want' in the output"; ok=0; }
    done
    if [ "$ok" -eq 1 ]; then
        echo "ok   $1"
    else
        echo "FAIL $1; output:"
        sed 's/^/     | /' "$3"
        fail=1
    fi
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
        echo "ok   $1"
    else
        echo "FAIL $1; output:"
        sed 's/^/     | /' "$3"
        fail=1
    fi
}

# layout <name> <prefix>: build, run and repl through mopm.
layout() {
    name=$1
    prefix=$2
    out=$work/$name
    mkdir -p "$out"
    for t in build run repl; do
        case $t in
            build) set -- build "$here/prog.mojo" -o "$out/prog" ;;
            run) set -- run "$here/prog.mojo" ;;
            repl) set -- repl ;;
        esac
        echo "     $name: $("$mopm" "$@" --prefix "$prefix" --print-cmd 2>&1)"
    done

    "$mopm" build "$here/prog.mojo" -o "$out/prog" --prefix "$prefix" > "$out/build.log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $name: mopm build exit $rc; output:"
        sed 's/^/     | /' "$out/build.log"
        fail=1
    else
        env -i "$out/prog" > "$out/binary.log" 2>&1
        expect "$name: mopm build, then the binary in an empty environment" $? "$out/binary.log"
    fi

    "$mopm" run "$here/prog.mojo" --prefix "$prefix" > "$out/run.log" 2>&1
    expect "$name: mopm run" $? "$out/run.log"

    "$mopm" repl --prefix "$prefix" < "$here/repl.stdin" > "$out/repl.log" 2>&1
    expect "$name: mopm repl, stdin with a blank line between expressions" $? "$out/repl.log"
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

layout split "$split"

install "$mojo_env"
layout pixi "$mojo_env"

exit "$fail"
