#!/usr/bin/env python3
"""Contract checks for the mopm registry API, index and lock.

Run from the repository root:

    python -I tests/contract/validate.py

Needs the packages in tests/contract/requirements.txt. CI installs them into a
throwaway virtual environment; nothing here is part of the mopm build.

What it checks (each failure prints one line starting with FAIL):

1. spec/api/openapi.yaml is a valid OpenAPI 3.1 document.
2. The error catalogue (x-mopm-errors) matches the ErrorCode enum.
3. Every file spec/*.schema.json is a valid JSON Schema, and the existing
   package metadata fixtures validate against package-metadata.schema.json.
4. Every case in tests/contract/api/*.json: its request and response are
   checked against the operation in openapi.yaml. A case marked
   "expect": "invalid" must be REJECTED, so the checker is shown to fail.
5. Every operation has a passing success case, every error code and every
   rejection code has a case.
6. Examples under tests/contract/examples/<kind>/valid pass and those under
   <kind>/invalid fail, for the index record, index config, takedown log and
   lock, including the lock rules that JSON Schema cannot express.
"""

import json
import pathlib
import re
import sys

import yaml
from jsonschema import Draft202012Validator
from openapi_spec_validator import validate as validate_openapi

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = ROOT / "spec"
HERE = ROOT / "tests" / "contract"

failures = []
checked = {"api cases": 0, "invalid cases rejected": 0, "examples": 0, "schemas": 0}


def fail(msg):
    failures.append(msg)
    print("FAIL: " + msg)


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------- openapi


def deref(spec, node):
    """Follow local $ref chains in a non-schema object."""
    seen = 0
    while isinstance(node, dict) and "$ref" in node:
        ref = node["$ref"]
        assert ref.startswith("#/"), ref
        cur = spec
        for part in ref[2:].split("/"):
            cur = cur[part]
        node = cur
        seen += 1
        assert seen < 20, "ref loop"
    return node


def schema_validator(spec, schema):
    """A validator for `schema` that can resolve #/components/... refs."""
    root = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "components": spec["components"],
        "allOf": [schema],
    }
    return Draft202012Validator(root)


def schema_errors(spec, schema, instance):
    v = schema_validator(spec, schema)
    return [
        "/".join(str(p) for p in e.absolute_path) + ": " + e.message[:160]
        for e in v.iter_errors(instance)
    ]


def template_regex(template):
    parts = re.split(r"\{[a-z_]+\}", template)
    return re.compile(".+".join(re.escape(p) for p in parts))


def operations(spec):
    ops = {}
    for path, item in spec["paths"].items():
        for method in ("get", "put", "post", "delete", "patch"):
            if method in item:
                op = item[method]
                opid = op["operationId"]
                if opid in ops:
                    fail("duplicate operationId " + opid)
                ops[opid] = (path, method, op, item)
    return ops


def case_problems(spec, ops, catalogue, case):
    """Return the list of ways `case` violates the contract."""
    problems = []
    opid = case.get("operationId")
    if opid not in ops:
        return ["unknown operationId %r" % (opid,)]
    path, method, op, item = ops[opid]
    request = case.get("request", {})
    response = case["response"]
    # A server must answer a malformed request; such a case (an error about
    # bad input) cannot satisfy the request schema, so its request values are
    # not schema-checked. Its response still is.
    check_request = not case.get("malformed_request", False)

    # parameters
    params = [deref(spec, p) for p in item.get("parameters", []) + op.get("parameters", [])]
    for where in ("path", "query"):
        declared = {p["name"]: p for p in params if p["in"] == where}
        given = request.get(where, {})
        for name in given:
            if name not in declared:
                problems.append("undeclared %s parameter %s" % (where, name))
        for name, p in declared.items():
            if name in given:
                if check_request:
                    for e in schema_errors(spec, p["schema"], given[name]):
                        problems.append("%s parameter %s: %s" % (where, name, e))
            elif p.get("required"):
                problems.append("missing %s parameter %s" % (where, name))
    template_names = set(re.findall(r"\{([a-z_]+)\}", path))
    if template_names != set(request.get("path", {}).keys()):
        problems.append("path parameters %s do not match template %s" % (sorted(request.get("path", {})), path))

    # request body
    rb = deref(spec, op.get("requestBody")) if "requestBody" in op else None
    if "body" in request:
        if rb is None:
            problems.append("request has a body but the operation takes none")
        else:
            schema = rb["content"]["application/json"]["schema"]
            if check_request:
                for e in schema_errors(spec, schema, request["body"]):
                    problems.append("request body: " + e)
    elif rb is not None and rb.get("required"):
        problems.append("request body is required")

    # authentication
    allowed = set()
    for req in op.get("security", spec.get("security", [])):
        allowed.update(req.keys())
    auth = request.get("auth")
    status = response["status"]
    if auth is not None and auth not in spec["components"]["securitySchemes"]:
        problems.append("unknown security scheme %s" % auth)
    elif auth is not None and auth not in allowed:
        problems.append("operation does not accept scheme %s" % auth)
    if allowed and auth is None and status != 401:
        problems.append("operation needs auth but the case sends none and does not expect 401")
    if not allowed and auth is not None:
        problems.append("operation takes no auth but the case sends %s" % auth)

    # response
    responses = op["responses"]
    declared = str(status) in responses
    resp = responses.get(str(status)) or responses.get("default")
    if resp is None:
        return problems + ["status %s is not declared" % status]
    resp = deref(spec, resp)
    if not declared and status < 400:
        problems.append("success status %s is not declared by the operation" % status)
    given_headers = {k.lower() for k in response.get("headers", {})}
    for hname, h in resp.get("headers", {}).items():
        h = deref(spec, h)
        if h.get("required") and hname.lower() not in given_headers:
            problems.append("response lacks required header " + hname)
    content = resp.get("content")
    if content:
        if "body" not in response:
            problems.append("response needs a body")
        else:
            schema = content["application/json"]["schema"]
            for e in schema_errors(spec, schema, response["body"]):
                problems.append("response body: " + e)
    elif "body" in response:
        problems.append("response must have no body")

    # error catalogue
    if status >= 400 and isinstance(response.get("body"), dict):
        err = response["body"].get("error", {})
        code = err.get("code")
        if code not in catalogue:
            problems.append("error code %r is not in the catalogue" % (code,))
        else:
            entry = catalogue[code]
            if entry["status"] != status:
                problems.append("code %s is catalogued with status %s, not %s" % (code, entry["status"], status))
            if not template_regex(entry["message"]).fullmatch(err.get("message", "")):
                problems.append("message %r does not follow the template of %s" % (err.get("message"), code))
            if not template_regex(entry["hint"]).fullmatch(err.get("hint", "")):
                problems.append("hint %r does not follow the template of %s" % (err.get("hint"), code))
            if code == "rate_limited" and "retry-after" not in given_headers:
                problems.append("rate_limited must carry Retry-After")

    # the embedded manifest is package metadata
    body = response.get("body")
    if isinstance(body, dict) and "manifest" in body:
        meta = Draft202012Validator(load_json(SPEC / "package-metadata.schema.json"))
        for e in meta.iter_errors(body["manifest"]):
            problems.append("manifest: " + e.message[:160])
    return problems


def check_api(spec):
    ops = operations(spec)
    catalogue = spec["x-mopm-errors"]
    codes = set(spec["components"]["schemas"]["ErrorCode"]["enum"])
    if codes != set(catalogue):
        fail("ErrorCode enum and x-mopm-errors differ: %s" % sorted(codes ^ set(catalogue)))
    for code, entry in catalogue.items():
        if not (isinstance(entry.get("status"), int) and 400 <= entry["status"] <= 599):
            fail("catalogue %s has no HTTP error status" % code)
        if not entry.get("message") or not isinstance(entry.get("hint"), str):
            fail("catalogue %s needs a message and a hint string" % code)

    seen_ok = set()
    seen_codes = set()
    seen_rejections = set()
    files = sorted((HERE / "api").glob("*.json"))
    if not files:
        fail("no files in tests/contract/api")
    for f in files:
        for i, case in enumerate(load_json(f)["cases"]):
            name = "%s[%d] %s" % (f.name, i, case.get("name", ""))
            checked["api cases"] += 1
            problems = case_problems(spec, ops, catalogue, case)
            expect = case.get("expect", "valid")
            if expect == "valid":
                for p in problems:
                    fail("%s: %s" % (name, p))
                status = case["response"]["status"]
                if not problems:
                    if status < 300:
                        seen_ok.add(case["operationId"])
                    body = case["response"].get("body")
                    if status >= 400 and isinstance(body, dict):
                        seen_codes.add(body["error"]["code"])
                    if isinstance(body, dict) and body.get("rejection_code"):
                        seen_rejections.add(body["rejection_code"])
            elif expect == "invalid":
                if not problems:
                    fail("%s: marked invalid but the contract accepts it" % name)
                else:
                    checked["invalid cases rejected"] += 1
            else:
                fail("%s: expect must be valid or invalid" % name)

    for opid in ops:
        if opid not in seen_ok:
            fail("operation %s has no passing success case" % opid)
    for code in codes - seen_codes:
        fail("error code %s has no case" % code)
    rej = set(spec["components"]["schemas"]["RejectionCode"]["enum"])
    for code in rej - seen_rejections:
        fail("rejection code %s has no case" % code)


# ---------------------------------------------------------------- examples


def lock_problems(doc):
    problems = []
    pk = doc["packages"]
    keys = [(p["name"], p["version"], p["subdir"]) for p in pk]
    if keys != sorted(set(keys)):
        problems.append("packages are not strictly sorted by (name, version, subdir)")
    channels = set(doc["channels"])
    names = {p["name"] for p in pk}
    by_name_channel = {}
    soname_owner = {}
    for p in pk:
        if p["channel"] not in channels:
            problems.append("%s: channel %s is not in channels" % (p["name"], p["channel"]))
        want = "%s%s/mojo-%s-%s-%s.conda" % (p["channel"], p["subdir"], p["name"], p["version"], p["build"])
        if p["url"] != want:
            problems.append("%s: url is not %s" % (p["name"], want))
        if p["mojo"] != doc["toolchain"]["mojo"]:
            problems.append("%s: built with mojo %s, toolchain is %s" % (p["name"], p["mojo"], doc["toolchain"]["mojo"]))
        for d in p.get("deps", []):
            if d not in names:
                problems.append("%s: dep %s is not in packages" % (p["name"], d))
        by_name_channel.setdefault(p["name"], set()).add(p["channel"])
        for n in p.get("native", []):
            owner = soname_owner.setdefault(n["soname"], p["name"])
            if owner != p["name"]:
                problems.append("soname %s is shipped by %s and %s" % (n["soname"], owner, p["name"]))
    for name, chans in by_name_channel.items():
        if len(chans) > 1:
            problems.append("%s comes from more than one channel" % name)
    return problems


def index_problems(path, schema):
    """An index package file: newline-delimited records."""
    problems = []
    text = path.read_text(encoding="utf-8")
    if not text.endswith("\n"):
        problems.append("file does not end with a newline (truncated?)")
    lines = text.split("\n")[:-1] if text.endswith("\n") else text.split("\n")
    versions = set()
    v = Draft202012Validator(schema)
    for n, line in enumerate(lines, 1):
        if line == "":
            problems.append("line %d is blank" % n)
            continue
        try:
            rec = json.loads(line)
        except ValueError as e:
            problems.append("line %d is not JSON: %s" % (n, e))
            continue
        for e in v.iter_errors(rec):
            problems.append("line %d: %s" % (n, e.message[:160]))
        if rec.get("name") != path.stem:
            problems.append("line %d: name %r differs from the file name %r" % (n, rec.get("name"), path.stem))
        if rec.get("version") in versions:
            problems.append("line %d: version %s repeats" % (n, rec.get("version")))
        versions.add(rec.get("version"))
    if not lines:
        problems.append("file is empty")
    return problems


KINDS = {
    "index-record": ("index-record.schema.json", "*.ndjson"),
    "index-config": ("index-config.schema.json", "*.json"),
    "takedowns": ("takedowns.schema.json", "*.json"),
    "lock": ("lock.schema.json", "*.json"),
}


def example_problems(kind, schema, path):
    if kind == "index-record":
        return index_problems(path, schema)
    doc = load_json(path)
    problems = [e.message[:160] for e in Draft202012Validator(schema).iter_errors(doc)]
    if kind == "lock" and not problems:
        problems += lock_problems(doc)
    return problems


def check_examples():
    for kind, (schema_file, glob) in KINDS.items():
        schema = load_json(SPEC / schema_file)
        for verdict in ("valid", "invalid"):
            files = sorted((HERE / "examples" / kind / verdict).glob(glob))
            if not files:
                fail("no %s examples for %s" % (verdict, kind))
            for f in files:
                checked["examples"] += 1
                problems = example_problems(kind, schema, f)
                rel = f.relative_to(ROOT)
                if verdict == "valid":
                    for p in problems:
                        fail("%s: %s" % (rel, p))
                elif not problems:
                    fail("%s: is under invalid/ but passes" % rel)


def check_schemas():
    for f in sorted(SPEC.glob("*.schema.json")):
        checked["schemas"] += 1
        try:
            Draft202012Validator.check_schema(load_json(f))
        except Exception as e:  # SchemaError
            fail("%s is not a valid JSON Schema: %s" % (f.name, str(e)[:160]))
    meta = Draft202012Validator(load_json(SPEC / "package-metadata.schema.json"))
    for f in sorted((ROOT / "tests" / "fixtures").rglob("*.mopm.json")):
        for e in meta.iter_errors(load_json(f)):
            fail("%s: %s" % (f.relative_to(ROOT), e.message[:160]))


def main():
    with open(SPEC / "api" / "openapi.yaml", encoding="utf-8") as f:
        spec = yaml.safe_load(f)
    try:
        validate_openapi(spec)
    except Exception as e:
        fail("openapi.yaml is not valid OpenAPI: %s" % str(e)[:400])
        return 1
    check_schemas()
    check_api(spec)
    check_examples()
    print("checked: " + ", ".join("%s %d" % (k, v) for k, v in checked.items()))
    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    print("contract OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
