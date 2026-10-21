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
curl -fsSL https://packages.komira.ai/apt/keyring.gpg | sudo tee /etc/apt/keyrings/packages.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/packages.gpg] https://packages.komira.ai/apt stable main" | sudo tee /etc/apt/sources.list.d/packages.list
sudo apt update && sudo apt install mopm
```

### Homebrew (planned)

A Homebrew tap is planned. It does not exist yet; use the script or the tarball.

### A Mojo environment

`mopm build`, `run`, `repl` and `test` run the `mojo` of an environment, so you need one with `mojo` and
`mojo-compiler` installed (Mojo 1.0.0 is the version mopm's tests and pinned toolchain use). The usual way is
pixi:

```toml
# pixi.toml
[workspace]
name = "my_project"
channels = ["https://conda.modular.com/max", "conda-forge"]
platforms = ["linux-64"]          # or linux-aarch64, osx-arm64

[dependencies]
mojo = "==1.0.0"
mojo-compiler = "==1.0.0"
```

mopm finds the environment from `--prefix <dir>`, else `CONDA_PREFIX`, else `MODULAR_HOME` without its
trailing `/share/max`. `mopm sync` also needs `pixi` on your `PATH` (or `--pixi <path>`).

## 2. Start a package: `new` and `init`

```sh
mopm new my_pkg --lib        # a library in a new directory my_pkg (the default kind)
mopm new my_app --bin        # a program
cd existing_dir && mopm init [--lib|--bin] [--name <name>]    # in the current directory
```

A new library contains `mopm.toml`, `src/<name>/__init__.mojo`, `tests/test_<...>.mojo`, a README and a
`.gitignore`. Its manifest:

```toml
[package]
name = "my_pkg"
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
mopm add http_client            # newest version that fits, written as ^X.Y.Z; then lock
mopm add http_client@0.4        # with a requirement
mopm add test_util --dev        # into [dev-dependencies]
mopm add helper --path ../helper
mopm remove http_client
mopm lock                       # resolve mopm.toml against the registry's index, write mopm.lock
mopm update [pkg...]            # move the named packages (all, with none) to the newest that fit
mopm tree                       # draw the dependency graph in mopm.lock
mopm sync                       # install mopm.lock into .mopm/ (locks first if needed)
mopm sync --locked              # CI: install exactly the lock, fail if it would change
```

`add` and `remove` keep the rest of `mopm.toml` byte for byte (comments, order, spacing), and write
nothing if the result does not resolve. Reading the index needs no account. After `sync`, the environment is
`.mopm/.pixi/envs/default`; pass it as `--prefix` to `build`, `run`, `repl` and `test`.

Commit `mopm.lock`. Every download is checked against the lock's sha256 and size.

Because a compiled Mojo package is tied to one compiler, a dependency is only chosen if it has a build for
your exact Mojo. If none does, `mopm lock` says which versions have builds and for which Mojo.

Note: the hosted registry is new and its catalogue is small, so `mopm add` of a registry package may have
nothing to find yet (the package list is on mopm.dev). Path dependencies
work now, and `--registry` can point at a local test registry.

## 4. Build, run, REPL

```sh
mopm build hello.mojo -o hello --prefix .mopm/.pixi/envs/default
mopm run hello.mojo
mopm repl
mopm build hello.mojo --print-cmd     # show the mojo command instead of running it
```

These run `<env>/bin/mojo` with the linker flags (or the REPL preload list) for the native libraries of
every installed package computed for you. stdin, signals and the exit status are mojo's. A closure with a
missing library, two owners of one library, or a library file absent from `<env>/lib` is refused with a
message. `mopm link-plan <file.mopm.json>...` prints the plan from metadata files, and
`mopm metadata [mopm.toml]` checks a manifest and prints it as JSON.

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
mopm login                                   # device login through GitHub; stores credentials.json (0600)
mopm whoami

mojo precompile -I <dep dirs> src/my_pkg -o my_pkg.mojoc    # build the .mojoc yourself (see below)

mopm pack    --compiler 1.0.0 --mojoc linux-64=my_pkg.mojoc          # writes dist/<subdir>/mojo-my_pkg-<v>-mojo1.0.0_0.conda
mopm publish --compiler 1.0.0 --mojoc linux-64=my_pkg.mojoc --dry-run # pack and show what would be sent
mopm publish --compiler 1.0.0 --mojoc linux-64=my_pkg.mojoc            # publish to prod
mopm publish ... --registry beta                                       # prod (default), gamma, beta, or a URL
```

`--mojoc` takes `[<subdir>=]<file>`, repeatable; the subdir is `noarch` (the default), `linux-64`,
`linux-aarch64` or `osx-arm64`. In CI set `MOPM_TOKEN` instead of logging in. A published version is
immutable and its number can never be reused; fix a bad release by publishing a new version. The registry
refuses a package that breaks the layout rules, limits (100 MB per package file, 128 MiB per unpacked file), or the manifest rules, and says
which in `rejection_code`.

Today `mopm publish` does not build the `.mojoc` for you; building it per Mojo version is **planned**. The
exact `mojo precompile` flags for your layout are the compiler's, not mopm's. See `spec/unit-graph.md` for
the command mopm itself uses to build a library.

## 7. Configuration

### `mopm.toml`

```toml
[package]
name = "http_client"             # import name and registry name: lowercase letters, digits, underscore
version = "0.4.0"                # MAJOR.MINOR.PATCH, nothing else
description = "HTTP/1.1 client"  # optional display fields: description, license, repository
license = "Apache-2.0"           #   (checked to be strings), and readme (a Markdown file of at most 64 KiB)
repository = "https://github.com/example/http_client"
readme = "README.md"
mojo = ["1.0.0", "1.1.0"]        # exact compilers this package builds for (or use [toolchain] below)

[dependencies]
http_core = "1.2"                # caret: >=1.2.0, <2.0.0
tls = { version = "0.9" }
local_util = { path = "../local_util" }   # a path or a version, not both; a path cannot be published

[dev-dependencies]
mopm_test = "0.1"

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

Use either `[package] mojo` (a list of exact versions; gives a version 2 lock) or `[toolchain] mojo` (the
older form, a version or a list read as alternatives, locked for the first that resolves; what `mopm new`
writes), never both. Version requirements follow cargo: `"1.2"`, `"~1.2"`, `"=1.2.3"`, `">=1.2, <1.5"`,
`"*"`. mopm refuses keys and tables it does not know, so a typo is an error; `mopm metadata` shows exactly how
the file was read. Every key, with its type, default and allowed values, is in [configuration](configuration.md); `spec/mopm-toml.md` is the draft of the format, and where it differs from the parser, the configuration page says what the parser does.

Not all of this is used end to end today: `[native-dependencies]` and `[native.<id>]` are checked and shown by
`mopm metadata`, and `mopm pack` refuses a package that has either, for now.

### Registries and credentials

- `--registry prod|gamma|beta|<url>` on `login`, `logout`, `whoami`, `publish`, `lock`, `update`, `sync`,
  `add` and `remove`. The default is `prod` (`https://api.mopm.dev`). A URL must be `https`, or plain `http`
  to `127.0.0.1`, `[::1]` or `localhost` with a port (for a local or test registry).
- Credentials are in `credentials.json` under `$XDG_CONFIG_HOME/mopm`, else `~/.config/mopm`; override with
  `--config-dir <dir>`. `MOPM_TOKEN`, when set, wins over a stored login for `publish`.
- The channel for a project is the registry's channel (`https://conda.mopm.dev/` for prod). The lock records
  it, and only the root project's choice counts.

### Environment variables

| variable | used by |
|---|---|
| `CONDA_PREFIX`, `MODULAR_HOME` | find the Mojo environment when `--prefix` is not given |
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
mopm new greeter --lib
cd greeter
mopm test --prefix <your env>       # builds tests/test_*.mojo and runs each test in its own process
```

**CI: lock-exact install and strict tests**

```sh
mopm sync --locked
mopm test --prefix .mopm/.pixi/envs/default --retries 2 --deny-flaky --junit report.xml
```

**A package that depends on one with a native library**

```toml
[package]
name = "app"
version = "0.1.0"
[toolchain]
mojo = "1.0.0"
[dependencies]
crypto = "0.3"          # ships libcrypto_native.so.1
```

```sh
mopm sync
mopm build main.mojo -o app --prefix .mopm/.pixi/envs/default     # -Xlinker flags and run path added for you
mopm build main.mojo --prefix .mopm/.pixi/envs/default --print-cmd   # see them
```

**Seeing why a test flakes**

```sh
mopm test --retries 3 --format json | jq '.tests[] | select(.status=="flaky") | {id, attempts}'
```

**A build system integration**

```sh
mopm lock
mopm plan --unit-graph --locked --mojo 1.0.0 -o graph.json
mopm unit build --unit 'greeter@0.1.0#mojo1.0.0/lib' --graph graph.json --out out --toolchain <toolchain dir>
```

## 9. Where to go next

- [Configuration](configuration.md) for every key of `mopm.toml`, `mopm.lock` and the user's own configuration, and [Examples](examples.md) for six complete packages.
- [mopm.toml](../spec/mopm-toml.md) for the draft of the manifest; `spec/` also holds `lock.md`, `index.md`, `channel.md`,
  `unit-graph.md` and the OpenAPI document.
- [mopm test](mopm-test.md) for the test runner.
- [Why mopm, and how it is built](why-and-design.md) for the design.
- [RELEASING.md](../RELEASING.md) for how releases are made and verified.
- Report a vulnerability privately through the repository's Security tab ([SECURITY.md](../SECURITY.md)).
