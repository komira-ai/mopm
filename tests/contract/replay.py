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
import base64
import hashlib
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
    "exchangeOidcToken",
    "searchPackages",
    "getPackage",
    "claimPackage",
    "listVersions",
    "listOwners",
    "inviteOwner",
    "removeOwner",
    "listInvitations",
    "acceptInvitation",
    "beginUpload",
    "commitPublish",
    "getPublishStatus",
    "setYanked",
    "getVersion",
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
        self.names = itertools.count(1)
        self.ids = {}

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
        self.ids[handle] = self.control("/users", {"handle": handle})["github_id"]
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

    def name(self, prefix="pkg"):
        """A package name no recipe has used."""
        return "%s%d" % (prefix, next(self.names))

    def claim(self, session, name, **body):
        status, _, out = self.request("POST", "/api/v1/packages/%s/claim" % name, body or None, session)
        if status != 201:
            raise SystemExit("could not claim %s: %s %s" % (name, status, out))
        return name

    def invite(self, session, name, handle):
        """Invites `handle` to own `name`; the invitation id."""
        status, _, out = self.request("PUT", "/api/v1/packages/%s/owners" % name, {"handle": handle}, session)
        if status != 202:
            raise SystemExit("could not invite %s: %s %s" % (handle, status, out))
        return out["id"]

    def device_start(self):
        _, _, out = self.request("POST", "/api/v1/auth/device", {"client": "mopm 0.0.1"})
        return out


def step(op, path=None, query=None, body=None, token=None, auth=None, check=None, after=None, malformed=False,
         raw_path=None):
    """What a recipe sends. `auth` names the security scheme `token` stands for;
    `check(body)` is an extra assertion; `after()` undoes a control; `raw_path`
    sends a GET to that path instead of the operation's own."""
    return dict(op=op, path=path or {}, query=query or {}, body=body, token=token, auth=auth,
                check=check, after=after, malformed=malformed, raw_path=raw_path)


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
        lambda f: step("revokeToken", path={"token_id": "tok-unknown"}, token=f.session(), auth="freshSession"),
    ("revokeToken", "revoke a token"): revoke,
}


def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def jwt(repository):
    """A CI identity token as the fake reads it: three base64url parts, the
    middle one carrying the repository claim."""
    claims = json.dumps({"repository": repository, "workflow_ref": repository + "/.github/workflows/release.yml"})
    return ".".join([b64(b'{"alg":"RS256"}'), b64(claims.encode()), b64(b"signature")])


def oidc(f, trusted=True):
    owner = f.session()
    name = f.claim(owner, f.name())
    if trusted:
        f.control("/trusted", {"name": name, "repository": "octo/" + name})
    return step("exchangeOidcToken", body={"jwt": jwt("octo/" + name), "name": name, "version": "0.4.0"},
                check=(lambda b: b["name"] == name) if trusted else None)


def fault(f, op, code, **kw):
    f.control("/fault", {"operation": op, "code": code})
    return step(op, **kw)


def route_not_found(f):
    """The real thing: a path the API does not have, not a planted fault. The case's operation is only its carrier."""
    return step("getHealth", raw_path="/api/v1/no_such_operation")


def search_prefix(f):
    s = f.session()
    prefix = f.name("srch")
    for suffix in ("b", "a"):
        f.claim(s, prefix + suffix)
    return step("searchPackages", query={"q": prefix, "sort": "name", "limit": 20},
                check=lambda b: [p["name"] for p in b["packages"]] == [prefix + "a", prefix + "b"]
                and b["next_cursor"] is None)


def search_last_page(f):
    s = f.session()
    prefix = f.name("page")
    for suffix in ("a", "b"):
        f.claim(s, prefix + suffix)
    _, _, first = f.request("GET", "/api/v1/packages", query={"q": prefix, "limit": 1})
    cursor = first["next_cursor"]
    return step("searchPackages", query={"q": prefix, "limit": 1, "cursor": cursor},
                check=lambda b: b["next_cursor"] is None and b["packages"][0]["name"] == prefix + "b"
                and b["packages"][0]["latest"] is None)


def claimed(f):
    """A package claimed by a new account: (owner handle, owner session, name)."""
    handle = f.user()
    s = f.session(handle)
    return handle, s, f.claim(s, f.name())


def claim_step(f, name, **kw):
    return step("claimPackage", path={"name": name}, token=f.session(), auth="userToken", **kw)


def similar(f, confirm):
    _, _, name = claimed(f)
    body = {"confirm_similar": True} if confirm else None
    return claim_step(f, name + "s", body=body)


def invite(f, handle_of):
    owner, s, name = claimed(f)
    handle = handle_of(f, owner)
    return step("inviteOwner", path={"name": name}, body={"handle": handle}, token=s, auth="freshSession")


def not_owner(f):
    _, _, name = claimed(f)
    return step("inviteOwner", path={"name": name}, body={"handle": f.user()}, token=f.session(), auth="freshSession")


def invited(f):
    """A package and a pending invitation of a new account: (owner session, name, invitee, invitation id)."""
    _, s, name = claimed(f)
    invitee = f.user()
    return s, name, invitee, f.invite(s, name, invitee)


def accept(f, expire=False):
    _, name, invitee, inv = invited(f)
    if expire:
        f.control("/clock", {"advance_seconds": 8 * 86400})
    return step("acceptInvitation", path={"invitation_id": inv}, token=f.session(invitee), auth="userToken",
                check=None if expire else (lambda b: invitee in [o["handle"] for o in b["owners"]]))


def list_invitations(f):
    _, name, invitee, _ = invited(f)
    return step("listInvitations", token=f.session(invitee), auth="userToken",
                check=lambda b: [i["name"] for i in b["invitations"]] == [name])


def remove_owner(f):
    s, name, invitee, inv = invited(f)
    status, _, _ = f.request("POST", "/api/v1/me/invitations/%s/accept" % inv, token=f.session(invitee))
    assert status == 200, status

    def one_left(_):
        _, _, body = f.request("GET", "/api/v1/packages/%s/owners" % name)
        return len(body["owners"]) == 1

    return step("removeOwner", path={"name": name, "github_id": f.ids[invitee]}, token=s, auth="freshSession",
                check=one_left)


def last_owner(f):
    owner, s, name = claimed(f)
    return step("removeOwner", path={"name": name, "github_id": f.ids[owner]}, token=s, auth="freshSession")


RECIPES.update({
    ("exchangeOidcToken", "exchange a CI identity token"): oidc,
    ("exchangeOidcToken", "error oidc_token_invalid"):
        lambda f: step("exchangeOidcToken", body={"jwt": "not-a-jwt", "name": "http_client", "version": "0.4.0"}),
    ("exchangeOidcToken", "error oidc_not_trusted"): lambda f: oidc(f, trusted=False),
    ("searchPackages", "error invalid_request"): lambda f: step("searchPackages", query={"cursor": "garbage"}),
    ("searchPackages", "error rate_limited"): lambda f: fault(f, "searchPackages", "rate_limited", query={"q": "http"}),
    ("searchPackages", "error unavailable"): lambda f: fault(f, "searchPackages", "unavailable"),
    ("getHealth", "error route_not_found"): route_not_found,
    ("searchPackages", "search by prefix"): search_prefix,
    ("searchPackages", "search, last page, claimed package with no version"): search_last_page,
    ("getPackage", "error invalid_name"):
        lambda f: step("getPackage", path={"name": "Http-Client"}, malformed=True),
    ("getPackage", "error package_not_found"): lambda f: step("getPackage", path={"name": f.name("nosuch")}),
    ("getPackage", "error internal_error"):
        lambda f: fault(f, "getPackage", "internal_error", path={"name": claimed(f)[2]}),
    ("getPackage", "package info"):
        lambda f: (lambda c: step("getPackage", path={"name": c[2]},
                                  check=lambda b: [o["handle"] for o in b["owners"]] == [c[0]] and b["state"] == "claimed"))(claimed(f)),
    ("getPackage", "package info with homepage, keywords and the latest readme"):
        lambda f: (lambda c: step("getPackage", path={"name": c[2]}))(claimed(f)),
    ("claimPackage", "error name_reserved"): lambda f: claim_step(f, "mopm"),
    ("claimPackage", "error name_taken"): lambda f: claim_step(f, claimed(f)[2]),
    ("claimPackage", "error name_too_similar"): lambda f: similar(f, confirm=False),
    ("claimPackage", "claim with no body"): lambda f: claim_step(f, f.name()),
    ("claimPackage", "claim a similar name on purpose"): lambda f: similar(f, confirm=True),
    ("listVersions", "list versions"): lambda f: step("listVersions", path={"name": claimed(f)[2]}),
    ("listOwners", "list owners"): lambda f: step("listOwners", path={"name": claimed(f)[2]}),
    ("inviteOwner", "error not_owner"): not_owner,
    ("inviteOwner", "error user_not_found"): lambda f: invite(f, lambda f, owner: "ghost-nobody"),
    ("inviteOwner", "error already_owner"): lambda f: invite(f, lambda f, owner: owner),
    ("inviteOwner", "invite an owner"): lambda f: invite(f, lambda f, owner: f.user()),
    ("removeOwner", "error owner_not_found"):
        lambda f: (lambda c: step("removeOwner", path={"name": c[2], "github_id": 1}, token=c[1], auth="freshSession"))(claimed(f)),
    ("removeOwner", "error last_owner"): last_owner,
    ("removeOwner", "remove an owner"): remove_owner,
    ("listInvitations", "list invitations"): list_invitations,
    ("acceptInvitation", "error invitation_not_found"):
        lambda f: step("acceptInvitation", path={"invitation_id": "inv-none"}, token=f.session(), auth="userToken"),
    ("acceptInvitation", "error invitation_expired"): lambda f: accept(f, expire=True),
    ("acceptInvitation", "accept an invitation"): accept,
})


# ---------------------------------------------------------------------------
# Publishing
# ---------------------------------------------------------------------------

BUILD = "mojo1.0.0_0"


class Release:
    """An owner, a token with the publish and yank scopes for a fresh
    package, and helpers that publish versions of it."""

    def __init__(self, f):
        self.f = f
        self.owner, self.session, self.name = claimed(f)
        self.token = f.api_token(self.session, scopes=["publish", "yank"], packages=[self.name])["token"]

    def filename(self, version):
        return "mojo-%s-%s-%s.conda" % (self.name, version, BUILD)

    def begin_body(self, version, data, subdir="linux-64", filename=None):
        return {"subdir": subdir, "filename": filename or self.filename(version), "size": len(data),
                "sha256": hashlib.sha256(data).hexdigest()}

    def upload(self, version, data=b"conda bytes", put=True, **kw):
        """Begins an upload and, unless put is False, PUTs the bytes; the upload id."""
        status, _, out = self.f.request("POST", "/api/v1/packages/%s/%s/files" % (self.name, version),
                                        self.begin_body(version, data, **kw), self.token)
        assert status == 200, (status, out)
        if put:
            req = urllib.request.Request(out["put_url"], data=data, method="PUT", headers=out["put_headers"])
            with urllib.request.urlopen(req, timeout=10) as r:
                assert r.status == 200, r.status
        return out["upload_id"]

    def commit_body(self, *upload_ids):
        return {"upload_ids": list(upload_ids), "manifest_sha256": hashlib.sha256(b"manifest").hexdigest()}

    def commit(self, version, *upload_ids):
        status, _, out = self.f.request("POST", "/api/v1/packages/%s/%s/publish" % (self.name, version),
                                        self.commit_body(*upload_ids), self.token)
        assert status == 202, (status, out)
        return out["publish_id"]

    def poll(self, publish_id, times):
        out = None
        for _ in range(times):
            status, _, out = self.f.request("GET", "/api/v1/publishes/" + publish_id, token=self.token)
            assert status == 200, (status, out)
        return out

    def publish(self, version, data=b"conda bytes"):
        pid = self.commit(version, self.upload(version, data))
        out = self.poll(pid, 4)
        assert out["status"] == "published", out
        return pid

    def path(self, version):
        return {"name": self.name, "version": version}


def begin_upload(f, size=None, read_only=False):
    r = Release(f)
    body = r.begin_body("0.4.0", b"conda bytes")
    if size:
        body["size"] = size
    after = None
    if read_only:
        f.control("/mode", {"read_only": True})
        after = lambda: f.control("/mode", {"read_only": False})  # noqa: E731
    return step("beginUpload", path=r.path("0.4.0"), body=body, token=r.token, auth="publishToken",
                after=after, malformed=size is not None)


def begin_upload_version(f, version):
    """A well-formed begin for a version that is not MAJOR.MINOR.PATCH."""
    r = Release(f)
    return step("beginUpload", path=r.path(version), body=r.begin_body(version, b"conda bytes"), token=r.token,
                auth="publishToken", malformed=True)


def commit_version(f, version):
    r = Release(f)
    return step("commitPublish", path=r.path(version), body=r.commit_body("upl-none"), token=r.token,
                auth="publishToken", malformed=True)


def project_full(f):
    """The package already holds 11 bytes and may hold 15: a file of 5 more does not fit."""
    r = Release(f)
    f.control("/limits", {"project_bytes": 15})
    r.publish("0.3.0", b"conda bytes")
    return step("beginUpload", path=r.path("0.4.0"), body=r.begin_body("0.4.0", b"12345"), token=r.token,
                auth="publishToken")


def commit(f, kind):
    r = Release(f)
    if kind == "not uploaded":
        up = r.upload("0.4.0", put=False)
    elif kind == "exists":
        # 1.0.0 is published; the same version again is refused.
        r.publish("1.0.0")
        up = r.upload("1.0.0")
        return step("commitPublish", path=r.path("1.0.0"), body=r.commit_body(up), token=r.token,
                    auth="publishToken")
    elif kind == "used":
        # The version is still pending, and a different set reuses an upload.
        first = r.upload("0.4.0")
        second = r.upload("0.4.0", subdir="osx-arm64")
        r.commit("0.4.0", first)
        return step("commitPublish", path=r.path("0.4.0"), body=r.commit_body(first, second), token=r.token,
                    auth="publishToken")
    elif kind == "display":
        up = r.upload("0.4.0")
        body = r.commit_body(up)
        body.update({"description": "HTTP/1.1 client", "license": "MIT OR Apache-2.0", "keywords": ["http", "client"],
                     "repository": "https://github.com/example/http_client", "homepage": "https://example.com/http_client"})
        return step("commitPublish", path=r.path("0.4.0"), body=body, token=r.token, auth="publishToken")
    else:
        up = r.upload("0.4.0")
    return step("commitPublish", path=r.path("0.4.0"), body=r.commit_body(up), token=r.token, auth="publishToken")


def status(f, polls_before, data=b"conda bytes", filename=None, want=None):
    r = Release(f)
    pid = r.commit("0.4.0", r.upload("0.4.0", data, filename=filename))
    if polls_before:
        r.poll(pid, polls_before)
    return step("getPublishStatus", path={"publish_id": pid}, token=r.token, auth="publishToken",
                check=(lambda b: b["status"] == want) if want else None)


def rejected(f, code):
    if code == "filename_mismatch":
        s = status(f, 2, filename="mojo-other-9.9.9-%s.conda" % BUILD)
    else:
        s = status(f, 2, data=("REJECT:%s from the replay" % code).encode())
    s["check"] = lambda b: b["status"] == "rejected" and b["rejection_code"] == code
    return s


YANK = {"yanked": True, "reason": "crashes on empty body"}


def yank(f, kind):
    r = Release(f)
    r.publish("0.4.0")
    if kind == "scope_missing":
        other = Release(f)
        tok = f.api_token(other.session, scopes=["yank"], packages=[other.name])["token"]
        return step("setYanked", path=r.path("0.4.0"), body={"yanked": False}, token=tok, auth="yankToken")
    if kind == "tombstoned":
        # A tombstoned version never changes state.
        f.control("/tombstone", {"name": r.name, "version": "0.4.0", "reason_code": "malware"})
        return step("setYanked", path=r.path("0.4.0"), body=YANK, token=r.token, auth="yankToken")
    if kind == "unyank":
        f.request("PUT", "/api/v1/packages/%s/0.4.0/yank" % r.name, YANK, r.token)
        return step("setYanked", path=r.path("0.4.0"), body={"yanked": False}, token=r.token, auth="yankToken",
                    check=lambda b: b["state"] == "published" and b["yank_reason"] is None)
    if kind == "publish token":
        tok = f.api_token(r.session, scopes=["publish"], packages=[r.name])["token"]
        return step("setYanked", path=r.path("0.4.0"), body=YANK, token=tok, auth="publishToken",
                    check=lambda b: b["state"] == "yanked")
    return step("setYanked", path=r.path("0.4.0"), body=YANK, token=r.token, auth="yankToken",
                check=lambda b: b["state"] == "yanked" and b["yank_reason"] == YANK["reason"])


def version_detail(f, kind):
    r = Release(f)
    r.publish("0.4.0")
    if kind == "yanked":
        f.request("PUT", "/api/v1/packages/%s/0.4.0/yank" % r.name, YANK, r.token)
        return step("getVersion", path=r.path("0.4.0"),
                    check=lambda b: b["state"] == "yanked" and b["yank_reason"] == YANK["reason"]
                    and "url" in b["files"][0])
    if kind == "tombstoned":
        f.control("/tombstone", {"name": r.name, "version": "0.4.0", "reason_code": "malware"})
        return step("getVersion", path=r.path("0.4.0"),
                    check=lambda b: b["state"] == "tombstoned" and "url" not in b["files"][0]
                    and b["tombstone"]["reason_code"] == "malware")
    return step("getVersion", path=r.path("0.4.0"),
                check=lambda b: b["state"] == "published" and b["requires_mojo"] == "==1.0.0"
                and b["provenance"] == {"kind": "none"})


RECIPES.update({
    ("beginUpload", "begin an upload"): lambda f: begin_upload(f),
    ("beginUpload", "error payload_too_large"): lambda f: begin_upload(f, size=60000000),
    ("beginUpload", "error limit_exceeded"): project_full,
    ("beginUpload", "error invalid_version: two parts"): lambda f: begin_upload_version(f, "1.0"),
    ("beginUpload", "error read_only_mode"): lambda f: begin_upload(f, read_only=True),
    ("commitPublish", "commit"): lambda f: commit(f, "ok"),
    ("commitPublish", "commit with the display fields"): lambda f: commit(f, "display"),
    ("commitPublish", "error invalid_version: pre-release suffix"): lambda f: commit_version(f, "1.0.0rc1"),
    ("commitPublish", "error upload_invalid"): lambda f: commit(f, "not uploaded"),
    ("commitPublish", "error version_exists"): lambda f: commit(f, "exists"),
    ("commitPublish", "error upload_used"): lambda f: commit(f, "used"),
    ("getPublishStatus", "error publish_not_found"):
        lambda f: step("getPublishStatus", path={"publish_id": "pub-none"}, token=Release(f).token,
                       auth="publishToken"),
    ("getPublishStatus", "status pending"): lambda f: status(f, 0, want="pending"),
    ("getPublishStatus", "status validating"): lambda f: status(f, 1, want="validating"),
    ("getPublishStatus", "status indexing"): lambda f: status(f, 2, want="indexing"),
    ("getPublishStatus", "status published"): lambda f: status(f, 3, want="published"),
    ("getPublishStatus", "rejected: archive_invalid"): lambda f: rejected(f, "archive_invalid"),
    ("getPublishStatus", "rejected: path_not_allowed"): lambda f: rejected(f, "path_not_allowed"),
    ("getPublishStatus", "rejected: limit_exceeded"): lambda f: rejected(f, "limit_exceeded"),
    ("getPublishStatus", "rejected: manifest_invalid"): lambda f: rejected(f, "manifest_invalid"),
    ("getPublishStatus", "rejected: filename_mismatch"): lambda f: rejected(f, "filename_mismatch"),
    ("getPublishStatus", "rejected: sha256_mismatch"): lambda f: rejected(f, "sha256_mismatch"),
    ("getPublishStatus", "rejected: dependency_not_allowed"): lambda f: rejected(f, "dependency_not_allowed"),
    ("setYanked", "error scope_missing"): lambda f: yank(f, "scope_missing"),
    ("setYanked", "error invalid_transition"): lambda f: yank(f, "tombstoned"),
    ("setYanked", "yank"): lambda f: yank(f, "yank"),
    ("setYanked", "yank with a publish token"): lambda f: yank(f, "publish token"),
    ("setYanked", "unyank"): lambda f: yank(f, "unyank"),
    ("getVersion", "error invalid_version"):
        lambda f: step("getVersion", path={"name": claimed(f)[2], "version": "1.0.0+local"}, malformed=True),
    ("getVersion", "error version_not_found"):
        lambda f: step("getVersion", path={"name": claimed(f)[2], "version": "9.9.9"}),
    ("getVersion", "version detail"): lambda f: version_detail(f, "published"),
    # The display fields are optional and the fake publishes none of them (the publish pipeline fills them from
    # mopm.toml), so these replay the ordinary state: the fake must still answer a valid VersionDetail without them.
    ("getVersion", "version detail with the mopm.toml display fields"): lambda f: version_detail(f, "published"),
    ("getVersion", "yanked version keeps its files and says why"): lambda f: version_detail(f, "yanked"),
    ("getVersion", "tombstoned version has no url"): lambda f: version_detail(f, "tombstoned"),
})


# ---------------------------------------------------------------------------
# The channel and the sparse index (spec/channel.md, spec/index.md)
# ---------------------------------------------------------------------------

def fetch(f, path):
    with urllib.request.urlopen(f.base + path, timeout=10) as r:
        return r.read()


def status_of(f, path):
    try:
        with urllib.request.urlopen(f.base + path, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def index_path(name):
    padded = (name + "____")[:4]
    return "/index/%s/%s/%s" % (padded[:2], padded[2:4], name)


def check_files(f):
    """Publishes, yanks and takes down versions of one package, then checks the
    files a client reads with no API: the index config, the package's index
    records (validate.index_problems), the takedown log, repodata.json and
    current_repodata.json, and the package file itself."""
    problems = []
    schema = lambda n: json.loads((validate.SPEC / n).read_text(encoding="utf-8"))  # noqa: E731

    config = json.loads(fetch(f, "/index/config.json"))
    problems += ["config.json: " + e.message for e in validate.Draft202012Validator(schema("index-config.schema.json")).iter_errors(config)]
    for subdir in ("linux-64", "linux-aarch64", "osx-arm64", "noarch"):
        empty = json.loads(fetch(f, "/channel/%s/repodata.json" % subdir))
        if empty["info"] != {"subdir": subdir} or "packages.conda" not in empty:
            problems.append("%s/repodata.json is not a repodata file" % subdir)

    r = Release(f)
    for version in ("0.3.0", "0.4.0", "0.5.0"):
        r.publish(version, ("bytes of %s" % version).encode())
    f.request("PUT", "/api/v1/packages/%s/0.3.0/yank" % r.name, YANK, r.token)
    r.publish("0.2.0", b"bytes of 0.2.0")
    f.control("/tombstone", {"name": r.name, "version": "0.2.0", "reason_code": "malware"})

    # The index records: valid, oldest first, the states the API reports.
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / r.name
        path.write_bytes(fetch(f, index_path(r.name)))
        problems += ["index: " + p for p in validate.index_problems(path, schema("index-record.schema.json"))]
        records = [json.loads(line) for line in path.read_text().splitlines()]
    order = [(rec["version"], rec["state"]) for rec in records]
    want = [("0.2.0", "tombstoned"), ("0.3.0", "yanked"), ("0.4.0", "published"), ("0.5.0", "published")]
    if order != want:
        problems.append("index records %s, expected %s" % (order, want))
    for rec in records:
        _, _, detail = f.request("GET", "/api/v1/packages/%s/%s" % (r.name, rec["version"]))
        if [x["sha256"] for x in rec["files"]] != [x["sha256"] for x in detail["files"]]:
            problems.append("index and getVersion disagree on the sha256 of %s" % rec["version"])

    # The channel: yanked and taken-down files leave packages.conda for removed.
    repodata = json.loads(fetch(f, "/channel/linux-64/repodata.json"))
    mine = {k: v for k, v in repodata["packages.conda"].items() if v["name"] == "mojo-" + r.name}
    if sorted(v["version"] for v in mine.values()) != ["0.4.0", "0.5.0"]:
        problems.append("repodata.json lists %s" % sorted(v["version"] for v in mine.values()))
    for v in mine.values():
        if v["build_number"] != 0 or v["subdir"] != "linux-64" or v["depends"] != ["mojo-compiler ==1.0.0"]:
            problems.append("repodata entry %s: %s" % (v["version"], v))
    for version in ("0.2.0", "0.3.0"):
        if r.filename(version) not in repodata["removed"]:
            problems.append("%s is not under removed" % version)
    # Rewriting the same state gives the same bytes (two rewrites: mode on, off).
    before = fetch(f, "/channel/linux-64/repodata.json")
    f.control("/mode", {"read_only": True})
    f.control("/mode", {"read_only": False})
    if fetch(f, "/channel/linux-64/repodata.json") != before:
        problems.append("repodata.json is not deterministic")
    current = json.loads(fetch(f, "/channel/linux-64/current_repodata.json"))
    cur = sorted(v["version"] for v in current["packages.conda"].values() if v["name"] == "mojo-" + r.name)
    if cur != ["0.5.0"]:
        problems.append("current_repodata.json lists %s, expected only 0.5.0" % cur)

    # The files: a yanked file still downloads; a taken-down one answers 410.
    if fetch(f, "/channel/linux-64/" + r.filename("0.3.0")) != b"bytes of 0.3.0":
        problems.append("the yanked file does not download")
    if status_of(f, "/channel/linux-64/" + r.filename("0.2.0")) != 410:
        problems.append("the taken-down file does not answer 410")

    takedowns = json.loads(fetch(f, "/index/takedowns.json"))
    problems += ["takedowns.json: " + e.message for e in validate.Draft202012Validator(schema("takedowns.schema.json")).iter_errors(takedowns)]
    if not any(t["name"] == r.name and t["version"] == "0.2.0" for t in takedowns["takedowns"]):
        problems.append("takedowns.json does not list the takedown")
    return ["files: " + p for p in problems]


def catalogue_drift(spec):
    """The codes the fake knows (registry/fake/errors.zig) must be the spec's."""
    src = (HERE.parents[1] / "registry" / "fake" / "errors.zig").read_text(encoding="utf-8")
    enum = src.split("pub const Code = enum {", 1)[1].split("};", 1)[0]
    fake = set(re.findall(r"(\w+),", enum))
    codes = set(spec["components"]["schemas"]["ErrorCode"]["enum"])
    if fake == codes:
        return []
    return ["registry/fake/errors.zig and the spec's ErrorCode differ (%s); run registry/fake/gen_errors.py"
            % ", ".join(sorted(fake ^ codes))]


def main(exe):
    spec = validate.yaml.safe_load((validate.SPEC / "api" / "openapi.yaml").read_text(encoding="utf-8"))
    ops = validate.operations(spec)
    catalogue = spec["x-mopm-errors"]
    cases = []
    for path in sorted((HERE / "api").glob("*.json")):
        cases += json.loads(path.read_text(encoding="utf-8"))["cases"]
    wanted = [c for c in cases if c.get("expect", "valid") == "valid" and c["operationId"] in IMPLEMENTED]
    failures = catalogue_drift(spec)
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
            if s["raw_path"]:
                status, headers, body = fake.request("GET", s["raw_path"])
            else:
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
            if not problems and s["check"]:
                try:
                    ok = s["check"](body)
                except Exception as e:  # a check that cannot read the body has failed
                    ok, body = False, {"check raised": repr(e), "body": body}
                if not ok:
                    problems.append("the recipe's check failed on %s" % json.dumps(body)[:300])
            if s["after"]:
                s["after"]()
            for p in problems:
                failures.append("%s / %r: %s" % (key[0], key[1], p))
        failures += check_files(fake)
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
