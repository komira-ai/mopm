# Examples

This page walks through six complete examples, from a library with a test to a package that pins its compiler, and every file in them is quoted from the `examples/` directory of the repository. It is part four of the documentation: [configuration](configuration.md) is the reference for every key used here, and [getting started](getting-started.md) installs mopm.

## How to read this page

Each example is a directory under `examples/`, and the file names in bold are paths from the repository root. Nothing here is a sketch: the CI of the repository runs the built `mopm` over a copy of `examples/` (`tests/drivers/examples_test.zig`) and compares what it prints, writes and refuses with the files quoted on this page, and the site's own tests (`site/test/docs-examples.test.ts`) fail if a block on this page differs from its file, or if a file under `examples/` is missing from the page. So a command shown with its output printed that output when the CI ran it, and a command shown with an error refused with those words.

Two limits are worth knowing. The test that holds these examples to mopm has no Mojo compiler, so it never compiles the `.mojo` files: mopm reads them with its own scanner (`mopm test --list`), the part of mopm that does not need Mojo. And `mopm lock` is run offline, against a registry address where nothing listens, which works because a project with no registry dependency never contacts one. A registry dependency needs a registry, so the examples use path dependencies, and the second one shows what changes when a package comes from the registry.

To try an example, copy its directory out of `examples/` and run the commands in it. The commands that build or run Mojo (`mopm build`, `mopm run`, `mopm test` without `--list`) also need a Mojo environment, which [getting started](getting-started.md) sets up.

## 1. A library

The smallest useful package: a manifest, a library directory with the package's name, and a test. `mopm new greeter --lib` makes the same layout.

**`examples/greeter/mopm.toml`**

```toml
[package]
name = "greeter"
version = "0.1.0"
description = "Greetings, as a library"
license = "Apache-2.0"
repository = "https://github.com/example/greeter"

[toolchain]
mojo = "1.0.0"

[targets]
lib = { path = "src/greeter" }
tests = ["tests"]
```

`[package]` names the package and gives it a version. `description`, `license` and `repository` are display fields: mopm checks that they are strings and prints them, nothing more (the table of what reads each key is in [configuration](configuration.md)). `[toolchain]` pins the compiler the package is built with. `[targets] lib` says where the library is, and `tests` names the directory of tests; mopm finds tests by their path, so `tests` here is a note for the reader.

**`examples/greeter/src/greeter/__init__.mojo`**

```mojo
"""greeter: greetings, as a library."""


def greet(who: String) -> String:
    """Returns a greeting for `who`."""
    return "Hello, " + who + "!"


def greet_twice(who: String) -> String:
    """Returns the greeting for `who`, twice."""
    return greet(who) + " " + greet(who)
```

**`examples/greeter/tests/test_greeter.mojo`**

```mojo
from std.testing import TestSuite, assert_equal

from greeter import greet, greet_twice


def test_greet() raises:
    assert_equal(greet("Mojo"), "Hello, Mojo!")


def test_greet_twice() raises:
    assert_equal(greet_twice("Mojo"), "Hello, Mojo! Hello, Mojo!")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

The test file registers its tests with `TestSuite.discover_tests`, as the file `mopm new` writes does. `mopm metadata` checks the manifest and prints how mopm read it, and `mopm test --list` prints the tests it found, one per line as `<file>::<test>`, without running anything:

```sh
cd examples/greeter
mopm metadata
mopm test --list
```

**`examples/greeter/expected/metadata.json`**

```json
{
  "package": {
    "name": "greeter",
    "version": "0.1.0",
    "description": "Greetings, as a library",
    "license": "Apache-2.0",
    "repository": "https://github.com/example/greeter",
    "readme": null
  },
  "toolchain": {
    "mojo": ["1.0.0"]
  },
  "dependencies": [],
  "dev-dependencies": [],
  "native-dependencies": [],
  "native": [],
  "targets": {
    "lib": {"path": "src/greeter"},
    "bins": [],
    "tests": ["tests"]
  }
}
```

**`examples/greeter/expected/tests.txt`**

```text
tests/test_greeter.mojo::test_greet
tests/test_greeter.mojo::test_greet_twice
```

`mopm test` without `--list` builds each test file and runs every test in its own process, in a Mojo environment: `mopm test --prefix <your env>`.

A manifest is checked strictly, so a typo is an error that names the line. Each of these changes to the manifest above is refused by `mopm metadata`, with exit status 1:

| change | message |
|---|---|
| `[target]` for `[targets]` | `unknown key 'target' in mopm.toml` |
| `homepage = "..."` in `[package]` | `unknown key 'homepage' in [package]` (`keywords` is refused the same way) |
| `name = "Greeter"` | `package name 'Greeter' must start with a lowercase letter` |
| `version = "0.1"` | `must be exactly MAJOR.MINOR.PATCH`, with the form it wants (no pre-release or build part, such as `0.1.0`) |

## 2. A program with a dependency

A program is a package with a `[targets] bins` entry. This one depends on the library above by path, which is how a package is used before it is published, and how two packages in one checkout work together.

**`examples/app/mopm.toml`**

```toml
[package]
name = "app"
version = "0.1.0"

[toolchain]
mojo = "1.0.0"

[dependencies]
greeter = { path = "../greeter" }
# A package from the registry is a version requirement instead:
# http_client = "0.4"

[targets]
bins = [{ name = "hello", path = "src/main.mojo" }]
```

**`examples/app/src/main.mojo`**

```mojo
from greeter import greet


def main():
    print(greet("world"))
```

`mopm lock` resolves the dependencies and writes `mopm.lock`; commit that file. A project whose dependencies are all paths needs no registry, so the command works offline, and the lock holds the path packages and the default channel:

```sh
cd examples/app
mopm lock
mopm tree
```

**`examples/app/expected/lock.txt`**

```text
adding greeter 0.1.0
locked 1 packages for mojo 1.0.0
```

**`examples/app/mopm.lock`**

```json
{
  "lock_version": 1,
  "toolchain": {
    "mojo": "1.0.0"
  },
  "channels": [
    "https://conda.mopm.dev/"
  ],
  "packages": [
    {
      "name": "greeter",
      "version": "0.1.0",
      "source": "path",
      "path": "../greeter"
    }
  ]
}
```

**`examples/app/expected/tree.txt`**

```text
app 0.1.0
└── greeter 0.1.0 (../greeter)
```

Running `mopm lock` again changes nothing and prints `locked 1 packages for mojo 1.0.0`. Removing the comment from the `http_client` line makes the project depend on the registry, and `mopm lock` then needs one: with the registry unreachable it stops with `cannot reach` and the address, and writes no lock. `mopm add http_client` writes that line for you, as `^X.Y.Z` for the newest version that fits, and locks.

After `mopm sync` installs the lock into `.mopm/`, `mopm build src/main.mojo -o hello --prefix .mopm/.pixi/envs/default` builds the program with the native libraries of every installed package linked.

## 3. Several packages in one repository

mopm has no `[workspace]` table. The packages of one repository are path dependencies of one another, and a build system takes the ones below the root as its members. Here a program depends on two libraries, one of which depends on the other, and has a fourth package for its tests.

**`examples/workspace/mopm.toml`**

```toml
[package]
name = "app"
version = "0.2.0"

[toolchain]
mojo = "1.0.0"

[dependencies]
core = { path = "core" }
util = { path = "util" }

[dev-dependencies]
testkit = { path = "testkit" }

[targets]
bins = [{ name = "run", path = "src/main.mojo" }]
```

**`examples/workspace/core/mopm.toml`**

```toml
[package]
name = "core"
version = "0.1.0"

[toolchain]
mojo = "1.0.0"

[dependencies]
util = { path = "../util" }
```

**`examples/workspace/util/mopm.toml`**

```toml
[package]
name = "util"
version = "0.1.0"

[toolchain]
mojo = "1.0.0"
```

**`examples/workspace/testkit/mopm.toml`**

```toml
[package]
name = "testkit"
version = "0.1.0"

[toolchain]
mojo = "1.0.0"
```

**`examples/workspace/src/main.mojo`**

```mojo
from core import total
from util import clamp


def main():
    print(clamp(total(40, 5), 0, 42))
```

**`examples/workspace/core/src/core/__init__.mojo`**

```mojo
from util import clamp


def total(a: Int, b: Int) -> Int:
    """The sum of `a` and `b`, held between 0 and a million."""
    return clamp(a + b, 0, 1000000)
```

**`examples/workspace/util/src/util/__init__.mojo`**

```mojo
def clamp(x: Int, low: Int, high: Int) -> Int:
    """`x`, held between `low` and `high`."""
    if x < low:
        return low
    if x > high:
        return high
    return x
```

**`examples/workspace/testkit/src/testkit/__init__.mojo`**

```mojo
def approx(a: Int, b: Int, within: Int) -> Bool:
    """Whether `a` and `b` differ by at most `within`."""
    return a - b <= within and b - a <= within
```

A path is relative to the manifest that names it, so `core` names `../util` and the root names `util`: both are the same directory, and the lock records it once, relative to the root. A name may be given only one directory. `mopm lock` follows path dependencies to any depth, and `mopm tree` lists dependencies and dev-dependencies separately:

```sh
cd examples/workspace
mopm lock
mopm tree
mopm plan --unit-graph --locked
```

**`examples/workspace/expected/lock.txt`**

```text
adding core 0.1.0
adding testkit 0.1.0
adding util 0.1.0
locked 3 packages for mojo 1.0.0
```

**`examples/workspace/mopm.lock`**

```json
{
  "lock_version": 1,
  "toolchain": {
    "mojo": "1.0.0"
  },
  "channels": [
    "https://conda.mopm.dev/"
  ],
  "packages": [
    {
      "name": "core",
      "version": "0.1.0",
      "source": "path",
      "path": "core",
      "deps": [
        "util"
      ]
    },
    {
      "name": "testkit",
      "version": "0.1.0",
      "source": "path",
      "path": "testkit"
    },
    {
      "name": "util",
      "version": "0.1.0",
      "source": "path",
      "path": "util"
    }
  ]
}
```

**`examples/workspace/expected/tree.txt`**

```text
app 0.2.0
├── core 0.1.0 (core)
│   └── util 0.1.0 (util)
└── util 0.1.0 (util)
[dev-dependencies]
└── testkit 0.1.0 (testkit)
```

`mopm plan --unit-graph --locked` prints the build as JSON for a build system (see `spec/unit-graph.md`): a unit for each of `util@0.1.0#mojo1.0.0/lib`, `core@0.1.0#mojo1.0.0/lib` and `testkit@0.1.0#mojo1.0.0/lib`, and for the program, `app@0.2.0#mojo1.0.0/bin:run`. It takes only members that are below the root project, which is why the members are directories of the root here and not its siblings (`mopm lock` and `mopm tree` take siblings too). Two mistakes are refused, each with exit status 1:

| mistake | message |
|---|---|
| a `[workspace]` table | `unknown key 'workspace' in mopm.toml` |
| `util = { path = "testkit" }` while `core` names `../util` | `one name, one path`: a name is one directory |

## 4. Tests

`mopm test` finds `tests/**/test_*.mojo` and `src/**/tests/test_*.mojo` (hidden directories are skipped), and runs each test in its own process. This package has one of each kind of test file.

**`examples/testing/mopm.toml`**

```toml
[package]
name = "mathkit"
version = "0.1.0"

[toolchain]
mojo = "1.0.0"

[targets]
lib = { path = "src/mathkit" }
```

**`examples/testing/src/mathkit/__init__.mojo`**

```mojo
def double(x: Int) -> Int:
    return x * 2


def square(x: Int) -> Int:
    return x * x


def clamp(x: Int, low: Int, high: Int) -> Int:
    if x < low:
        return low
    if x > high:
        return high
    return x
```

A bare file has no `main`: its tests are its top-level `def test_*() raises` functions, and mopm builds it through a generated harness.

**`examples/testing/tests/test_double.mojo`**

```mojo
from std.testing import assert_equal

from mathkit import double


def test_double_two() raises:
    assert_equal(double(2), 4)


def test_double_zero() raises:
    assert_equal(double(0), 0)
```

A self-hosted file has its own `main`. This one registers every `test_*` function with `discover_tests`, and holds a test marked `# mopm: ignore "<reason>" <issue>`. An ignored test is still listed and built, and runs only with `--ignored` or `--include-ignored`. The reason in quotes and the issue (`#12`, `owner/repo#12` or an https URL) are both required, so that an ignored test can be traced.

**`examples/testing/tests/test_suite.mojo`**

```mojo
from std.testing import TestSuite, assert_equal

from mathkit import clamp


def test_clamp_low() raises:
    assert_equal(clamp(-5, 0, 10), 0)


def test_clamp_high() raises:
    assert_equal(clamp(50, 0, 10), 10)


# mopm: ignore "needs the network" #12
def test_clamp_remote() raises:
    assert_equal(clamp(1, 0, 10), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

A test can sit beside the code it tests, in a `tests` directory under `src`:

**`examples/testing/src/mathkit/tests/test_inner.mojo`**

```mojo
from std.testing import assert_equal

from mathkit import square


def test_inner_square() raises:
    assert_equal(square(7), 49)
```

A file whose name does not start with `test_` is not a test file, so it is the place for helpers:

**`examples/testing/tests/helpers.mojo`**

```mojo
def repeat_text(s: String, n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += s
    return out
```

`mopm test --list` shows what would run, in path order and then source order, with the ignored test left out. A pattern after `--` selects the tests whose `<file>::<test>` contains it (a pattern with `*`, `?` or `[` is a glob), and `--ignored` selects only the ignored ones:

```sh
cd examples/testing
mopm test --list
mopm test --list -- double
mopm test --list --ignored
```

**`examples/testing/expected/list.txt`**

```text
src/mathkit/tests/test_inner.mojo::test_inner_square
tests/test_double.mojo::test_double_two
tests/test_double.mojo::test_double_zero
tests/test_suite.mojo::test_clamp_low
tests/test_suite.mojo::test_clamp_high
```

**`examples/testing/expected/list-select.txt`**

```text
tests/test_double.mojo::test_double_two
tests/test_double.mojo::test_double_zero
```

**`examples/testing/expected/list-ignored.txt`**

```text
tests/test_suite.mojo::test_clamp_remote
```

An ignore directive without an issue is refused, with exit status 2: the message says it needs a reason in double quotes and an issue reference. The verdicts, timeouts, retries and reports of `mopm test` are in [the test reference](mopm-test.md).

## 5. Publishing

A package is published as a `.conda` file per platform, made from a `.mojoc` that you build with the Mojo compiler you name: mopm does not run `mojo precompile` for you today. This package has the fields a registry shows (`readme` is the file whose text it serves) and one dependency, written as a requirement on the registry.

**`examples/publish/mopm.toml`**

```toml
[package]
name = "slug"
version = "1.2.0"
description = "Turn a title into a URL slug"
license = "Apache-2.0"
repository = "https://github.com/example/slug"
readme = "README.md"
mojo = ["1.0.0"]

[dependencies]
text_tools = "0.3"

[targets]
lib = { path = "src/slug" }
```

**`examples/publish/README.md`**

```markdown
# slug

Turn a title into a URL slug.
```

**`examples/publish/src/slug/__init__.mojo`**

```mojo
"""slug: turn a title into a URL slug."""

from text_tools import lower_ascii


def slugify(title: String) -> String:
    return lower_ascii(title).replace(" ", "-")
```

`text_tools` is a placeholder for any registry package. `mopm pack` and `mopm publish --dry-run` never contact a registry, so they work on this package as it is. The `.mojoc` in the commands is a stand-in file, named `slug.mojoc`; build the real one with `mojo precompile` and the compiler you pass to `--compiler`.

```sh
cd examples/publish
mopm pack --compiler 1.0.0 --mojoc linux-64=slug.mojoc -o dist
mopm publish --compiler 1.0.0 --mojoc linux-64=slug.mojoc --dry-run
```

`pack` writes `dist/linux-64/mojo-slug-1.2.0-mojo1.0.0_0.conda` and prints its digests. In the output, `<sha256>` stands for 64 hexadecimal digits and `<n>` for a number of bytes, which depend on the packed bytes:

**`examples/publish/expected/pack.txt`**

```text
packed dist/linux-64/mojo-slug-1.2.0-mojo1.0.0_0.conda
  sha256 <sha256>
  size <n>
  manifest_sha256 <sha256>
```

`publish --dry-run` packs the same way and says what it would send, without a registry or a login:

**`examples/publish/expected/publish-dry-run.txt`**

```text
would upload linux-64/mojo-slug-1.2.0-mojo1.0.0_0.conda (<n> bytes, sha256 <sha256>)
would commit mojo-slug 1.2.0 (manifest_sha256 <sha256>)
would send a readme of 38 bytes
dry run: nothing was sent
```

Without `--dry-run`, `mopm publish` logs in with `$MOPM_TOKEN` or the login that `mopm login` stored, uploads each file, commits, and waits for the registry to say `published` or `rejected`. A published version is immutable and its number can never be reused. `pack` and `publish` refuse, before any request, a package that cannot be published as it is, each with exit status 1:

| change | message |
|---|---|
| `version = "1.2.0-rc.1"` | `must be exactly MAJOR.MINOR.PATCH` |
| `text_tools = { path = "../text_tools" }` | `dependency 'text_tools' is a path dependency` |
| `[native-dependencies]` with `zlib = "1.2"` (mode `link`) | `native dependency 'zlib' is mode = "link"; only mode = "load" is packed` |
| `--compiler v1` | `an exact Mojo version is digits and dots, such as 1.0.0` |

## 6. Pinning the compiler

A `.mojoc` is tied to the compiler that built it, so a project says which compiler it uses. `[package] mojo` lists the exact versions the package builds for, and gives a lock that covers all of them.

**`examples/toolchain/mopm.toml`**

```toml
[package]
name = "pinned"
version = "0.1.0"
mojo = ["1.0.0"]

[targets]
lib = { path = "src/pinned" }
```

**`examples/toolchain/src/pinned/__init__.mojo`**

```mojo
def answer() -> Int:
    return 42
```

```sh
cd examples/toolchain
mopm lock
mopm plan --unit-graph --locked
```

**`examples/toolchain/expected/lock.txt`**

```text
locked 0 packages for mojo 1.0.0
```

The lock is `lock_version` 2. It records, for each Mojo version and platform, the hash of the toolchain that mopm pins for it (the pins are in mopm's own source), so that a build system gets the same compiler on every machine, and `mopm plan` refuses a lock whose hash this mopm does not compute. The hashes are written `<sha256>` here, because they change when the pin does:

**`examples/toolchain/expected/mopm.lock`**

```json
{
  "lock_version": 2,
  "mojo": [
    "1.0.0"
  ],
  "toolchain": {
    "1.0.0": {
      "linux-64": "<sha256>"
    }
  },
  "channels": [
    "https://conda.mopm.dev/"
  ],
  "packages": []
}
```

`mopm plan --unit-graph --locked` then prints the unit graph for the one listed version, with `"id": "pinned@0.1.0#mojo1.0.0/lib"` among its units. mopm pins a toolchain only for the Mojo versions in `src/core/toolchain/` (1.0.0 today), and says so for the others:

| change | message |
|---|---|
| `mojo = ["1.0.0", "1.1.0"]` | `mopm has no pinned toolchain for mojo 1.1.0` |
| a `[toolchain]` table beside `[package] mojo` | `mojo is set in [package] and in [toolchain]; keep [package] mojo` |

`[toolchain] mojo = "1.0.0"`, the form `mopm new` writes, is the older way: one version, or a list read as alternatives, and a `lock_version` 1 lock.
