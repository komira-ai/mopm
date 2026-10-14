#!/usr/bin/env python3
"""End-to-end test of `mopm sync` against mopm-fake-registry and the real
Mojo toolchain.

    python3 -I tests/install_e2e/run.py <mopm> <mopm-fake-registry> <mojo env prefix>

Standard library only; `pixi` must be on PATH (it is passed to mopm with
--pixi). The script:

  1. builds libgreet (tests/e2e/native/greet.c) with the host C compiler and
     precompiles the Mojo package greet (tests/e2e/pkgs/greet) with the mojo
     of <mojo env prefix>;
  2. packs them into a real conda package, mojo-greet-1.0.0-mojo1.0.0_0.conda,
     laid out as spec/channel.md says (lib/mojo/greet.mojoc,
     lib/mojo/greet.mopm.json, lib/libgreet.<so|dylib>), and serves it from
     the fake registry with its sparse index line and repodata.json entry;
  3. in a project whose mopm.toml needs greet = "1", runs `mopm sync`, which
     locks, downloads, verifies, writes .mopm/pixi.toml and runs pixi;
  4. builds tests/install_e2e/prog.mojo with `mopm build --prefix
     .mopm/.pixi/envs/default` and runs the binary in an empty environment,
     and runs it with `mopm run`: both must print "greet 4242", which only
     libgreet computes.

Can-fail checks (each is a refusal the test must see):

  * a stale lock: mopm.toml changed after locking (a requirement the locked
    version does not meet, a new dependency, a removed one, another
    toolchain) makes `mopm sync --locked` fail, naming the drift, and leaves
    mopm.lock as it was;
  * a tampered artifact: the channel's .conda is replaced by bytes of the
    same size with one byte changed, then by bytes one longer. `mopm sync
    --locked` must refuse each, naming the pinned and the actual value, must
    not keep the file, and must not run pixi. A project that kept the good
    file from an earlier sync and then has that copy tampered with must not
    use it either. With the original bytes back, the same sync succeeds, so
    the refusals came from the bytes and nothing else.

Each check prints `ok   <name>` or `FAIL <name>: ...`; the exit status is 1
if any failed.
"""
import hashlib
import io
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
E2E = os.path.join(os.path.dirname(HERE), "e2e")
MOJO = "1.0.0"
BUILD = "mojo%s_0" % MOJO
ENV = os.path.join(".mopm", ".pixi", "envs", "default")
failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


def host():
    """(conda subdir, shared library suffix) of this machine."""
    system, machine = platform.system(), platform.machine()
    if system == "Linux" and machine == "x86_64":
        return "linux-64", "so"
    if system == "Linux" and machine in ("aarch64", "arm64"):
        return "linux-aarch64", "so"
    if system == "Darwin" and machine == "arm64":
        return "osx-arm64", "dylib"
    raise SystemExit("install e2e: unsupported host %s-%s" % (system, machine))


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def zstd_raw(data):
    """A zstd frame holding `data` in raw (stored) blocks: valid zstd that any
    decoder reads, written without a compressor (RFC 8878, sections 3.1.1)."""
    out = bytearray(b"\x28\xb5\x2f\xfd")  # magic number 0xFD2FB528
    out.append(0x00)  # frame header: no content size, no checksum, no dictionary
    out.append(0x38)  # window descriptor: 2^17 bytes, the largest block size
    block = 128 * 1024
    chunks = [data[i:i + block] for i in range(0, len(data), block)] or [b""]
    for n, chunk in enumerate(chunks):
        last = 1 if n == len(chunks) - 1 else 0
        out += (last | (0 << 1) | (len(chunk) << 3)).to_bytes(3, "little")  # type 0: raw
        out += chunk
    return bytes(out)


def tar(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as t:
        for path, data, mode in entries:
            info = tarfile.TarInfo(path)
            info.size, info.mode, info.mtime = len(data), mode, 0
            t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def conda_package(name, version, subdir, depends, files):
    """The bytes of mojo-<name>-<version>-<BUILD>.conda holding `files`
    ((path, bytes, mode) under the prefix)."""
    stem = "mojo-%s-%s-%s" % (name, version, BUILD)
    index = {"build": BUILD, "build_number": 0, "depends": depends, "name": "mojo-" + name,
             "subdir": subdir, "version": version}
    paths = {"paths": [{"_path": p, "path_type": "hardlink", "sha256": sha256(d), "size_in_bytes": len(d)}
                       for p, d, _ in files], "paths_version": 1}
    info = [("info/index.json", json.dumps(index, sort_keys=True).encode(), 0o644),
            ("info/paths.json", json.dumps(paths, sort_keys=True).encode(), 0o644),
            ("info/files", "".join(p + "\n" for p, _, _ in files).encode(), 0o644)]
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
        for member, data in (("metadata.json", json.dumps({"conda_pkg_format_version": 2}).encode()),
                             ("info-%s.tar.zst" % stem, zstd_raw(tar(info))),
                             ("pkg-%s.tar.zst" % stem, zstd_raw(tar(files)))):
            z.writestr(zipfile.ZipInfo(member, date_time=(1980, 1, 1, 0, 0, 0)), data)
    return buf.getvalue()


def build_greet(mojo_env, work, ext):
    """libgreet and greet.mojoc, as tests/e2e/run.sh builds them."""
    lib = os.path.join(work, "libgreet." + ext)
    if ext == "dylib":
        cmd = ["cc", "-dynamiclib", "-install_name", "@rpath/libgreet.dylib", "-o", lib]
    else:
        cmd = ["cc", "-shared", "-fPIC", "-Wl,-soname,libgreet.so", "-o", lib]
    subprocess.run(cmd + [os.path.join(E2E, "native", "greet.c")], check=True)
    mojoc = os.path.join(work, "greet.mojoc")
    env = dict(os.environ, MODULAR_HOME=os.path.join(mojo_env, "share", "max"))
    subprocess.run([os.path.join(mojo_env, "bin", "mojo"), "precompile", os.path.join(E2E, "pkgs", "greet"), "-o", mojoc],
                   check=True, env=env)
    with open(lib, "rb") as f:
        lib_bytes = f.read()
    with open(mojoc, "rb") as f:
        mojoc_bytes = f.read()
    return lib_bytes, mojoc_bytes


class Fake:
    def __init__(self, exe, workdir):
        self.dir = os.path.join(workdir, "fake")
        self.proc = subprocess.Popen([exe, "--dir", self.dir, "--port", "0"], stdout=subprocess.PIPE, text=True)
        m = re.search(r"listening on (http://\S+)", self.proc.stdout.readline())
        if not m:
            raise SystemExit("the fake registry did not start")
        self.base = m.group(1)

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)


def publish(fake, subdir, filename, data, native):
    """greet 1.0.0 in the fake's sparse index and channel (spec/index.md,
    spec/channel.md), as its data directory serves them."""
    rec = {"v": 1, "name": "greet", "version": "1.0.0", "build": BUILD, "state": "published",
           "published_at": "2026-10-14T12:00:00Z", "requires_mojo": "==" + MOJO, "deps": [], "native": native,
           "files": [{"filename": filename, "sha256": sha256(data), "size": len(data), "subdir": subdir,
                      "url": "%s/channel/%s/%s" % (fake.base, subdir, filename)}],
           "manifest_sha256": sha256(b"greet manifest")}
    path = os.path.join(fake.dir, "index", "gr", "ee", "greet")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(json.dumps(rec, sort_keys=True, separators=(",", ":")) + "\n")
    repodata = {"info": {"subdir": subdir}, "packages": {}, "removed": [], "packages.conda": {filename: {
        "build": BUILD, "build_number": 0, "depends": ["mojo-compiler ==" + MOJO], "name": "mojo-greet",
        "sha256": sha256(data), "size": len(data), "subdir": subdir, "version": "1.0.0"}}}
    with open(os.path.join(fake.dir, "channel", subdir, "repodata.json"), "w") as f:
        f.write(json.dumps(repodata, sort_keys=True) + "\n")
    serve(fake, subdir, filename, data)


def serve(fake, subdir, filename, data):
    with open(os.path.join(fake.dir, "channel", subdir, filename), "wb") as f:
        f.write(data)


MANIFEST = """[package]
name = "app"
version = "0.1.0"

[toolchain]
mojo = "%s"

[dependencies]
%s
"""


def main(mopm, fake_exe, mojo_env):
    subdir, ext = host()
    pixi = shutil.which("pixi")
    if not pixi:
        raise SystemExit("install e2e: pixi is not on PATH")
    with tempfile.TemporaryDirectory() as work:
        lib_bytes, mojoc_bytes = build_greet(mojo_env, work, ext)
        soname = "libgreet." + ext
        native = [{"id": "greet", "soname": soname}]
        meta = {"schema": 1, "name": "greet", "version": "1.0.0", "deps": [],
                "native": [{"id": "greet", "soname": soname, "file": "../" + soname}]}
        filename = "mojo-greet-1.0.0-%s.conda" % BUILD
        good = conda_package("greet", "1.0.0", subdir, ["mojo-compiler ==" + MOJO], [
            ("lib/mojo/greet.mojoc", mojoc_bytes, 0o644),
            ("lib/mojo/greet.mopm.json", (json.dumps(meta, sort_keys=True) + "\n").encode(), 0o644),
            ("lib/" + soname, lib_bytes, 0o755),
        ])
        good_sha = sha256(good)
        print("     %s: %d bytes, sha256 %s" % (filename, len(good), good_sha))

        fake = Fake(fake_exe, work)
        try:
            publish(fake, subdir, filename, good, native)

            def project(name, deps='greet = "1"', mojo=MOJO):
                d = os.path.join(work, name)
                os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, "mopm.toml"), "w") as f:
                    f.write(MANIFEST % (mojo, deps))
                shutil.copy(os.path.join(HERE, "prog.mojo"), d)
                return d

            def run(d, *args, timeout=1800):
                return subprocess.run([mopm, *args], cwd=d, capture_output=True, text=True, timeout=timeout)

            def sync(d, *args):
                return run(d, "sync", "--pixi", pixi, *args)

            def read(d, *path):
                p = os.path.join(d, *path)
                return open(p).read() if os.path.exists(p) else None

            reg = ["--registry", fake.base]
            app = project("app")

            r = sync(app, "--locked")
            check("sync --locked without a lock fails and installs nothing",
                  r.returncode == 1 and "--locked: there is no mopm.lock" in r.stderr
                  and not os.path.exists(os.path.join(app, ".mopm")), r.stderr)

            # ------------------------------------------------ lock, install, build, run
            r = sync(app, *reg)
            check("sync locks and installs", r.returncode == 0 and "installed 1 packages for %s" % subdir in r.stdout,
                  "exit %d\n%s\n%s" % (r.returncode, r.stdout, r.stderr))
            lock = read(app, "mopm.lock") or ""
            check("the lock pins the package's bytes", '"sha256": "%s"' % good_sha in lock
                  and '"size": %d' % len(good) in lock, lock)
            pin = 'mojo-greet = { version = "==1.0.0", build = "%s", sha256 = "%s" }' % (BUILD, good_sha)
            toml = read(app, ".mopm", "pixi.toml") or ""
            check("the pixi project pins the version, build and sha256", pin in toml, toml)
            record = read(app, ENV, "conda-meta", "mojo-greet-1.0.0-%s.json" % BUILD)
            check("pixi installed exactly the locked file",
                  record is not None and json.loads(record).get("sha256") == good_sha, str(record)[:400])
            for path in (("lib", "mojo", "greet.mojoc"), ("lib", "mojo", "greet.mopm.json"), ("lib", soname)):
                check("installed: " + "/".join(path), os.path.exists(os.path.join(app, ENV, *path)))

            out = os.path.join(app, "prog")
            r = run(app, "build", "prog.mojo", "-o", out, "--prefix", ENV)
            check("mopm build links the installed native library", r.returncode == 0, r.stdout + r.stderr)
            if r.returncode == 0:
                b = subprocess.run([out], capture_output=True, text=True, env={}, timeout=60)
                check("the binary, in an empty environment, prints greet 4242",
                      b.returncode == 0 and "greet 4242" in b.stdout, "exit %d: %s%s" % (b.returncode, b.stdout, b.stderr))
            r = run(app, "run", "prog.mojo", "--prefix", ENV)
            check("mopm run prints greet 4242", r.returncode == 0 and "greet 4242" in r.stdout, r.stdout + r.stderr)

            r = sync(app, "--locked")
            check("sync --locked with a fresh lock installs it again and leaves the lock alone",
                  r.returncode == 0 and read(app, "mopm.lock") == lock, r.stdout + r.stderr)

            # ------------------------------------------------ stale locks
            stale = [
                ("a requirement the locked version does not meet", 'greet = "2"', MOJO,
                 'mopm.lock is out of date with mopm.toml: mopm.toml needs greet "2", but mopm.lock has greet 1.0.0'),
                ("a new dependency", 'greet = "1"\nother = "1"', MOJO,
                 "mopm.lock is out of date with mopm.toml: mopm.toml needs other, which mopm.lock does not lock"),
                ("a removed dependency", "", MOJO,
                 "mopm.lock is out of date with mopm.toml: mopm.lock locks greet 1.0.0, which nothing in mopm.toml needs"),
                ("another toolchain", 'greet = "1"', "1.1.0",
                 "mopm.lock is out of date with mopm.toml: mopm.lock is for mojo 1.0.0; mopm.toml's [toolchain] allows 1.1.0"),
            ]
            for what, deps, mojo, want in stale:
                project("app", deps, mojo)
                r = sync(app, "--locked")
                check("stale lock (%s): sync --locked fails, naming it" % what,
                      r.returncode == 1 and want in r.stderr and read(app, "mopm.lock") == lock,
                      "exit %d: %s" % (r.returncode, r.stderr))
            project("app")

            # ------------------------------------------------ tampered artifacts
            flipped = bytearray(good)
            flipped[len(flipped) // 2] ^= 0x01
            flipped = bytes(flipped)
            longer = good + b"\0"
            fresh = project("fresh")
            shutil.copy(os.path.join(app, "mopm.lock"), fresh)
            kept = os.path.join(fresh, ".mopm", "channel", subdir, filename)
            for what, data, want in [
                ("one byte changed", flipped,
                 "%s: sha256 mismatch: mopm.lock pins %s, the file is %s; refused" % (filename, good_sha, sha256(flipped))),
                ("one byte longer", longer,
                 "%s: mopm.lock pins %d bytes, the file has %d; refused" % (filename, len(good), len(longer))),
            ]:
                serve(fake, subdir, filename, data)
                r = sync(fresh, "--locked")
                check("tampered artifact (%s): sync --locked refuses it" % what,
                      r.returncode == 1 and want in r.stderr, "exit %d: %s" % (r.returncode, r.stderr))
                check("tampered artifact (%s): the file is not kept and pixi does not run" % what,
                      not os.path.exists(kept) and not os.path.exists(os.path.join(fresh, ".mopm", "pixi.toml")))

            # The project that synced before keeps the good file; tampered
            # with, it is not used (and the channel's copy is tampered too).
            serve(fake, subdir, filename, flipped)
            app_kept = os.path.join(app, ".mopm", "channel", subdir, filename)
            with open(app_kept, "wb") as f:
                f.write(flipped)
            r = sync(app, "--locked")
            check("tampered kept file: sync --locked does not use it",
                  r.returncode == 1 and "sha256 mismatch: mopm.lock pins %s" % good_sha in r.stderr,
                  "exit %d: %s" % (r.returncode, r.stderr))

            # Control: the same sync with the original bytes back succeeds.
            serve(fake, subdir, filename, good)
            r = sync(fresh, "--locked")
            check("control: with the original bytes the same sync --locked succeeds",
                  r.returncode == 0 and os.path.exists(kept), "exit %d: %s%s" % (r.returncode, r.stdout, r.stderr))
        finally:
            fake.close()
    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("usage: run.py <mopm> <mopm-fake-registry> <mojo env prefix>")
    sys.exit(main(*(os.path.abspath(a) for a in sys.argv[1:])))
