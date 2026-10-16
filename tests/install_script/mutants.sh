#!/bin/sh
# Plants defects in a copy of install.sh and requires tests/install_script/run.sh to go red for each.
# A mutant that leaves the script unchanged, or that run.sh passes, fails this job.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
src=$root/site/static/install.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/mopm-mutants.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

"$here/run.sh" "$src" > "$work/clean.log" 2>&1 || { cat "$work/clean.log" >&2; echo "the unmutated script does not pass" >&2; exit 1; }

bad=0
# mutant <name> <sed expression>
mutant() {
    sed "$2" "$src" > "$work/m.sh"
    if cmp -s "$src" "$work/m.sh"; then
        echo "MUTANT $1: the sed expression changed nothing" >&2
        bad=$((bad + 1))
        return
    fi
    if "$here/run.sh" "$work/m.sh" > "$work/m.log" 2>&1; then
        echo "MUTANT $1 SURVIVED: run.sh stayed green" >&2
        bad=$((bad + 1))
    else
        echo "mutant $1 killed ($(grep -c '^FAIL' "$work/m.log") failing checks)"
    fi
}

mutant skip-sha-compare 's/^\[ "\$got" = "\$want" \] .*$/true/'
mutant any-platform-accepted 's/^    \*) die "no mopm release for.*$/    *) target=linux-x86_64 ;;/'
mutant skip-binary-version-check 's/^if \[ "\$("\$home\/bin\/.mopm.new.\$\$" --version.*$/if false; then/'
mutant macos-arm-maps-to-intel 's/Darwin-arm64) target=macos-arm64/Darwin-arm64) target=macos-x86_64/'
mutant aarch64-maps-to-x86 's/Linux-aarch64|Linux-arm64) target=linux-aarch64/Linux-aarch64|Linux-arm64) target=linux-x86_64/'
mutant latest-not-resolved 's/^    tag=\${url##\*\/}$/    tag=v1.0.0/'

[ "$bad" -eq 0 ] || { echo "$bad mutant(s) not killed" >&2; exit 1; }
echo "all mutants killed"
