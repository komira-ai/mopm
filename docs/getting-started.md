# Getting started with mopm

This is part two of the mopm documentation: how to install it and use it. For the reasons and the design,
read [why-and-design.md](why-and-design.md). mopm is early (0.0.x). What works today is listed as it is
described; anything else is marked **planned**.

## 1. Install

### The install script

```sh
curl -fsSL https://mopm.dev/install.sh | sh
```

The script needs `curl`, `tar`, `awk` and `sha256sum` (or `shasum`). It picks the release for your
machine (Linux on x86_64 or arm64, or macOS on arm64; there is no Intel Mac release) from the GitHub releases, checks the tarball's sha256 against
the release's `SHA256SUMS`, and installs `~/.mopm/bin/mopm`. It needs no root and edits no shell startup
file: add the `PATH` line it prints to your own. If any check fails, it installs nothing.

| variable | effect |
|---|---|
| `MOPM_VERSION=1.2.3` | install this version instead of the latest |
| `MOPM_HOME=<dir>` | install under `<dir>` instead of `~/.mopm` |
| `MOPM_RELEASES_URL=<url>` | read releases from a mirror (also used by tests) |

Read the script before you run it: it is `site/static/install.sh` in the repository.

### By hand

Each release lists `mopm-<version>-<target>.tar.gz` for `linux-x86_64`, `linux-aarch64` and
`macos-arm64`, `mopm_<version>_amd64.deb` and `mopm_<version>_arm64.deb` (for Debian and Ubuntu: `sudo apt install ./mopm_<version>_amd64.deb`),
a `SHA256SUMS` file, and a `<file>.sigstore.json` signature bundle for each of those six files.

```sh
v=0.0.2 t=linux-x86_64
curl -fsSLO "https://github.com/komira-ai/mopm/releases/download/v$v/mopm-$v-$t.tar.gz"
curl -fsSLO "https://github.com/komira-ai/mopm/releases/download/v$v/SHA256SUMS"
grep " mopm-$v-$t.tar.gz\$" SHA256SUMS | sha256sum -c -     # macOS: shasum -a 256 -c -
tar -xzf "mopm-$v-$t.tar.gz"                              # mopm-$v-$t/mopm
```

### Verify a download (optional)

Every release file is signed and attested by the repository's release workflow:

```sh
gh attestation verify mopm-$v-$t.tar.gz -R komira-ai/mopm \
  --signer-workflow komira-ai/mopm/.github/workflows/release.yml
cosign verify-blob --bundle mopm-$v-$t.tar.gz.sigstore.json \
  --certificate-identity https://github.com/komira-ai/mopm/.github/workflows/release.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com mopm-$v-$t.tar.gz
```

macOS binaries are not signed or notarized by Apple yet. The install script checks the sha256 only;
the two commands above are the way to check the signature and the provenance.

### apt (available once the repository is set up)

Debian and Ubuntu can install mopm from an apt repository, which every release publishes to once its owner has made the settings
(RELEASING.md, "The apt repository"). Until then use the script, the tarball, or the `.deb` of a release. Once it exists:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL -o /etc/apt/keyrings/komira-archive-keyring.gpg https://packages.komira.ai/apt/komira-archive-keyring.gpg
sudo tee /etc/apt/sources.list.d/komira.sources > /dev/null <<'EOF'
Types: deb
URIs: https://packages.komira.ai/apt
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/komira-archive-keyring.gpg
EOF
sudo apt update && sudo apt install mopm
```

### Homebrew (planned)

A Homebrew tap is planned. It does not exist yet; use the script or the tarball.

### A Mojo environment

`mopm build`, `run`, `repl` and `test` run the `mojo` of an environment. You need nothing else installed:
`mopm sync` (section 3) installs the Mojo toolchain your `mopm.toml` names (Mojo 1.0.0, 1.1.0 or 1.2.0 today), with
everything it needs, into the project's `.mopm/env`, next to your dependencies. It does not use pixi or
conda: every file comes from a list pinned in mopm (`mojo`, `mojo-compiler` and their dependencies, each
with its sha256 and size), is checked against it, and is unpacked by mopm.

mopm finds the environment from `--prefix <dir>`, else `CONDA_PREFIX`, else `MODULAR_HOME` without its
trailing `/share/max`, else the `.mopm/env` that `mopm sync` made in the current directory. So an
environment you made yourself (with pixi or conda, holding `mojo` and `mojo-compiler`) still works: activate
it or pass `--prefix`.

## 2. Start a package: `new` and `init`

```sh
mopm new alice/my_pkg --lib  # a library in a new directory my_pkg (the default kind)
mopm new alice/my_app --bin  # a program
cd existing_dir && mopm init [--lib|--bin] [--name <namespace>/<name>]    # in the current directory
mopm new my_pkg               # the same as mopm new alice/my_pkg, when mopm login stored the namespace alice
```

A package name is a full name, `<namespace>/<name>`: the namespace is your GitHub login (here `alice`), or an
organization's, and the name is what Mojo code imports. A bare name (`mopm new my_pkg`, or `mopm init` with no
`--name`, which takes the directory's name) gets the namespace that `mopm login` stored for the registry, read from
`credentials.json` (`--registry` and `--config-dir` choose which, as for `login`); a full name never reads it and
works offline. A bare name asks the registry for its configuration (whose API URL keys the entry) only when some
login stored a namespace; with none it asks nothing and is refused: `mopm new json needs a namespace: run 'mopm login'
(your GitHub login is your namespace) or name it, as in 'mopm new <your login>/json'` (`mopm init --name` for the
init forms). A new library contains
`mopm.toml`, `src/<name>/__init__.mojo`, `tests/test_<...>.mojo`, a README and a
`.gitignore`. Its manifest:

```toml
[package]
name = "alice/my_pkg"
version = "0.1.0"

[toolchain]
mojo = "1.0.0"

[dependencies]

[targets]
lib = { path = "src/my_pkg" }
tests = ["tests"]
```

A `--bin` package adds `bins = [{ name = "my_app", path = "src/main.mojo" }]` to `[targets]`.

## 3. Dependencies: `add`, `remove`, `lock`, `update`, `tree`, `sync`

```sh
mopm add example/http_client          # newest version that fits, written as ^X.Y.Z; then lock
mopm add example/http_client@0.4      # with a requirement
mopm add example/test_util --dev      # into [dev-dependencies]
mopm add alice/helper --path ../helper
mopm add http_client                  # refused: a bare name has no namespace; mopm names the packages it knows by that name
mopm remove example/http_client
mopm lock                       # resolve mopm.toml against the registry's index, write mopm.lock
mopm update [pkg...]            # move the named packages (all, with none) to the newest that fit
mopm tree                       # draw the dependency graph in mopm.lock
mopm sync                       # install mopm.lock and the Mojo toolchain into .mopm/env (locks first if needed)
mopm sync --locked              # CI: install exactly the lock, fail if it would change
```

`add` and `remove` keep the rest of `mopm.toml` byte for byte (comments, order, spacing), and write
nothing if the result does not resolve. Reading the index needs no account. After `sync`, the environment is
`.mopm/env`, and `build`, `run`, `repl` and `test` run in the project directory use it without `--prefix`.

Commit `mopm.lock`. Every download is checked against its pinned sha256 and size (the lock's for your
dependencies, mopm's own list for the toolchain), and a file that differs is refused. `sync` builds the new
environment beside `.mopm/env` and swaps it in at the end, so if anything fails the old environment is
still there. A second `sync` with the same lock finds the environment current and downloads nothing.
Downloaded dependencies are kept in `.mopm/pkgs`; the toolchain's files, which are large and the same for
every project, in `~/.cache/mopm/pkgs` (`$XDG_CACHE_HOME/mopm/pkgs` when that is set; `--cache <dir>` to
choose). `--toolchain <file>` installs the toolchain from another list of the same files, for instance one
whose channel URLs point at a mirror.

`sync` also installs the lock's system libraries for your platform. Only one `sync` runs in a project at a
time: a second one says it is waiting for `.mopm/sync.lock` and goes on when the first is done. The toolchain's
files are kept as `<cache>/<sha256>/<file>`, and `--cache` may not point inside `.mopm/env`, which `sync`
replaces. If `.mopm/env` has lost a file or no longer matches what `sync` recorded, the next `sync` says so and
installs it again; so does moving the project to another directory. A lock made with several Mojo versions
records the toolchain closure it was made for, and `sync` refuses a different one: run `mopm lock` again.

Because a compiled Mojo package is tied to one compiler, a dependency is only chosen if it has a build for
your exact Mojo. If none does, `mopm lock` says which versions have builds and for which Mojo.

A dependency named without a namespace is refused. `mopm add json` asks the registry for the packages with that name
(`GET /packages?q=json&limit=100`, at most 5 whose name part is `json`) and says so:
`dependency 'json' has no namespace: write it as <namespace>/json; packages named json on prod: komira-ai/json, alice/json
(as in 'mopm add komira-ai/json')`, or `...; no package on prod is named json`. If the registry cannot be read, the
message is `dependency 'json' has no namespace: write it as <namespace>/<name>, as in 'mopm add <namespace>/<name>'`.
mopm never adds one of the suggestions itself. A `[package] name` without a namespace in `mopm.toml` is refused by
`lock`, `update`, `sync`, `tree`, `add` and `remove` with the namespace you are logged in with:
`package name 'json' has no namespace: write name = "alice/json" (alice is your namespace), or another namespace you publish in`.

Note: the hosted registry is new and its catalogue is small, so `mopm add` of a registry package may have
nothing to find yet (the package list is on mopm.dev). Path dependencies
work now, and `--registry` can point at a local test registry.

## 4. Build, run, REPL

```sh
mopm build hello.mojo -o hello
mopm run hello.mojo
mopm repl
mopm build hello.mojo --print-cmd     # show the mojo command instead of running it
```

These run `<env>/bin/mojo` with the linker flags (or the REPL preload list) for the native libraries of
every installed package computed for you. stdin, signals and the exit status are mojo's. A closure with a
missing library, two owners of one library, or a library file absent from `<env>/lib` is refused with a
message. `mopm link-plan <file.mopm.json>...` prints the plan from metadata files, and
`mopm metadata [mopm.toml]` checks a manifest and prints it as JSON.

### Build the package's targets

`mopm build` with no program builds what `[targets]` of `mopm.toml` declares (`mopm new --bin` writes both):

```toml
[targets]
lib = { path = "src/my_pkg" }
bins = [{ name = "my_pkg", path = "src/main.mojo" }]
```

```sh
mopm build
# mopm build: library my_pkg -> target/build/my_pkg.mojoc
# mopm build: binary my_pkg -> target/build/my_pkg
mopm build --out-dir dist ...         # somewhere else than target/build
mopm build --print-cmd ...            # print the two mojo commands, write nothing
```

The library is made with `mojo precompile` of the package directory into `target/build/<package name>.mojoc`, the
file `mopm pack --mojoc` and `mopm publish --mojoc` take (see "Publish"). Each program is made with `mojo build`,
linked the way `mopm build hello.mojo` links it, into `target/build/<name>`. It is the `mojo` of the environment
that does the work, the same one `mopm run` uses, on Linux x86_64, Linux arm64 and macOS arm64 alike. (The unit
graph of `mopm plan` is for a build farm and is not used here.) The programs import the package's own library by
name. If one step fails, the build stops with that program's exit status; the steps before it stay. A `.mojoc`
is built by the Mojo that compiles it, one per platform; `mopm build` makes the one for the machine it runs on.

### Path dependencies

A dependency written `name = { path = "../name" }` (in `[dependencies]` or `[dev-dependencies]`, and the path
dependencies of that one in turn) is built from its source, and `mopm build` makes it importable: it passes
`-I <dir>` to `mojo` for the directory that holds the dependency's library package, the parent of its
`[targets] lib` path (`../name/src` for `lib = { path = "src/name" }`). This is for `mopm build` with a program
(`mopm build hello.mojo`) and for `mopm build` with none, and they are the same paths `mopm lock` and `mopm sync`
read. A dependency with no `[targets] lib` has nothing to import. `mopm run` and `mopm repl` do not add them.

### The REPL on macOS 14

`mojo repl` runs the program under lldb, and on macOS 14 the debugserver that comes with the Mojo toolchain
crashes at start (the REPL then answers "couldn't find a REPL for mojo"). On macOS 14 and older `mopm repl` points
lldb at Xcode's debugserver by setting `LLDB_DEBUGSERVER_PATH` for `mojo`: the one in the Xcode named by
`DEVELOPER_DIR` or `xcode-select -p`, else the Command Line Tools'. Nothing is set on macOS 15 and newer, on Linux,
or when you set `LLDB_DEBUGSERVER_PATH` yourself. `mopm repl --debugserver <path>` names the file to use instead. If
macOS 14 has no Xcode or Command Line Tools to take it from, `mopm repl` says so on stderr and starts `mojo` as
it is; install Xcode (`xcode-select -s <Xcode.app>/Contents/Developer`) or pass `--debugserver`.

## 5. Test

```sh
mopm test                               # tests/**/test_*.mojo and src/**/tests/test_*.mojo
mopm test tests/test_parse.mojo
mopm test -- parse                      # tests whose id contains "parse"
mopm test -- 'test_parse_*'             # a glob
mopm test --list                        # what would run
mopm test --timeout 30 --memory 2048    # seconds, MiB
mopm test --retries 2 --deny-flaky      # retry, but a test that needed a retry fails the run
mopm test --format json                 # one JSON document on stdout
mopm test --junit report.xml            # JUnit XML
```

A test is a top-level `def test_*() raises` function. A test file may have no `main` (mopm builds it through
a generated harness), or, as the file `mopm new` writes, a `main` that registers its tests with
`TestSuite.discover_tests`. Each test runs in its own process; a crash, a hang or a memory blow-up is reported for that test only.
Verdicts are PASS, FAIL, CRASH, TIMEOUT, OOM, COMPILE-ERROR, FLAKY and SKIP. Exit status: 0 all passed, 1 a
test did not pass, 2 usage, discovery or build error or nothing to run, 5 a toolchain problem. To skip a
test, say why and where it is tracked:

```mojo
# mopm: ignore "needs network" #123
def test_download() raises:
    ...
```

The full reference is `docs/mopm-test.md`.

## 6. Publish

You need an account on the registry, a `.mojoc` built by the Mojo version you name, and a manifest with
the display fields you want.

```sh
mopm login                                   # device login through GitHub; stores credentials.json (0600) and your namespace
mopm whoami                                  # your handle, GitHub id and namespaces on the registry

mojo precompile -I <dep dirs> src/my_pkg -o my_pkg.mojoc    # build the .mojoc yourself (see below)

mopm pack    --compiler 1.0.0 --mojoc linux-64=my_pkg.mojoc          # writes dist/<subdir>/mojo-<namespace>.my_pkg-<v>-mojo1.0.0_0.conda
mopm publish --compiler 1.0.0 --mojoc linux-64=my_pkg.mojoc --dry-run # pack and show what would be sent
mopm publish --compiler 1.0.0 --mojoc linux-64=my_pkg.mojoc            # publish to prod
mopm publish ... --registry beta                                       # prod (default), gamma, beta, or a URL
```

`mopm login` then asks the registry who you are (`GET /me`) and stores your user namespace beside the token: it prints
`Logged in to prod as alice; your namespace is alice.` When your GitHub login cannot be a namespace (another account
holds it, it is reserved, or it is not a valid namespace) it says so and stores none. If the registry cannot be asked,
the token is stored all the same and mopm warns `mopm: could not read your namespace from prod; 'mopm whoami' shows it`.
`mopm whoami` is a generated command (one call of `GET /me`; `mopm whoami --help` lists its flags). It prints the
registry's answer as `key: value` lines: the handle, the GitHub id, then `namespaces:` with an entry for each (its
namespace, kind `user` or `org`, role `owner` or `member`, and its packages), and `unavailable_namespace` when your
GitHub login cannot be a namespace. `--json` prints the answer as JSON.

An organization's namespace is shared by its members. An admin of the GitHub organization registers it once, and
the registry then manages its members itself:

```sh
mopm org create komira-ai                    # an active GitHub admin of komira-ai; you become its first owner
mopm org add komira-ai alice                 # alice (her mopm username) may publish in komira-ai
mopm org add komira-ai bob --role owner      # bob may also manage the members
mopm org remove komira-ai alice              # alice is refused from the next request on
mopm org list komira-ai                      # the members and their roles
```

`mopm org create` needs a stored login. It prints `To register the GitHub organization komira-ai on prod, open
<verification_uri> and enter the code <user_code>`, and waits while you approve on GitHub; the approval asks GitHub for
the `read:org` scope for that one step, and the registry discards the token. The GitHub account that approves must be
the one you are logged in as, and an active admin of the organization whose current login is the namespace; otherwise
the registry answers `not_org_admin` or `github_account_mismatch`. An organization that restricts OAuth apps must
approve the mopm registry first. GitHub is asked only then: afterwards members are the registry's own list, a person
leaving the GitHub organization is not removed from it, and an owner runs `mopm org remove`. A member is named by their
mopm username, which is their lower-case GitHub login and exists after their first `mopm login`. `add` sets the role
(`--role owner|member`, `member` when not given), so `mopm org add <org> <user>` makes an owner a member. The last owner
cannot be removed or demoted. `add`, `remove` and `list` are generated commands, one call of the registry's API each
(`mopm org add --help`) and take `--registry`, `--config-dir` and `--json`; `create` takes `--registry` and
`--config-dir`.

`mopm publish` first makes the package: it sends `PUT /packages/<namespace>/<name>` with no body, after reading the
token and before any upload. A 201 prints `created <full name> on <registry>`; a 200 (the package exists) prints nothing;
any other answer is printed and the run ends with exit status 1. `--dry-run` sends nothing.

`--mojoc` takes `[<subdir>=]<file>`, repeatable; the subdir is `noarch` (the default), `linux-64`,
`linux-aarch64` or `osx-arm64`. In CI set `MOPM_TOKEN` instead of logging in, or, inside a GitHub Actions job
with `id-token: write`, pass `--oidc` to publish with the job's identity and no stored token (see
[publishing a workspace](publishing-a-workspace.md)). A published version is
immutable and its number can never be reused; fix a bad release by publishing a new version. The registry
refuses a package that breaks the layout rules, limits (100 MB per package file, 128 MiB per unpacked file), or the manifest rules, and says
which in `rejection_code`.

`mopm publish` does not build the `.mojoc` itself. `mopm build` makes the one for this machine's platform and Mojo
into `target/build/<package name>.mojoc` (see "Build the package's targets"); build it per platform and Mojo version
you publish for, and pass each file with `--mojoc <subdir>=<file>`. See `spec/unit-graph.md` for the command mopm
uses to build a library for a build farm.

## 7. Configuration

### `mopm.toml`

```toml
[package]
name = "example/http_client"     # <namespace>/<name>; the name is the import name: lowercase letters, digits, underscore
version = "0.4.0"                # MAJOR.MINOR.PATCH, nothing else
description = "HTTP/1.1 client"  # optional display fields: description, license, repository
license = "Apache-2.0"           #   (checked to be strings), and readme (a Markdown file of at most 64 KiB)
repository = "https://github.com/example/http_client"
readme = "README.md"
mojo = ["1.0.0", "1.1.0"]        # exact compilers this package builds for (or use [toolchain] below)

[dependencies]
"example/http_core" = "1.2"      # full names, quoted; caret: >=1.2.0, <2.0.0
"example/tls" = { version = "0.9" }
"example/local_util" = { path = "../local_util" }   # a path or a version, not both; a path cannot be published

[dev-dependencies]
"example/mopm_test" = "0.1"

[native-dependencies]
zlib = { version = ">=1.2", kind = "shared", mode = "link" }

[native.curl_shim]               # a native library this package ships
kind = "shared"                  # shared | static | both
mode = "link"                    # link (mopm computes flags) | load (the package loads it itself)
build = "cmake -S native -B out && cmake --build out"
outputs = ["out/libcurl_shim.so.1"]

[targets]
lib = { path = "src/http_client" }
bins = [{ name = "fetch", path = "src/fetch.mojo" }]
tests = ["tests"]

[package.metadata.some_tool]     # settings for other tools: mopm preserves, never reads
```

Use either `[package] mojo` (a list of exact versions) or `[toolchain] mojo` (the
older form, a version or a list read as alternatives, locked for the first that resolves; what `mopm new`
writes), never both. Version requirements follow cargo: `"1.2"`, `"~1.2"`, `"=1.2.3"`, `">=1.2, <1.5"`,
`"*"`. mopm refuses keys and tables it does not know, so a typo is an error; `mopm metadata` shows exactly how
the file was read. Every key, with its type, default and allowed values, is in [configuration](configuration.md); `spec/mopm-toml.md` is the draft of the format, and where it differs from the parser, the configuration page says what the parser does.

Not all of this is used end to end today: `[native-dependencies]` is checked and shown by `mopm metadata`, and
`mopm pack` refuses a package that has it, for now. `[native.<id>]` with `kind = "static"` is packed: give the
archive of each platform with `--native <id>=<subdir>:<file>` (see [configuration](configuration.md)).

### Registries and credentials

- `--registry prod|gamma|beta|<url>` on `login`, `logout`, `whoami`, `org`, `publish`, `lock`, `update`, `sync`,
  `add` and `remove`. The default is `prod` (`https://api.mopm.dev`). A URL must be `https`, or plain `http`
  to `127.0.0.1`, `[::1]` or `localhost` with a port (for a local or test registry).
- Credentials are in `credentials.json` under `$XDG_CONFIG_HOME/mopm`, else `~/.config/mopm`; override with
  `--config-dir <dir>`. `MOPM_TOKEN`, when set, wins over a stored login for `publish`.
- The channel root for a project is the registry's (`https://conda.mopm.dev/` for prod); each namespace is its own
  channel below it (`https://conda.mopm.dev/komira-ai/`). The lock records the root, and only the root project's
  choice counts. A lock written before packages had namespaces (`lock_version` 1 or 2) is rewritten by `mopm lock`;
  `mopm sync --locked` refuses it.

### Environment variables

| variable | used by |
|---|---|
| `CONDA_PREFIX`, `MODULAR_HOME` | find the Mojo environment when `--prefix` is not given (before the `.mopm/env` of `mopm sync`) |
| `MOPM_TOKEN` | `publish` (CI) |
| `XDG_CONFIG_HOME`, `HOME` | where credentials live |
| `MOPM_VERSION`, `MOPM_HOME`, `MOPM_RELEASES_URL` | the install script |

### The Mojo toolchain pin for build systems

`mopm plan --unit-graph` and `mopm unit` use a toolchain that mopm pins itself, not the environment. A
build system supplies it. For Buck2 this is the job of buildrules, which has its own `mopm-toolchain.toml`
(it names the mopm and Mojo versions); mopm itself reads no such file. See the buildrules documentation.

## 8. Examples

The [examples page](examples.md) walks through six complete packages (a library, a program with a dependency, several packages in one repository, tests, publishing, and a compiler pin), each of them run by the CI of this repository. These are shorter.

**A library with a test, from nothing**

```sh
mopm new alice/greeter --lib
cd greeter
mopm sync                           # the Mojo toolchain into .mopm/env (no dependencies yet)
mopm test                           # builds tests/test_*.mojo and runs each test in its own process
```

**CI: lock-exact install and strict tests**

```sh
mopm sync --locked
mopm test --retries 2 --deny-flaky --junit report.xml
```

**A package that depends on one with a native library**

```toml
[package]
name = "alice/app"
version = "0.1.0"
[toolchain]
mojo = "1.0.0"
[dependencies]
"example/crypto" = "0.3"          # ships libcrypto_native.so.1
```

```sh
mopm sync
mopm build main.mojo -o app                 # -Xlinker flags and run path added for you
mopm build main.mojo --print-cmd            # see them
```

**Seeing why a test flakes**

```sh
mopm test --retries 3 --format json | jq '.tests[] | select(.status=="flaky") | {id, attempts}'
```

**A build system integration**

```sh
mopm lock
mopm plan --unit-graph --locked --mojo 1.0.0 -o graph.json
mopm unit build --unit 'example/greeter@0.1.0#mojo1.0.0/lib' --graph graph.json --out out --toolchain <toolchain dir>
```

## 9. Where to go next

- [Configuration](configuration.md) for every key of `mopm.toml`, `mopm.lock` and the user's own configuration, and [Examples](examples.md) for six complete packages.
- [mopm.toml](../spec/mopm-toml.md) for the draft of the manifest; `spec/` also holds `lock.md`, `index.md`, `channel.md`,
  `unit-graph.md` and the OpenAPI document.
- [mopm test](mopm-test.md) for the test runner.
- [Why mopm, and how it is built](why-and-design.md) for the design.
- [RELEASING.md](../RELEASING.md) for how releases are made and verified.
- Report a vulnerability privately through the repository's Security tab ([SECURITY.md](../SECURITY.md)).
