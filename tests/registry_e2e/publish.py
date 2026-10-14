#!/usr/bin/env python3
"""End-to-end tests of `mopm pack` and `mopm publish`.

    python3 -I tests/registry_e2e/publish.py path/to/mopm path/to/mopm-fake-registry

Standard library only. Each check prints `ok   <name>` or `FAIL <name>: ...`;
the exit status is 1 if any failed.

What can go red, and why:
- a publish against mopm-fake-registry must end `published`, and then the
  version, the sparse index and the channel's repodata.json must list it, with
  the sha256 that `mopm pack` printed (so a packer that is not deterministic,
  or an upload that sends other bytes than it packed, fails);
- publishing the same version again must fail with the registry's
  `version_exists` message;
- the client-side refusals (a version that is not exactly MAJOR.MINOR.PATCH, a
  readme over 64 KiB, native libraries, a missing login) must happen before
  any request: they are run against a registry address nothing listens on, so
  a client that went to the network would print "cannot reach" instead;
- the fake does not open archives, so a rejection is exercised against a small
  stand-in registry in this file that answers `rejected` with a code; the same
  stand-in records the PUT it receives, which must carry every header the
  registry named and no Authorization header;
- no token (the API token, the stand-in's token) appears in any output.
"""
import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request

failures = []
DEAD = "http://127.0.0.1:1"  # nothing listens here


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


class Fake:
    def __init__(self, exe, workdir):
        self.proc = subprocess.Popen(
            [exe, "--dir", os.path.join(workdir, "fake"), "--port", "0", "--poll-interval", "1"],
            stdout=subprocess.PIPE, text=True)
        m = re.search(r"listening on (http://\S+)", self.proc.stdout.readline())
        if not m:
            raise SystemExit("the fake registry did not start")
        self.base = m.group(1)
        self.api = self.base + "/api/v1"

    def call(self, method, url, body=None, token=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={"content-type": "application/json"})
        if token:
            req.add_header("authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def control(self, path, body):
        return json.loads(self.call("POST", self.base + "/_fake" + path, body)[1])

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)


class Stub(http.server.BaseHTTPRequestHandler):
    """A registry that rejects every publish with path_not_allowed."""

    protocol_version = "HTTP/1.1"
    put_seen = {}

    def reply(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        return self.rfile.read(int(self.headers.get("content-length", "0")))

    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_port

    def do_GET(self):
        if self.path == "/index/config.json":
            return self.reply(200, {
                "index_version": 1, "stage": "stub", "api_url": self.base() + "/api/v1",
                "channel_url": self.base() + "/channel/", "min_cli_version": "0.0.1"})
        if self.path == "/api/v1/publishes/pub_1":
            Stub.polls += 1
            if Stub.polls < 2:
                return self.reply(200, {"publish_id": "pub_1", "name": "stubpkg", "version": "1.0.0", "status": "validating"})
            return self.reply(200, {
                "publish_id": "pub_1", "name": "stubpkg", "version": "1.0.0", "status": "rejected",
                "rejection_code": "path_not_allowed", "message": "bin/tool is not an allowed path"})
        self.reply(404, {"error": {"code": "not_found", "message": "no", "hint": ""}})

    def do_POST(self):
        body = self.body()
        if self.path == "/api/v1/packages/stubpkg/1.0.0/files":
            Stub.begin = json.loads(body)
            Stub.begin_auth = self.headers.get("authorization")
            return self.reply(200, {
                "upload_id": "upl_1", "put_url": self.base() + "/put/upl_1",
                "put_headers": {"content-length": str(Stub.begin["size"]), "x-stub-checksum": "abc=="},
                "expires_at": "2099-01-01T00:00:00Z"})
        if self.path == "/api/v1/packages/stubpkg/1.0.0/publish":
            Stub.commit = json.loads(body)
            return self.reply(202, {"publish_id": "pub_1", "status_url": "/api/v1/publishes/pub_1"})
        self.reply(404, {"error": {"code": "not_found", "message": "no", "hint": ""}})

    def do_PUT(self):
        body = self.body()
        Stub.put_seen = {"headers": {k.lower(): v for k, v in self.headers.items()}, "size": len(body)}
        self.reply(200, {})

    def log_message(self, *args):
        pass


Stub.polls = 0


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def toml(name, version, extra=""):
    return '[package]\nname = "%s"\nversion = "%s"\n\n[toolchain]\nmojo = "1.0.0"\n\n%s' % (name, version, extra)


def main(mopm, fake_exe):
    with tempfile.TemporaryDirectory() as work:
        fake = Fake(fake_exe, work)
        try:
            def run(*args, env=None):
                e = {k: v for k, v in os.environ.items() if k != "MOPM_TOKEN"}
                e.update(env or {})
                return subprocess.run([mopm, *args], capture_output=True, text=True, timeout=120, env=e)

            pkg = os.path.join(work, "pkg")
            write(os.path.join(pkg, "mopm.toml"), toml("pubdemo", "0.1.0"))
            write(os.path.join(pkg, "README.md"), "# pubdemo\n")
            mojoc = os.path.join(pkg, "pubdemo.mojoc")
            write(mojoc, "not a real mojoc, only bytes\n")
            manifest = os.path.join(pkg, "mopm.toml")
            conf = os.path.join(work, "conf")
            everything = []  # all output, to look for tokens in

            # --- pack
            r = run("pack", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", manifest, "-o", os.path.join(work, "dist"))
            everything.append(r.stdout + r.stderr)
            m = re.search(r"packed (\S+)\n  sha256 ([0-9a-f]{64})\n  size (\d+)\n  manifest_sha256 ([0-9a-f]{64})", r.stdout)
            conda_name = "mojo-pubdemo-0.1.0-mojo1.0.0_0.conda"
            check("pack writes <dir>/noarch/<file>.conda and prints its sha256",
                  r.returncode == 0 and m is not None and m.group(1).endswith("/noarch/" + conda_name)
                  and os.path.exists(m.group(1)), r.stdout + r.stderr)
            packed_sha = m.group(2) if m else ""
            r2 = run("pack", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", manifest, "-o", os.path.join(work, "dist2"))
            m2 = re.search(r"sha256 ([0-9a-f]{64})", r2.stdout)
            check("packing twice gives the same bytes", m2 is not None and m2.group(1) == packed_sha, r2.stdout)
            r = run("pack", "--compiler", "1.0.0", "--mojoc", "linux-64=" + mojoc, "--mojoc", "osx-arm64=" + mojoc,
                    "--manifest", manifest, "-o", os.path.join(work, "dist3"))
            check("pack writes one file per subdir",
                  r.returncode == 0 and os.path.exists(os.path.join(work, "dist3", "linux-64", conda_name))
                  and os.path.exists(os.path.join(work, "dist3", "osx-arm64", conda_name)), r.stdout + r.stderr)
            r = run("pack", "--compiler", "1.0.0", "--mojoc", "win-64=" + mojoc, "--manifest", manifest)
            check("pack refuses an unknown subdir", r.returncode == 2 and "not a subdir" in r.stderr, r.stderr)

            # --- an account that owns the name, and a token that may publish it
            status, body = fake.call("POST", fake.base + "/_fake/session", {"handle": "pub-user"})
            session = json.loads(body)["token"]
            status, body = fake.call("POST", fake.api + "/packages/pubdemo/claim", {}, session)
            check("the name is claimed", status == 201, body.decode())
            status, body = fake.call("POST", fake.api + "/me/tokens", {
                "name": "e2e", "scopes": ["publish"], "packages": ["pubdemo"], "expires_in_days": 1}, session)
            api_token = json.loads(body)["token"] if status == 201 else ""
            check("an API token with the publish scope is made", status == 201 and api_token != "", body.decode())
            secrets = [session, api_token]
            flags = ["--registry", fake.base, "--config-dir", conf]
            pub = ["publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", manifest]

            # --- client-side refusals, before any request
            r = run(*pub, "--registry", DEAD, "--config-dir", conf, "--dry-run")
            everything.append(r.stdout + r.stderr)
            check("--dry-run packs and says what it would send, without a registry",
                  r.returncode == 0 and "would upload noarch/" + conda_name in r.stdout
                  and ("sha256 " + packed_sha) in r.stdout and "would commit mojo-pubdemo 0.1.0" in r.stdout
                  and "would send a readme of 10 bytes" in r.stdout and "dry run: nothing was sent" in r.stdout,
                  r.stdout + r.stderr)

            rc_manifest = os.path.join(work, "rc", "mopm.toml")
            write(rc_manifest, toml("pubdemo", "0.2.0-rc.1"))
            r = run("publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", rc_manifest, "--registry", DEAD, "--config-dir", conf)
            check("a pre-release version is refused before any request",
                  r.returncode == 1 and "must be exactly MAJOR.MINOR.PATCH" in r.stderr and "cannot reach" not in r.stderr, r.stderr)
            short_manifest = os.path.join(work, "short", "mopm.toml")
            write(short_manifest, toml("pubdemo", "1.0"))
            r = run("publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", short_manifest, "--registry", DEAD, "--config-dir", conf)
            check("a version 1.0 is refused before any request",
                  r.returncode == 1 and "MAJOR.MINOR.PATCH" in r.stderr and "cannot reach" not in r.stderr, r.stderr)

            big = os.path.join(work, "big", "README.md")
            write(big, "a" * 65537)
            r = run(*pub, "--registry", DEAD, "--config-dir", conf, "--readme", big)
            check("a readme over 65536 bytes is refused before any request",
                  r.returncode == 1 and "at most 65536 bytes" in r.stderr and "cannot reach" not in r.stderr, r.stderr)
            exact = os.path.join(work, "exact", "README.md")
            write(exact, "a" * 65536)
            r = run(*pub, "--registry", DEAD, "--config-dir", conf, "--readme", exact, "--dry-run")
            check("a readme of exactly 65536 bytes is accepted",
                  r.returncode == 0 and "would send a readme of 65536 bytes" in r.stdout, r.stdout + r.stderr)

            native_manifest = os.path.join(work, "native", "mopm.toml")
            write(native_manifest, toml("pubdemo", "0.1.0", '[native.zlib]\nkind = "shared"\n'))
            r = run("publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", native_manifest, "--registry", DEAD, "--config-dir", conf)
            check("native libraries are refused before any request",
                  r.returncode == 1 and "native libraries are not packed yet" in r.stderr and "cannot reach" not in r.stderr, r.stderr)

            r = run(*pub, *flags)
            check("publishing without a login or MOPM_TOKEN says to log in",
                  r.returncode == 1 and "not logged in to beta; run 'mopm login' or set MOPM_TOKEN" in r.stderr, r.stderr)

            # --- a publish
            r = run(*pub, *flags, env={"MOPM_TOKEN": api_token})
            everything.append(r.stdout + r.stderr)
            check("publish ends with 'published'",
                  r.returncode == 0 and "uploaded " + conda_name in r.stdout and "committed, publish " in r.stdout
                  and "published mojo-pubdemo 0.1.0" in r.stdout, r.stdout + r.stderr)
            status, body = fake.call("GET", fake.api + "/packages/pubdemo/0.1.0")
            check("the version is served", status == 200 and json.loads(body).get("version") == "0.1.0", body.decode())
            status, body = fake.call("GET", fake.base + "/index/pu/bd/pubdemo")
            check("the sparse index lists the version and its sha256",
                  status == 200 and b'"version":"0.1.0"' in body and packed_sha.encode() in body, body.decode())
            status, body = fake.call("GET", fake.base + "/channel/noarch/repodata.json")
            entry = json.loads(body).get("packages.conda", {}).get(conda_name) if status == 200 else None
            check("the channel's repodata.json lists the file with the packed sha256",
                  entry is not None and entry.get("sha256") == packed_sha, body.decode()[:400])
            status, body = fake.call("GET", fake.base + "/channel/noarch/" + conda_name)
            check("the channel serves the file", status == 200 and len(body) == int(m.group(3)) if m else False, str(status))

            r = run(*pub, *flags, env={"MOPM_TOKEN": api_token})
            everything.append(r.stdout + r.stderr)
            check("publishing the same version again fails with version_exists",
                  r.returncode == 1 and "already exists" in r.stderr and "versions are immutable" in r.stderr, r.stdout + r.stderr)

            # --- the login's session is not a publish token
            write(os.path.join(work, "conf2", "credentials.json"),
                  json.dumps({fake.api: {"token": session, "handle": "pub-user"}}))
            next_manifest = os.path.join(work, "next", "mopm.toml")
            write(next_manifest, toml("pubdemo", "0.1.1"))
            r = run("publish", "--compiler", "1.0.0", "--mojoc", mojoc, "--manifest", next_manifest,
                    "--registry", fake.base, "--config-dir", os.path.join(work, "conf2"))
            everything.append(r.stdout + r.stderr)
            check("a stored session token is sent and the registry's refusal is printed",
                  r.returncode == 1 and "does not have the 'publish' scope for 'pubdemo'" in r.stderr, r.stdout + r.stderr)
        finally:
            fake.close()

        # --- a rejection, against the stand-in
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        stub_base = "http://127.0.0.1:%d" % server.server_port
        stub_pkg = os.path.join(work, "stub")
        write(os.path.join(stub_pkg, "mopm.toml"), toml("stubpkg", "1.0.0"))
        stub_mojoc = os.path.join(stub_pkg, "stubpkg.mojoc")
        write(stub_mojoc, "bytes")
        stub_token = "mopm_stub_secret_token"
        e = {k: v for k, v in os.environ.items()}
        e["MOPM_TOKEN"] = stub_token
        r = subprocess.run([mopm, "publish", "--compiler", "1.0.0", "--mojoc", stub_mojoc,
                            "--manifest", os.path.join(stub_pkg, "mopm.toml"),
                            "--registry", stub_base, "--config-dir", os.path.join(work, "conf3")],
                           capture_output=True, text=True, timeout=120, env=e)
        server.shutdown()
        everything.append(r.stdout + r.stderr)
        check("a rejected publish exits 1 and prints the code and message",
              r.returncode == 1 and "rejected: path_not_allowed: bin/tool is not an allowed path" in r.stderr
              and "published" not in r.stdout, r.stdout + r.stderr)
        seen = Stub.put_seen
        check("the PUT carries the headers the registry named, as given",
              seen.get("headers", {}).get("x-stub-checksum") == "abc==", str(seen))
        check("the PUT carries no Authorization header",
              "authorization" not in seen.get("headers", {}), str(seen))
        check("the PUT sends the declared number of bytes", seen.get("size") == Stub.begin.get("size"), str(seen))
        check("begin-upload and commit carry the bearer token",
              Stub.begin_auth == "Bearer " + stub_token, str(Stub.begin_auth))
        check("commit declares the upload id and a manifest_sha256",
              Stub.commit.get("upload_ids") == ["upl_1"] and re.fullmatch(r"[0-9a-f]{64}", Stub.commit.get("manifest_sha256", "")) is not None
              and "readme" not in Stub.commit, str(Stub.commit))

        text = "\n".join(everything)
        check("no token is ever printed", not any(t and t in text for t in secrets + [stub_token]), "a token was printed")
    print("%d failure(s)" % len(failures) if failures else "publish e2e OK")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
