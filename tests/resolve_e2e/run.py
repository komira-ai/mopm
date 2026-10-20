#!/usr/bin/env python3
"""End-to-end tests of `mopm lock`, `mopm update`, `mopm tree`, `mopm add` and
`mopm remove` against mopm-fake-registry.

SUPERSEDED by //:resolve_e2e (tests/drivers/resolve_e2e_test.zig), the Zig port
the Buck2 build runs: the build has no Python. This script stays for ci.yml
until farm.yml has matched it, and is deleted then.

    python3 -I tests/resolve_e2e/run.py path/to/mopm path/to/mopm-fake-registry

Needs the packages in tests/contract/requirements.txt (jsonschema), for the
lock schema check. The fake registry is started on a free port; the
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
naming a plain-http channel on any other host is refused. The lock written is
compared byte for byte with expected.lock and also validated against
spec/lock.schema.json plus the rules of spec/lock.md, with the validator the
contract job uses (tests/contract/validate.py). So that the schema check is
shown to be able to fail, the same lock with its channel moved to plain http
on a non-loopback host, or to loopback http without a port, must be refused.

`mopm add` and `mopm remove` edit a project whose mopm.toml starts as
add_before.toml; the file is compared byte for byte with add_after.toml and
remove_after.toml (see add_remove below).
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "tests", "contract"))

from jsonschema import Draft202012Validator  # noqa: E402

import validate  # noqa: E402

LOCK_SCHEMA = Draft202012Validator(validate.load_json(validate.SPEC / "lock.schema.json"))
SIZE = 4096
failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


def lock_contract_problems(text):
    """What tests/contract/validate.py finds wrong with a lock: schema, then rules."""
    doc = json.loads(text)
    found = [e.message[:160] for e in LOCK_SCHEMA.iter_errors(doc)]
    return found or validate.lock_problems(doc)


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


def read(path):
    with open(path, "rb") as f:
        return f.read().decode()


def file_or_none(path):
    return read(path) if os.path.exists(path) else None


def golden_diff(got, want):
    """'' when `got` is `want` byte for byte, else what differs."""
    if got == want:
        return ""
    return "\n--- got\n%s\n--- want\n%s" % (got, want)


def unchanged(d, toml_before, lock_before):
    """What changed in mopm.toml or mopm.lock of `d`: '' when neither did (a lock that was absent must stay absent)."""
    found = []
    if file_or_none(os.path.join(d, "mopm.toml")) != toml_before:
        found.append("mopm.toml changed")
    if file_or_none(os.path.join(d, "mopm.lock")) != lock_before:
        found.append("mopm.lock was written" if lock_before is None else "mopm.lock changed")
    return "; ".join(found)


def locked_versions(d):
    text = file_or_none(os.path.join(d, "mopm.lock"))
    return {p["name"]: p["version"] for p in json.loads(text)["packages"]} if text else {}


def add_remove(work, run, reg):
    """`mopm add` and `mopm remove`: byte-exact goldens of mopm.toml, the lock
    each writes, and the refusals, which must leave both files as they were.

    Two can-fail proofs run here too, so CI shows each comparison going red
    on the defect it guards against: golden_diff refuses add_after.toml with
    its comments or its spacing lost (a writer that re-serialises the
    manifest), and unchanged() refuses a project whose mopm.toml holds the
    edit of an add that failed to resolve (a writer that writes mopm.toml
    before resolving)."""
    before = read(os.path.join(HERE, "add_before.toml"))
    after_add = read(os.path.join(HERE, "add_after.toml"))
    after_remove = read(os.path.join(HERE, "remove_after.toml"))
    d = os.path.join(work, "edit")
    os.makedirs(d)
    toml = os.path.join(d, "mopm.toml")
    with open(toml, "w") as f:
        f.write(before)

    lost = [("comments", re.sub(r"[ \t]*#[^\n]*", "", after_add)),
            ("spacing", re.sub(r"[ \t]*=[ \t]*", " = ", re.sub(r"  +", " ", after_add)))]
    for what, bad in lost:
        check("can fail: the add golden refuses the file with its %s lost" % what,
              bad != after_add and golden_diff(bad, after_add) != "", "the golden does not hold any %s" % what)

    # No requirement: the newest version that fits, as ^X.Y.Z, after the last entry.
    r = run(d, "add", "http_client", *reg)
    want = after_add.replace('http_core = "^1.2.5"\n', "")
    check("add writes ^ the newest version that fits, after the table's last entry, every other byte kept",
          r.returncode == 0 and not golden_diff(read(toml), want), r.stderr + golden_diff(read(toml), want))
    v = locked_versions(d)
    check("add locks the added package and what it pulls in",
          v.get("http_client") == "0.5.0" and v.get("crypto") == "2.0.1" and "adding http_client 0.5.0\n" in r.stdout,
          json.dumps(v) + r.stdout)

    # The newest http_core in the index is 2.0.0; tls's "~1.2" lets only 1.2.x fit.
    r = run(d, "add", "http_core", "--dev", *reg)
    check("add --dev writes [dev-dependencies]; the version is the newest that fits, not the newest (golden add_after.toml)",
          r.returncode == 0 and not golden_diff(read(toml), after_add), r.stderr + golden_diff(read(toml), after_add))

    r = run(d, "add", "tls@~1.1", *reg)
    want = after_add.replace('tls   =   "1"', 'tls   =   "~1.1"')
    check("add of an existing dependency replaces its value in place (spacing and comment kept)",
          r.returncode == 0 and not golden_diff(read(toml), want) and locked_versions(d).get("tls") == "1.1.0",
          r.stderr + golden_diff(read(toml), want))

    r = run(d, "remove", "legacy", *reg)
    check("remove of the middle key of a table takes its line only (golden remove_after.toml)",
          r.returncode == 0 and not golden_diff(read(toml), after_remove), r.stderr + golden_diff(read(toml), after_remove))
    check("remove takes the package out of the lock", "legacy" not in locked_versions(d) and "removing legacy 1.1.0\n" in r.stdout,
          json.dumps(locked_versions(d)) + r.stdout)

    r = run(d, "remove", "http_client", *reg)
    v = locked_versions(d)
    check("remove drops what only the removed package pulled in, and keeps what others need",
          r.returncode == 0 and "http_client" not in v and "crypto" not in v and v.get("http_core") == "1.2.5"
          and v.get("tls") == "1.1.0" and read(toml) == after_remove.replace('http_client = "^0.5.0"\n', ""),
          r.stderr + json.dumps(v) + read(toml))

    toml_now, lock_now = read(toml), read(os.path.join(d, "mopm.lock"))
    for args, wants in ((["remove", "nosuch"], "nosuch is not a dependency: [dependencies] of mopm.toml does not name it"),
                        (["remove", "http_core"], "http_core is not a dependency: [dependencies] of mopm.toml does not name it"),
                        (["add", "nosuch"], "nosuch (required by mopm.toml) is not in the registry's index"),
                        (["add", "tls@3"], "no version of tls matches 3 (from mopm.toml)")):
        r = run(d, *args, *reg)
        changed = unchanged(d, toml_now, lock_now)
        check("refused, both files unchanged: mopm %s" % " ".join(args),
              r.returncode == 1 and wants in r.stderr and not changed, "exit %d, %s, stderr %s" % (r.returncode, changed, r.stderr))

    # A project with no lock: a failed add writes neither file.
    fresh = os.path.join(work, "edit_fresh")
    os.makedirs(fresh)
    with open(os.path.join(fresh, "mopm.toml"), "w") as f:
        f.write(before)
    r = run(fresh, "add", "http_core@3", *reg)
    changed = unchanged(fresh, before, None)
    check("an add that does not resolve leaves mopm.toml byte-identical and writes no lock",
          r.returncode == 1 and "no version of http_core matches 3" in r.stderr and not changed,
          "exit %d, %s, stderr %s" % (r.returncode, changed, r.stderr))
    # The defect that check guards against, planted: the edit written before resolving.
    planted = os.path.join(work, "edit_planted")
    os.makedirs(planted)
    with open(os.path.join(planted, "mopm.toml"), "w") as f:
        f.write(before.replace('legacy = "1"\n', 'legacy = "1"\nhttp_core = "3"\n'))
    check("can fail: the unchanged check refuses mopm.toml written before resolving",
          unchanged(planted, before, None) == "mopm.toml changed", unchanged(planted, before, None) or "accepted")

    # A path dependency: { path = "<dir>" }, locked with source path.
    with_path = os.path.join(work, "edit_path")
    os.makedirs(os.path.join(with_path, "local"))
    with open(os.path.join(with_path, "mopm.toml"), "w") as f:
        f.write(before)
    with open(os.path.join(with_path, "local", "mopm.toml"), "w") as f:
        f.write('[package]\nname = "local"\nversion = "0.3.0"\n')
    r = run(with_path, "add", "local", "--path", "local", *reg)
    want = before.replace('legacy = "1"\n', 'legacy = "1"\nlocal = { path = "local" }\n')
    got = read(os.path.join(with_path, "mopm.toml"))
    check("add --path writes { path = \"<dir>\" } and locks it as a path dependency",
          r.returncode == 0 and not golden_diff(got, want) and locked_versions(with_path).get("local") == "0.3.0",
          r.stderr + golden_diff(got, want))


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
            found = lock_contract_problems(got) if got else ["no lock written"]
            check("the lock written passes spec/lock.schema.json and the lock rules", not found, "; ".join(found))
            for bad in ("http://example.com/channel/", "http://127.0.0.1/channel/"):
                found = lock_contract_problems(got.replace(channel, bad)) if got else []
                check("the schema check refuses the same lock with channel %s" % bad, bool(found), "accepted")
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

            # Path dependencies: locked as source = path, at the version their
            # own mopm.toml gives, with no file; their own requirements resolve.
            withpath = project("withpath", 'local = { path = "local" }')
            def package(d, name, ver, deps):
                os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, "mopm.toml"), "w") as f:
                    f.write('[package]\nname = "%s"\nversion = "%s"\n\n[dependencies]\n%s\n' % (name, ver, deps))
            package(os.path.join(withpath, "local"), "local", "0.3.0", 'tls = "1"\nutil = { path = "../util" }')
            package(os.path.join(withpath, "util"), "util", "0.0.7", "")
            r = run(withpath, "lock", *reg)
            text = lock_of(withpath) or ""
            entries = {p["name"]: p for p in json.loads(text)["packages"]} if text else {}
            check("a path dependency is locked with source path, its version and path, and no file",
                  r.returncode == 0
                  and entries.get("local") == {"name": "local", "version": "0.3.0", "source": "path", "path": "local", "deps": ["tls", "util"]}
                  and entries.get("util") == {"name": "util", "version": "0.0.7", "source": "path", "path": "util"},
                  "exit %d %s %s" % (r.returncode, r.stderr, json.dumps(entries)))
            check("a path dependency's own requirements are resolved from the registry",
                  entries.get("tls", {}).get("version") == "1.1.0" and entries.get("http_core", {}).get("version") == "1.2.5"
                  and sorted(entries) == ["http_core", "local", "tls", "util"], json.dumps(entries))
            check("lock reports the path dependencies", r.stdout ==
                  "adding http_core 1.2.5\nadding local 0.3.0\nadding tls 1.1.0\nadding util 0.0.7\nlocked 4 packages for mojo 1.0.0\n", r.stdout)
            r = run(withpath, "tree")
            check("tree draws path dependencies with their paths", r.returncode == 0 and r.stdout ==
                  "app 0.1.0\n└── local 0.3.0 (local)\n    ├── tls 1.1.0\n    │   └── http_core 1.2.5\n    └── util 0.0.7 (util)\n",
                  r.stdout + r.stderr)
            package(os.path.join(withpath, "local"), "local", "0.3.1", 'tls = "1"\nutil = { path = "../util" }')
            r = run(withpath, "lock", *reg)
            check("a path dependency's new version is locked",
                  r.returncode == 0 and "updating local 0.3.0 -> 0.3.1\n" in r.stdout and '"version": "0.3.1"' in (lock_of(withpath) or ""),
                  r.stdout + r.stderr)
            package(os.path.join(withpath, "util"), "notutil", "0.0.7", "")
            r = run(withpath, "lock", *reg)
            check("a path dependency whose mopm.toml names another package is refused",
                  r.returncode == 1 and "util/mopm.toml names the package notutil, but local/mopm.toml calls it util" in r.stderr, r.stderr)
            nodir = project("nopath", 'gone = { path = "gone" }')
            r = run(nodir, "lock", *reg)
            check("a path dependency without a mopm.toml is refused", r.returncode == 1 and "no gone/mopm.toml" in r.stderr
                  and lock_of(nodir) is None, r.stderr)

            add_remove(work, run, reg)

            with open(os.path.join(app, "mopm.lock"), "w") as f:
                f.write(expected.replace('"lock_version": 1', '"lock_version": 99'))
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
