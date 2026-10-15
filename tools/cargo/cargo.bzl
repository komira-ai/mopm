"""Rules for building Cargo crates with komira's pinned Rust toolchain.

komira's `crates_io_library`, `rust_binary` and `rust_test` build a crate that
needs nothing from its build script but cfgs and features. The crates of the
AWS SDK and the Lambda runtime need more, and these rules add exactly that,
reusing komira's toolchain (`toolchains//:rust`), its providers
(`RustCrateInfo`, `RustTestInfo`) and its pinned downloads, so crates built
here and crates built by komira's rules link into one binary:

  * `env`, and the `CARGO_PKG_*` variables Cargo sets from the manifest;
  * generated and patched sources (`patch`), run by a Zig tool, never a shell;
  * dependencies a crate renames (`renamed_deps`, `package = "..."` in Cargo);
  * native archives linked into an executable or test (`native_deps`).

Each crate is declared by `cargo_crate`; third_party/rust/BUCK is written by
third_party/rust/gen from `cargo metadata` and Cargo.lock.
"""

load("@komira//tools/build/mojo:download.bzl", "pinned_file")
load("@komira//tools/build/platforms:defs.bzl", "LINUX_X86_64")
load("@komira//tools/build/rust:defs.bzl", "RustCrateInfo", "RustTestInfo", "RustToolchainInfo", "crate_source")

# `-c mopm.rust_cache_nonce=<anything>` changes the key of every rustc action, so the whole graph
# builds from nothing (a cold build to measure). Unset, it changes nothing.
_NONCE = read_root_config("mopm", "rust_cache_nonce", "")

_TOOLCHAIN = attrs.toolchain_dep(default = "toolchains//:rust", providers = [RustToolchainInfo])

def _rustc(ctx, tc, kind, crate, root, hidden, remap, deps, renamed, natives, env, out, identifier):
    """Runs rustc through komira's wrapper; returns the dependency closure."""
    externs = []
    closure = []
    seen = {}
    pairs = [(None, d) for d in deps] + [(alias, d) for alias, d in renamed.items()]
    for alias, d in pairs:
        info = d[RustCrateInfo]
        externs.append(cmd_args(info.lib, format = "--extern=" + (alias or info.crate_name) + "={}"))
        for lib in info.closure:
            if lib not in seen:
                seen[lib] = True
                closure.append(lib)
    args = cmd_args(
        "--crate-name=" + crate,
        "--test" if kind == "test" else "--crate-type=" + kind,
        "--edition=" + ctx.attrs.edition,
        "-Copt-level=" + ctx.attrs.opt_level,
        "-Cdebuginfo=0",
        "-Cstrip=debuginfo",
        "-Cmetadata=" + str(ctx.label.raw_target()).replace(":", "_").replace("/", "_"),
        ["--cfg=feature=\"{}\"".format(f) for f in ctx.attrs.features],
        ["--cfg=" + c for c in ctx.attrs.cfgs],
        ["--cap-lints=allow"] if ctx.attrs.cap_lints else [],
        remap,
        externs,
        # Cargo passes the compiler's proc_macro crate to a proc-macro crate, which edition 2018 and later need to name it.
        ["--extern=proc_macro"] if kind == "proc-macro" else [],
        [cmd_args(lib, format = "-Ldependency={}", parent = 1) for lib in closure],
        [cmd_args(n, format = "-Clink-arg={}") for n in natives],
        ctx.attrs.rustc_flags,
        "-o",
        out.as_output(),
        root,
        hidden = hidden,
    )
    ctx.actions.run(
        cmd_args(tc.busybox, "sh", tc.wrapper, tc.busybox, tc.sysroot, tc.zig, tc.cc_target, out.as_output(), "--", args),
        env = env | ({"MOPM_CACHE_NONCE": _NONCE} if _NONCE else {}),
        category = "rustc",
        identifier = identifier,
    )
    return closure

_COMMON = {
    "cap_lints": attrs.bool(default = False),
    "cfgs": attrs.list(attrs.string(), default = []),
    "crate_root": attrs.string(),
    "deps": attrs.list(attrs.dep(providers = [RustCrateInfo]), default = []),
    "edition": attrs.string(default = "2021"),
    "env": attrs.dict(attrs.string(), attrs.string(), default = {}),
    "features": attrs.list(attrs.string(), default = []),
    # Archives linked into the executable or test (`-Clink-arg=<archive>`),
    # the place Cargo's `links` / `cargo:rustc-link-lib` would put them.
    "native_deps": attrs.list(attrs.dep(), default = []),
    "opt_level": attrs.string(default = "3"),
    "renamed_deps": attrs.dict(attrs.string(), attrs.dep(providers = [RustCrateInfo]), default = {}),
    "rustc_flags": attrs.list(attrs.string(), default = []),
    "toolchain": _TOOLCHAIN,
}

# ---- a crate ---------------------------------------------------------------

def _crate_env(ctx):
    v = ctx.attrs.version
    major, minor, patch_pre = (v.split(".") + ["0", "0"])[:3]
    patch = patch_pre.split("-")[0].split("+")[0]
    pre = patch_pre.split("-", 1)[1] if "-" in patch_pre else ""
    e = {
        "CARGO_CRATE_NAME": ctx.attrs.crate_name,
        "CARGO_PKG_NAME": ctx.attrs.pkg_name,
        "CARGO_PKG_VERSION": v,
        "CARGO_PKG_VERSION_MAJOR": major,
        "CARGO_PKG_VERSION_MINOR": minor,
        "CARGO_PKG_VERSION_PATCH": patch,
        "CARGO_PKG_VERSION_PRE": pre,
    }
    e.update(ctx.attrs.env)
    return e

def _crate_impl(ctx):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    src = ctx.attrs.src_dir[DefaultInfo].default_outputs[0]
    if ctx.attrs.patch_spec != None:
        spec = ctx.actions.write("patch.json", ctx.attrs.patch_spec)
        patched = ctx.actions.declare_output("patched", dir = True)
        ctx.actions.run(
            cmd_args(ctx.attrs.patch_tool[RunInfo], spec, src, patched.as_output()),
            category = "crate_patch",
        )
        src = patched
    crate = ctx.attrs.crate_name
    ext = "so" if ctx.attrs.proc_macro else "rlib"
    lib = ctx.actions.declare_output("{}/lib{}.{}".format(crate, crate, ext))
    closure = _rustc(
        ctx,
        tc,
        "proc-macro" if ctx.attrs.proc_macro else "rlib",
        crate,
        src.project(ctx.attrs.crate_root),
        [src],
        [cmd_args(src, format = "--remap-path-prefix={}=" + ctx.attrs.src_dir_label)],
        ctx.attrs.deps,
        ctx.attrs.renamed_deps,
        [],
        _crate_env(ctx),
        lib,
        crate,
    )
    return [
        DefaultInfo(default_output = lib),
        RustCrateInfo(crate_name = crate, lib = lib, closure = [lib] + closure),
    ]

cargo_crate_rule = rule(
    impl = _crate_impl,
    attrs = _COMMON | {
        "crate_name": attrs.string(),
        "patch_spec": attrs.option(attrs.string(), default = None),
        "patch_tool": attrs.exec_dep(default = "mopm//tools/cargo:crate_patch"),
        "pkg_name": attrs.string(),
        "proc_macro": attrs.bool(default = False),
        "src_dir": attrs.dep(),
        "src_dir_label": attrs.string(),
        "version": attrs.string(),
    },
)

def cargo_crate(
        name,
        version,
        sha256,
        size,
        crate = None,
        crate_root = "src/lib.rs",
        patch = None,
        **kwargs):
    """A crates.io crate pinned by the sha256 and size of its `.crate` file.

    `crate` is the registry name (default `name`). `patch` is a dict with
    `copy`, `sub` and `add` (tools/cargo/crate_patch.zig) applied to the
    unpacked crate before it is compiled. Everything a build script would
    have decided is stated here: features, cfgs, env, patch, native_deps.
    """
    crate = crate or name
    prefix = "{}-{}".format(crate, version)
    pinned_file(
        name = name + ".crate",
        url = "https://static.crates.io/crates/{}/{}.crate".format(crate, prefix),
        sha256 = sha256,
        size_bytes = size,
    )
    crate_source(
        name = name + ".src",
        archive = ":{}.crate".format(name),
        busybox = "komira//tools/build/toolchains:busybox",
        prefix = prefix,
        exec_compatible_with = LINUX_X86_64,
    )
    cargo_crate_rule(
        name = name,
        pkg_name = crate,
        crate_name = kwargs.pop("crate_name", crate.replace("-", "_")),
        version = version,
        src_dir = ":{}.src".format(name),
        src_dir_label = prefix,
        crate_root = crate_root,
        cap_lints = True,
        patch_spec = json.encode(patch) if patch else None,
        visibility = ["PUBLIC"],
        **kwargs
    )

# ---- executables and tests ---------------------------------------------------

def _sources(ctx):
    roots = [s for s in ctx.attrs.srcs if s.short_path == ctx.attrs.crate_root]
    if len(roots) != 1:
        fail("{}: crate_root `{}` must name exactly one of srcs".format(ctx.label, ctx.attrs.crate_root))
    d = ctx.actions.copied_dir("__srcs__", {s.short_path: s for s in ctx.attrs.srcs})
    remap = [cmd_args(d, format = "--remap-path-prefix={}=" + ctx.label.cell + "/" + ctx.label.package)]
    return d.project(roots[0].short_path), [d], remap

def _natives(ctx):
    return [d[DefaultInfo].default_outputs[0] for d in ctx.attrs.native_deps]

def _own_env(ctx):
    return {"CARGO_PKG_NAME": ctx.label.name, "CARGO_PKG_VERSION": "0.0.0"} | ctx.attrs.env

def _bin_impl(ctx):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    root, hidden, remap = _sources(ctx)
    ungated = ctx.actions.declare_output("ungated/" + ctx.label.name)
    _rustc(ctx, tc, "bin", ctx.label.name.replace("-", "_"), root, hidden, remap, ctx.attrs.deps, ctx.attrs.renamed_deps, _natives(ctx), _own_env(ctx), ungated, ctx.label.name)
    sub_targets = {"ungated": [DefaultInfo(default_output = ungated), RunInfo(args = cmd_args(ungated))]}
    if ctx.attrs.welded_tests:
        exe = ctx.actions.declare_output(ctx.label.name)
        markers = [t[RustTestInfo].marker for t in ctx.attrs.welded_tests]
        ctx.actions.run(cmd_args(tc.busybox, "cp", ungated, exe.as_output(), hidden = markers), category = "rust_gate_join")
        sub_targets["tests"] = [DefaultInfo(default_outputs = markers)]
    else:
        exe = ungated
    return [DefaultInfo(default_output = exe, sub_targets = sub_targets), RunInfo(args = cmd_args(exe))]

cargo_bin_rule = rule(
    impl = _bin_impl,
    attrs = _COMMON | {
        "srcs": attrs.list(attrs.source()),
        "welded_tests": attrs.list(attrs.dep(providers = [RustTestInfo]), default = []),
    },
)

def cargo_bin(name, tests = [], **kwargs):
    cargo_bin_rule(name = name, welded_tests = tests, **kwargs)

def _test_impl(ctx):
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    root, hidden, remap = _sources(ctx)
    exe = ctx.actions.declare_output("bin/" + ctx.label.name)
    _rustc(ctx, tc, "test", ctx.label.name.replace("-", "_"), root, hidden, remap, ctx.attrs.deps, ctx.attrs.renamed_deps, _natives(ctx), _own_env(ctx), exe, ctx.label.name)
    marker = ctx.actions.declare_output(ctx.label.name + ".passed")
    label = str(ctx.label.raw_target())

    def runner(marker_arg):
        return cmd_args(tc.gate, "rust", "--busybox", tc.busybox, "--label", label, "--test", exe, "--marker", marker_arg, "--timeout-s", str(ctx.attrs.test_timeout_s))

    ctx.actions.run(runner(marker.as_output()), category = "rust_gated_test", identifier = ctx.label.name)
    return [
        DefaultInfo(default_output = marker, sub_targets = {"bin": [DefaultInfo(default_output = exe)]}),
        RustTestInfo(marker = marker),
        ExternalRunnerTestInfo(type = "custom", command = [runner("/dev/null")], labels = []),
    ]

cargo_test = rule(
    impl = _test_impl,
    attrs = _COMMON | {
        "srcs": attrs.list(attrs.source()),
        "test_timeout_s": attrs.int(default = 600),
    },
)

# ---- the generator of third_party/rust/BUCK ---------------------------------

def _gen_impl(ctx):
    out = ctx.actions.declare_output("crates.bzl")
    cmd = cmd_args(
        ctx.attrs.tool[RunInfo],
        "--metadata", ctx.attrs.cargo_metadata,
        "--lock", ctx.attrs.lock,
        "--tree", ctx.attrs.tree,
        "--sizes", ctx.attrs.sizes,
        "--overrides", ctx.attrs.overrides,
        "--out", out.as_output(),
    )
    if ctx.attrs.check != None:
        cmd.add("--check", ctx.attrs.check)
    ctx.actions.run(cmd, category = "cargo_to_buck")
    return [DefaultInfo(default_output = out)]

cargo_buck_gen = rule(
    impl = _gen_impl,
    attrs = {
        # The committed BUCK file: when set, the action fails unless it is
        # exactly what the inputs generate (a drift check).
        "check": attrs.option(attrs.source(), default = None),
        "lock": attrs.source(),
        "cargo_metadata": attrs.source(),
        "overrides": attrs.source(),
        "sizes": attrs.source(),
        "tool": attrs.exec_dep(),
        "tree": attrs.source(),
    },
)
