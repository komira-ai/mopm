#!/usr/bin/env python3
"""Replay the API cases of tests/contract/api against the fake registry.

    python -I tests/contract/replay.py path/to/mopm-fake-registry

For every case marked valid whose operation the fake implements (IMPLEMENTED
below), a recipe puts a fresh fake in the state the case describes and sends
the request. The live answer must have the case's status and, for an error,
its code; and it must pass the same contract checks as the examples
(validate.case_problems: declared status, required headers, body schema,
the error catalogue's templates, Retry-After on rate_limited). A valid case of
an implemented operation with no recipe fails the run, and so does a recipe
whose case no longer exists.

Recipes reach states the public API cannot (a second account, a stale
session, time passing, a server fault) through the fake's /_fake controls,
documented in registry/fake/README.md.
"""
import itertools
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import validate  # noqa: E402

# The operations the fake implements. Every valid case of these must replay.
IMPLEMENTED = {
    "getHealth",
    "startDeviceLogin",
    "pollDeviceLogin",
    "getMe",
    "createToken",
    "listTokens",
    "revokeToken",
}


class Fake:
    """A running mopm-fake-registry on a free port, with a scratch directory."""

    def __init__(self, exe):
        self.dir = tempfile.TemporaryDirectory()
        self.proc = subprocess.Popen(
            [exe, "--dir", self.dir.name, "--port", "0"], stdout=subprocess.PIPE, text=True
        )
        line = self.proc.stdout.readline()
        m = re.search(r"listening on (http://\S+)", line)
        if not m:
            self.close()
            raise SystemExit("the fake registry did not start: %r" % line)
        self.base = m.group(1)
        self.handles = itertools.count(1)

    def close(self):
        self.proc.terminate()
        self.proc.wait(timeout=10)
        self.dir.cleanup()

    def request(self, method, path, body=None, token=None, query=None):
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method)
        if data is not None:
            req.add_header("content-type", "application/json")
        if token:
            req.add_header("authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                status, headers, raw = r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            status, headers, raw = e.code, e.headers, e.read()
        parsed = json.loads(raw) if raw else None
        return status, {k.lower(): v for k, v in headers.items()}, parsed

    def control(self, path, body):
        status, _, out = self.request("POST", "/_fake" + path, body)
        if status != 200:
            raise SystemExit("control %s failed: %s %s" % (path, status, out))
        return out

    def user(self):
        """A new GitHub account; its handle."""
        handle = "user-%d" % next(self.handles)
        self.control("/users", {"handle": handle})
        return handle

    def session(self, handle=None, fresh=True):
        """A session token for `handle` (a new account if None)."""
        return self.control("/session", {"handle": handle or self.user(), "fresh": fresh})["token"]

    def api_token(self, session, **body):
        """Creates an API token with the session; the createToken answer."""
        req = {"name": "ci", "scopes": ["publish"], "packages": ["http_client"], "expires_in_days": 30}
        req.update(body)
        status, _, out = self.request("POST", "/api/v1/me/tokens", req, session)
        if status != 201:
            raise SystemExit("could not create a token: %s %s" % (status, out))
        return out

    def device_start(self):
        _, _, out = self.request("POST", "/api/v1/auth/device", {"client": "mopm 0.0.1"})
        return out


def step(op, path=None, query=None, body=None, token=None, auth=None, check=None, after=None, malformed=False):
    """What a recipe sends. `auth` names the security scheme `token` stands for;
    `check(body)` is an extra assertion; `after()` undoes a control."""
    return dict(op=op, path=path or {}, query=query or {}, body=body, token=token, auth=auth,
                check=check, after=after, malformed=malformed)


def read_only(f):
    f.control("/mode", {"read_only": True})
    return step("getHealth", check=lambda b: b["read_only"] is True,
                after=lambda: f.control("/mode", {"read_only": False}))


def poll(f, decision=None, expire=False):
    start = f.device_start()
    if decision:
        f.control("/device", {"user_code": start["user_code"], "decision": decision, "handle": f.user()})
    if expire:
        f.control("/clock", {"advance_seconds": 601})
    return step("pollDeviceLogin", body={"device_code": start["device_code"]})


def expired_token(f):
    t = f.api_token(f.session(), expires_in_days=1)["token"]
    f.control("/clock", {"advance_seconds": 2 * 86400})
    return step("getMe", token=t, auth="userToken")


def revoked_token(f):
    s = f.session()
    created = f.api_token(s)
    status, _, _ = f.request("DELETE", "/api/v1/me/tokens/" + created["id"], token=s)
    assert status == 204, status
    return step("getMe", token=created["token"], auth="userToken")


def list_tokens(f):
    s = f.session()
    f.api_token(s)
    return step("listTokens", token=s, auth="freshSession",
                check=lambda b: len(b["tokens"]) == 1 and all("token" not in t for t in b["tokens"]))


def revoke(f):
    s = f.session()
    created = f.api_token(s)

    def gone(_):
        status, _, body = f.request("GET", "/api/v1/me/tokens", token=s)
        return status == 200 and body["tokens"] == []

    return step("revokeToken", path={"token_id": created["id"]}, token=s, auth="freshSession", check=gone)


TOKEN_BODY = {"name": "ci", "scopes": ["publish", "yank"], "packages": ["http_client", "http_core"], "expires_in_days": 90}

RECIPES = {
    ("getHealth", "prod is up"): lambda f: step("getHealth"),
    ("getHealth", "beta in read-only mode"): read_only,
    ("startDeviceLogin", "start login"): lambda f: step("startDeviceLogin", body={"client": "mopm 0.0.1"}),
    ("pollDeviceLogin", "poll while pending"): lambda f: poll(f),
    ("pollDeviceLogin", "poll approved"): lambda f: poll(f, "approve"),
    ("pollDeviceLogin", "poll denied"): lambda f: poll(f, "deny"),
    ("pollDeviceLogin", "poll expired"): lambda f: poll(f, expire=True),
    ("pollDeviceLogin", "error device_code_unknown"):
        lambda f: step("pollDeviceLogin", body={"device_code": "0" * 40}),
    ("getMe", "error token_missing"): lambda f: step("getMe"),
    ("getMe", "error token_unknown"): lambda f: step("getMe", token="mopm_" + "a" * 32, auth="userToken"),
    ("getMe", "error token_expired"): expired_token,
    ("getMe", "error token_revoked"): revoked_token,
    ("getMe", "whoami"): lambda f: step("getMe", token=f.session(), auth="userToken"),
    ("createToken", "error stale_session"):
        lambda f: step("createToken", body=TOKEN_BODY, token=f.session(fresh=False), auth="freshSession"),
    ("createToken", "create a token for named packages"):
        lambda f: step("createToken", body=TOKEN_BODY, token=f.session(), auth="freshSession",
                       check=lambda b: b["packages"] == ["http_client", "http_core"]),
    ("createToken", "create a token for all current packages"):
        lambda f: step("createToken", body=dict(TOKEN_BODY, packages="all_current"), token=f.session(),
                       auth="freshSession", check=lambda b: b["packages"] == "all_current"),
    ("listTokens", "list tokens never returns a secret"): list_tokens,
    ("revokeToken", "error token_not_found"):
        lambda f: step("revokeToken", path={"token_id": "tok-000000000000"}, token=f.session(), auth="freshSession"),
    ("revokeToken", "revoke a token"): revoke,
}


def main(exe):
    spec = validate.yaml.safe_load((validate.SPEC / "api" / "openapi.yaml").read_text(encoding="utf-8"))
    ops = validate.operations(spec)
    catalogue = spec["x-mopm-errors"]
    cases = []
    for path in sorted((HERE / "api").glob("*.json")):
        cases += json.loads(path.read_text(encoding="utf-8"))["cases"]
    wanted = [c for c in cases if c.get("expect", "valid") == "valid" and c["operationId"] in IMPLEMENTED]
    failures = []
    known = {(c["operationId"], c["name"]) for c in wanted}
    for key in sorted(set(RECIPES) - known):
        failures.append("recipe %s / %r has no valid case in tests/contract/api" % key)

    fake = Fake(exe)
    try:
        for case in wanted:
            key = (case["operationId"], case["name"])
            if key not in RECIPES:
                failures.append("no recipe for %s / %r" % key)
                continue
            s = RECIPES[key](fake)
            template, method = ops[s["op"]][0], ops[s["op"]][1]
            status, headers, body = fake.request(
                method.upper(), "/api/v1" + template.format(**s["path"]), s["body"], s["token"], s["query"]
            )
            live = {
                "operationId": s["op"],
                "request": {"path": s["path"], "query": s["query"]},
                "response": {"status": status, "headers": headers},
                "malformed_request": s["malformed"],
            }
            if s["body"] is not None:
                live["request"]["body"] = s["body"]
            if s["auth"]:
                live["request"]["auth"] = s["auth"]
            if body is not None:
                live["response"]["body"] = body
            problems = validate.case_problems(spec, ops, catalogue, live)
            want = case["response"]["status"]
            if status != want:
                problems.append("status %s, the case has %s" % (status, want))
            elif want >= 400:
                want_code = case["response"]["body"]["error"]["code"]
                got_code = (body or {}).get("error", {}).get("code")
                if got_code != want_code:
                    problems.append("error %s, the case has %s" % (got_code, want_code))
            if not problems and s["check"] and not s["check"](body):
                problems.append("the recipe's check failed on %s" % json.dumps(body)[:300])
            if s["after"]:
                s["after"]()
            for p in problems:
                failures.append("%s / %r: %s" % (key[0], key[1], p))
    finally:
        fake.close()

    for f in failures:
        print("FAIL " + f)
    print("replayed %d cases of %d operations against the fake" % (len(wanted), len(IMPLEMENTED)))
    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    print("replay OK")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1]))
