#!/usr/bin/env python3
"""End-to-end tests of `mopm lock`, `mopm update` and `mopm tree` against
mopm-fake-registry.

    python3 -I tests/resolve_e2e/run.py path/to/mopm path/to/mopm-fake-registry

Standard library only. The fake registry is started on a free port; the
index records and the channel's repodata.json files below are then written
into its data directory, which it serves at /index/... and /channel/... as
the hosted registry does (spec/index.md, spec/channel.md). Each check prints
`ok   <name>` or `FAIL <name>: ...`; the exit status is 1 if any failed.

The index is built so that a resolver that picks a wrong version writes a
lock that differs from tests/resolve_e2e/expected.lock. Each trap below is a
version a faulty resolver would pick:

    http_client 0.5.0   ignores the requirement "0.4"
    http_client 0.4.1   ignores the compiler (built for mojo 1.1.0)
    http_core   2.0.0   ignores http_client's range ">=1.2,<2"
    http_core   1.4.0   satisfies http_client but not tls's "~1.2" (the diamond)
    http_core   1.2.6   is yanked
    http_core   1.2.4   is older: the resolver must take the newest that fits
    tls         1.2.0   is taken down
    crypto      2.1.0b1 is not MAJOR.MINOR.PATCH: ignored, with a warning
    legacy      1.2.3.4 has four parts: ignored ("1" must give 1.1.0, not it)
    legacy      2.0.0-rc1 is a pre-release: ignored (">=2.0.0-rc1" matches nothing)
    legacy      1.0     is 1.0.0 ("=1.0.0" picks it)

The repodata `depends` disagree with the index records' `deps[].range` on
purpose (every range there is ">=99"): the resolver reads only `deps[].range`,
the cargo requirement from the publisher's mopm.toml, so the lock must not
change.

The lock's channel is the fake's loopback http URL with a path
(`http://127.0.0.1:<port>/channel/`), which mopm writes and reads; a lock
naming a plain-http channel on any other host is refused. spec/lock.schema.json
does not allow such a channel yet, so the lock is compared byte for byte here
and the schema check follows the spec change.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SIZE = 4096
failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


def digest(subdir, filename):
    return hashlib.sha256(("%s/%s" % (subdir, filename)).encode()).hexdigest()


def version(name, ver, deps=(), state="published", mojo="1.0.0", subdirs=("linux-64",), native=(), **extra):
    return dict(name=name, version=ver, deps=list(deps), state=state, mojo=mojo, subdirs=subdirs, native=list(native), **extra)


def dep(name, rng):
    return {"name": name, "range": rng}


CLIENT_DEPS = [dep("http_core", ">=1.2,<2"), dep("crypto", "2")]
PACKAGES = {
    "http_client": [
        version("http_client", "0.3.0", CLIENT_DEPS, state="yanked", yank_reason="crashes on empty body"),
        version("http_client", "0.4.0", CLIENT_DEPS),
        version("http_client", "0.4.1", CLIENT_DEPS, mojo="1.1.0"),
        version("http_client", "0.5.0", CLIENT_DEPS),
    ],
    "http_core": [
        version("http_core", "1.2.4"),
        version("http_core", "1.2.5"),
        version("http_core", "1.2.6", state="yanked", yank_reason="breaks keep-alive"),
        version("http_core", "1.4.0"),
        version("http_core", "2.0.0"),
    ],
    "crypto": [
        version("crypto", "2.0.1", subdirs=("linux-64", "osx-arm64"),
                native=[{"id": "crypto", "soname": "libcrypto_native.so.1"}]),
        version("crypto", "2.1.0b1"),
    ],
    "tls": [
        version("tls", "1.0.0", state="tombstoned", tombstone={"date": "2026-10-14", "reason_code": "malware"}),
        version("tls", "1.1.0", [dep("http_core", "~1.2")]),
        version("tls", "1.2.0", state="tombstoned", tombstone={"date": "2026-10-14", "reason_code": "malware"}),
    ],
    # The repodata disagrees with the index about this one's bytes.
    "badsum": [version("badsum", "1.0.0")],
    # Only MAJOR.MINOR.PATCH is read; 1.0 is 1.0.0; the rest are ignored.
    "legacy": [
        version("legacy", "1.0"),
        version("legacy", "1.1.0"),
        version("legacy", "1.2.3.4"),
        version("legacy", "2.0.0-rc1"),
    ],
}
WARNING = "mopm lock: warning: the index lists %s %s, which is not a MAJOR.MINOR.PATCH version; it is ignored\n"
SUBDIRS = ("linux-64", "linux-aarch64", "osx-arm64", "noarch")


def filename(v):
    return "mojo-%s-%s-mojo%s_0.conda" % (v["name"], v["version"], v["mojo"])


def write_registry(root, base):
    """The index files and repodata of PACKAGES under the fake's data directory."""
    repodata = {s: {"info": {"subdir": s}, "packages": {}, "packages.conda": {}, "removed": []} for s in SUBDIRS}
    for name, versions in PACKAGES.items():
        lines = []
        for v in versions:
            fn = filename(v)
            files = []
            for s in v["subdirs"]:
                f = {"filename": fn, "sha256": digest(s, fn), "size": SIZE, "subdir": s}
                if v["state"] != "tombstoned":
                    f["url"] = "%s/channel/%s/%s" % (base, s, fn)
                files.append(f)
                if v["state"] == "published":
                    sha = digest(s, fn) if name != "badsum" else digest(s, "tampered")
                    repodata[s]["packages.conda"][fn] = {
                        "build": "mojo%s_0" % v["mojo"], "build_number": 0,
                        # Deliberately not the index's ranges: never read.
                        "depends": ["mojo-compiler ==%s" % v["mojo"]] + ["mojo-%s >=99" % d["name"] for d in v["deps"]]
                        + ["mojo-zlib_never_read 1"],
                        "name": "mojo-" + name, "sha256": sha, "size": SIZE, "subdir": s, "version": v["version"]}
                else:
                    repodata[s]["removed"].append(fn)
            rec = {"v": 1, "name": name, "version": v["version"], "build": "mojo%s_0" % v["mojo"], "state": v["state"],
                   "published_at": "2026-10-13T12:00:00Z", "requires_mojo": "==" + v["mojo"], "deps": v["deps"],
                   "native": v["native"], "files": files, "manifest_sha256": digest("manifest", fn)}
            for key in ("yank_reason", "tombstone"):
                if key in v:
                    rec[key] = v[key]
            lines.append(json.dumps(rec, sort_keys=True, separators=(",", ":")))
        padded = (name + "____")[:4]
        path = os.path.join(root, "index", padded[:2], padded[2:4], name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("\n".join(lines) + "\n")
    for s, doc in repodata.items():
        path = os.path.join(root, "channel", s, "repodata.json")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        doc["removed"].sort()
        with open(path, "w") as f:
            f.write(json.dumps(doc, sort_keys=True) + "\n")


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


MANIFEST = """[package]
name = "app"
version = "0.1.0"

[toolchain]
mojo = "1.0.0"

[dependencies]
%s
"""

TREE = """app 0.1.0
├── http_client 0.4.0
│   ├── crypto 2.0.1
│   └── http_core 1.2.5
└── tls 1.1.0
    └── http_core 1.2.5
"""


def main(mopm, fake_exe):
    with tempfile.TemporaryDirectory() as work:
        fake = Fake(fake_exe, work)
        try:
            write_registry(fake.dir, fake.base)
            channel = fake.base + "/channel/"
            with open(os.path.join(HERE, "expected.lock")) as f:
                expected = f.read().replace("@CHANNEL@", channel)

            def project(name, deps):
                d = os.path.join(work, name)
                os.makedirs(d)
                with open(os.path.join(d, "mopm.toml"), "w") as f:
                    f.write(MANIFEST % deps)
                return d

            def run(d, *args):
                return subprocess.run([mopm, *args], cwd=d, capture_output=True, text=True, timeout=120)

            def lock_of(d):
                p = os.path.join(d, "mopm.lock")
                return open(p).read() if os.path.exists(p) else None

            reg = ["--registry", fake.base]
            app = project("app", 'http_client = "0.4"\ntls = "1"')

            r = run(app, "tree")
            check("tree without a lock says to lock", r.returncode == 1 and "no mopm.lock; run 'mopm lock'" in r.stderr, r.stderr)

            r = run(app, "lock", *reg)
            check("lock succeeds", r.returncode == 0, r.stdout + r.stderr)
            check("lock warns once about crypto 2.1.0b1 and about nothing else",
                  r.stderr == WARNING % ("crypto", "2.1.0b1"), r.stderr)
            check("the channel is loopback http with a path", re.fullmatch(r"http://127\.0\.0\.1:\d+/channel/", channel) is not None, channel)
            got = lock_of(app)
            check("the lock picks exactly the expected versions and bytes", got == expected,
                  "\n--- got\n%s\n--- want\n%s" % (got, expected))
            check("lock reports what it added",
                  r.stdout == "adding crypto 2.0.1\nadding http_client 0.4.0\nadding http_core 1.2.5\nadding tls 1.1.0\n"
                  "locked 4 packages for mojo 1.0.0\n", r.stdout)

            r = run(app, "tree")
            check("tree draws the locked graph", r.returncode == 0 and r.stdout == TREE, r.stdout + r.stderr)

            r = run(app, "lock", *reg)
            check("locking again changes nothing", r.returncode == 0 and r.stdout == "locked 4 packages for mojo 1.0.0\n"
                  and lock_of(app) == expected, r.stdout + r.stderr)

            # A lock that pins an older http_core keeps it; update moves it.
            old_fn = "mojo-http_core-1.2.4-mojo1.0.0_0.conda"
            new_fn = "mojo-http_core-1.2.5-mojo1.0.0_0.conda"
            pinned = (expected.replace(new_fn, old_fn).replace('"version": "1.2.5"', '"version": "1.2.4"')
                      .replace(digest("linux-64", new_fn), digest("linux-64", old_fn)))
            with open(os.path.join(app, "mopm.lock"), "w") as f:
                f.write(pinned)
            r = run(app, "lock", *reg)
            check("lock keeps a pinned version that still fits", r.returncode == 0 and lock_of(app) == pinned, r.stdout + r.stderr)
            r = run(app, "update", "http_core", *reg)
            check("update moves the named package to the newest that fits",
                  r.returncode == 0 and lock_of(app) == expected and "updating http_core 1.2.4 -> 1.2.5\n" in r.stdout,
                  r.stdout + r.stderr)
            r = run(app, "update", "nosuch", *reg)
            check("update refuses a package the lock does not hold",
                  r.returncode == 1 and "nosuch is not in mopm.lock" in r.stderr, r.stderr)

            for host in ("http://example.com/channel/", "http://127.0.0.2:80/channel/"):
                with open(os.path.join(app, "mopm.lock"), "w") as f:
                    f.write(expected.replace(channel, host))
                for cmd in (["tree"], ["lock", *reg]):
                    r = run(app, *cmd)
                    check("%s refuses a lock whose channel is %s" % (cmd[0], host),
                          r.returncode == 1 and ("channel %s is refused: a channel ends with '/' and is https, or plain http "
                                                 "only to 127.0.0.1, [::1] or localhost with a port" % host) in r.stderr, r.stderr)

            # Versions: 1.0 is 1.0.0; 1.2.3.4 and 2.0.0-rc1 are ignored, with a warning each.
            legacy_warnings = WARNING % ("legacy", "1.2.3.4") + WARNING % ("legacy", "2.0.0-rc1")
            for name, req, want in (("caret", "1", "1.1.0"), ("exact", "=1.0.0", "1.0"), ("below", "<1.1", "1.0")):
                d = project("legacy_" + name, 'legacy = "%s"' % req)
                r = run(d, "lock", *reg)
                text = lock_of(d)
                picked = [(p["version"], p["url"]) for p in json.loads(text)["packages"]] if text else []
                fn = "mojo-legacy-%s-mojo1.0.0_0.conda" % want
                check("legacy %s picks %s and warns about each ignored version" % (req, want),
                      r.returncode == 0 and r.stderr == legacy_warnings and picked == [(want, channel + "linux-64/" + fn)],
                      "exit %d, picked %s, stderr %s" % (r.returncode, picked, r.stderr))
            # Locking with the lock in place reads it back (the version 1.0 too).
            r = run(d, "lock", *reg)
            check("a lock holding legacy 1.0 is read back and kept", r.returncode == 0 and lock_of(d) == text, r.stdout + r.stderr)

            with open(os.path.join(app, "mopm.lock"), "w") as f:
                f.write(expected.replace('"lock_version": 1', '"lock_version": 2'))
            r = run(app, "lock", *reg)
            check("a lock from a newer mopm is refused", r.returncode == 1 and "Update mopm." in r.stderr, r.stderr)

            refusals = [
                ("missing", 'nosuch = "1"', ["nosuch (required by mopm.toml) is not in the registry's index"]),
                ("yanked", 'http_client = "=0.3.0"', ["0.3.0 was yanked: crashes on empty body"]),
                ("taken_down", 'tls = "=1.2.0"', ["1.2.0 was taken down (malware)"]),
                ("compiler", 'http_client = "=0.4.1"', ["is built for mojo 1.0.0", "0.4.1 (mojo 1.1.0)"]),
                ("conflict", 'http_client = "0.4"\nhttp_core = "2"',
                 ["no version of http_core satisfies every requirement on it",
                  ">=1.2,<2 (from http_client 0.4.0)", "2 (from mopm.toml)"]),
                ("no_match", 'http_core = "3"', ["no version of http_core matches 3 (from mopm.toml)"]),
                ("pre_release", 'legacy = ">=2.0.0-rc1"',
                 ["no version of legacy matches >=2.0.0-rc1 (from mopm.toml)", "2.0.0-rc1 (ignored: not MAJOR.MINOR.PATCH)",
                  WARNING % ("legacy", "2.0.0-rc1")]),
                ("four_parts", 'legacy = "=1.2.3"',
                 ["no version of legacy matches =1.2.3 (from mopm.toml)", "1.2.3.4 (ignored: not MAJOR.MINOR.PATCH)",
                  WARNING % ("legacy", "1.2.3.4")]),
                ("badsum", 'badsum = "1"',
                 ["the index says sha256 " + digest("linux-64", filename(PACKAGES["badsum"][0])),
                  "repodata.json says sha256 " + digest("linux-64", "tampered")]),
            ]
            for name, deps, wants in refusals:
                d = project("refuse_" + name, deps)
                r = run(d, "lock", *reg)
                missing = [w for w in wants if w not in r.stderr]
                check("refused: %s" % name, r.returncode == 1 and not missing and lock_of(d) is None,
                      "exit %d, lacks %s: %s" % (r.returncode, missing, r.stderr))
        finally:
            fake.close()
    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: run.py <mopm> <mopm-fake-registry>")
    sys.exit(main(os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])))
