#!/usr/bin/env python3
# SUPERSEDED for the Buck2 build by tests/drivers/login_test.zig (the same checks
# in Zig). This script stays for ci.yml until farm.yml has matched it, and is
# deleted in a later change.
"""End-to-end tests of mopm's registry commands against mopm-fake-registry.

    python3 -I tests/registry_e2e/run.py path/to/mopm path/to/mopm-fake-registry

Standard library only. Each check prints `ok   <name>` or `FAIL <name>: ...`;
the exit status is 1 if any failed. The refusals are checked as well as the
successes, so each check can go red: a registry URL that is not https or
loopback http, a config.json that names one, a login that is denied, a token
that has expired.
"""
import http.server
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import threading
import urllib.request

failures = []


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

    def control(self, path, body):
        req = urllib.request.Request(self.base + "/_fake" + path, data=json.dumps(body).encode(), method="POST",
                                     headers={"content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)


class BadConfig(http.server.BaseHTTPRequestHandler):
    """A registry whose config.json names a plain-http, non-loopback API."""

    def do_GET(self):
        body = json.dumps({
            "index_version": 1, "stage": "beta", "api_url": "http://registry.example/api/v1",
            "channel_url": "https://conda.example/", "min_cli_version": "0.0.1"}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def main(mopm, fake_exe):
    with tempfile.TemporaryDirectory() as work:
        conf = os.path.join(work, "conf")
        fake = Fake(fake_exe, work)
        try:
            flags = ["--registry", fake.base, "--config-dir", conf]

            def run(*args):
                return subprocess.run([mopm, *args], capture_output=True, text=True, timeout=60)

            r = run("whoami", "--registry", "http://example.com", "--config-dir", conf)
            check("a plain-http registry that is not loopback is refused",
                  r.returncode == 1 and "plain http only to 127.0.0.1" in r.stderr, r.stderr)
            r = run("whoami", "--registry", "staging", "--config-dir", conf)
            check("an unknown registry name is refused",
                  r.returncode == 1 and "a registry is prod, gamma, beta, or a URL" in r.stderr, r.stderr)

            server = http.server.HTTPServer(("127.0.0.1", 0), BadConfig)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            r = run("whoami", "--registry", "http://127.0.0.1:%d" % server.server_port, "--config-dir", conf)
            server.shutdown()
            check("a config.json that names a non-loopback http URL is refused",
                  r.returncode == 1 and "plain http only to a loopback host" in r.stderr, r.stderr)

            r = run("whoami", *flags)
            check("whoami before login says so",
                  r.returncode == 1 and "not logged in to beta; run 'mopm login'" in r.stderr, r.stderr)

            # Login, approved on the fake's approval page.
            login = subprocess.Popen([mopm, "login", *flags], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            first = login.stdout.readline()
            m = re.search(r"enter the code (\S+)", first)
            check("login prints a code to enter", m is not None, first)
            if m:
                fake.control("/device", {"user_code": m.group(1), "decision": "approve", "handle": "e2e-user"})
            out, errs = login.communicate(timeout=60)
            out = first + out
            check("an approved login succeeds",
                  login.returncode == 0 and "Logged in to beta as e2e-user." in out, out + errs)
            path = os.path.join(conf, "credentials.json")
            check("the token file exists", os.path.exists(path))
            if os.path.exists(path):
                check("the token file is mode 0600", stat.S_IMODE(os.stat(path).st_mode) == 0o600,
                      oct(stat.S_IMODE(os.stat(path).st_mode)))
                token = json.load(open(path))[fake.base + "/api/v1"]["token"]
                check("the token is a token", token.startswith("mopm_"), "")
                check("the token is never printed", token not in out + errs, "")

            r = run("whoami", *flags)
            check("whoami names the account",
                  r.returncode == 0 and re.search(r"^e2e-user \(GitHub id \d+\) on beta$", r.stdout, re.M) is not None,
                  r.stdout + r.stderr)

            # A session lives 30 days: past that the registry refuses it, and
            # mopm prints the contract's message, hint and request id.
            fake.control("/clock", {"advance_seconds": 31 * 86400})
            r = run("whoami", *flags)
            check("an expired token is reported with hint and request id",
                  r.returncode == 1 and "The token expired at" in r.stderr and "hint: Create a new token." in r.stderr
                  and "request id: fake-" in r.stderr, r.stderr)

            r = run("logout", *flags)
            check("logout removes the token", r.returncode == 0 and "Logged out of beta." in r.stdout
                  and fake.base + "/api/v1" not in json.load(open(path)), r.stdout + r.stderr)
            r = run("logout", *flags)
            check("a second logout says there is nothing to remove",
                  r.returncode == 0 and "Not logged in to beta." in r.stdout, r.stdout)

            # Login, denied.
            login = subprocess.Popen([mopm, "login", *flags], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            m = re.search(r"enter the code (\S+)", login.stdout.readline())
            if m:
                fake.control("/device", {"user_code": m.group(1), "decision": "deny"})
            _, errs = login.communicate(timeout=60)
            check("a denied login fails and says so", login.returncode == 1 and "the login was denied" in errs, errs)
        finally:
            fake.close()
    print("%d failure(s)" % len(failures) if failures else "registry e2e OK")
    return 1 if failures else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2]))
