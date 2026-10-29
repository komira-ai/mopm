//! The two metadata files and how they must agree (`validate/metadata.ts`): `lib/mojo/<name>.mopm.json` (checked
//! against spec/package-metadata.schema.json, hand-written because the schema is small) and conda's
//! `info/index.json`.

use std::collections::BTreeSet;

use mopm_core::canonical_json::cmp_utf16;
use mopm_core::version::{canonical_version, is_valid_version};
use serde::Serialize;
use serde_json::{Map, Value};

use crate::codes::{fail, Checked, RuleCode};
use crate::js;

/// Constants drawn from spec/package-metadata.schema.json.
pub const METADATA_SCHEMA_VERSION: u64 = 1;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct NativeDecl {
    pub id: String,
    pub soname: String,
    pub kind: String,
    pub mode: String,
    /// Archive paths this declaration claims (resolved against lib/mojo/), e.g. lib/libfoo.so.1.
    pub paths: Vec<String>,
    #[serde(rename = "sharedPath", skip_serializing_if = "Option::is_none")]
    pub shared_path: Option<String>,
    #[serde(rename = "staticPath", skip_serializing_if = "Option::is_none")]
    pub static_path: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Dep {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Mopm {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    pub deps: Vec<Dep>,
    pub native: Vec<NativeDecl>,
}

/// Which rule a JSON file that does not parse as an object is refused with.
#[derive(Clone, Copy)]
pub enum JsonRule {
    Manifest,
    Index,
}

pub fn parse_json_object(buf: &[u8], what: &str, rule: JsonRule) -> Checked<Map<String, Value>> {
    let rule = match rule {
        JsonRule::Manifest => RuleCode::ManifestJson,
        JsonRule::Index => RuleCode::IndexInvalid,
    };
    let parsed = js::decode_utf8(buf).and_then(|t| serde_json::from_str::<Value>(&t).ok());
    match parsed {
        None => fail(rule, format!("{what} is not valid UTF-8 JSON")),
        Some(Value::Object(m)) => Ok(m),
        Some(_) => fail(rule, format!("{what} is not a JSON object")),
    }
}

fn is_zero(v: &Value) -> bool {
    v.as_f64() == Some(0.0)
}

fn bad<T>(m: impl std::fmt::Display) -> Checked<T> {
    fail(RuleCode::ManifestSchema, format!("<name>.mopm.json: {m}"))
}

fn str_of(v: Option<&Value>) -> Option<&str> {
    v.and_then(Value::as_str)
}

/// `^lib[^./]+\..+$`: the soname looks like `lib<name>.<suffix>`.
fn soname_ok(s: &str) -> bool {
    let Some(rest) = s.strip_prefix("lib") else { return false };
    let stem_len: usize = rest.chars().take_while(|c| *c != '.' && *c != '/').map(char::len_utf8).sum();
    if stem_len == 0 {
        return false;
    }
    let Some(tail) = rest[stem_len..].strip_prefix('.') else { return false };
    // `.` does not match a line terminator.
    !tail.is_empty() && !tail.contains(['\n', '\r', '\u{2028}', '\u{2029}'])
}

/// `^[^ \u0000-\u001f\u007f](?:[^\u0000-\u001f\u007f]*[^ \u0000-\u001f\u007f])?$`: an exclusivity group is not empty, has
/// no space at either end and no control character.
fn exclusive_ok(s: &str) -> bool {
    !s.is_empty() && !s.starts_with(' ') && !s.ends_with(' ') && !s.chars().any(|c| c < ' ' || c == '\u{7f}')
}

/// Validate `<name>.mopm.json` against spec/package-metadata.schema.json.
pub fn check_mopm(o: &Map<String, Value>) -> Checked<Mopm> {
    if !o.get("schema").is_some_and(|v| v.as_f64() == Some(METADATA_SCHEMA_VERSION as f64)) {
        return bad(format!("'schema' must be {METADATA_SCHEMA_VERSION}"));
    }
    let name = match str_of(o.get("name")) {
        Some(n) if !n.is_empty() => n.to_string(),
        _ => return bad("'name' must be a non-empty string"),
    };
    let mut version = None;
    if let Some(v) = o.get("version") {
        let Some(s) = v.as_str() else { return bad("'version' must be a string") };
        if !is_valid_version(s) {
            return bad(format!("'version' '{s}' is not MAJOR.MINOR.PATCH (three numbers, no suffix)"));
        }
        version = Some(s.to_string());
    }
    let mut deps = Vec::new();
    if let Some(d) = o.get("deps") {
        let Some(items) = d.as_array() else { return bad("'deps' must be an array") };
        for item in items {
            let Some(r) = item.as_object() else { return bad("'deps' items must be objects") };
            let dep_name = match str_of(r.get("name")) {
                Some(n) if !n.is_empty() => n,
                _ => return bad("a dependency needs a non-empty 'name'"),
            };
            if r.get("range").is_some_and(|v| !v.is_string()) {
                return bad("a dependency 'range' must be a string");
            }
            if r.get("path").is_some_and(|v| !v.is_string()) {
                return bad("a dependency 'path' must be a string");
            }
            // Cargo's rule: a path is only for development; what is published must say which versions of the dependency work.
            if r.get("path").is_some() && r.get("range").is_none() {
                return bad(format!("dependency '{dep_name}' has a path but no version; a published package depends on a version, so add one next to the path"));
            }
            deps.push(Dep { name: dep_name.to_string(), range: str_of(r.get("range")).map(str::to_string) });
        }
    }
    let mut native = Vec::new();
    if let Some(n) = o.get("native") {
        let Some(items) = n.as_array() else { return bad("'native' must be an array") };
        for item in items {
            native.push(check_native(item)?);
        }
    }
    Ok(Mopm { name, version, deps, native })
}

fn check_native(item: &Value) -> Checked<NativeDecl> {
    let Some(r) = item.as_object() else { return bad("'native' items must be objects") };
    let id = match str_of(r.get("id")) {
        Some(i) if !i.is_empty() => i.to_string(),
        _ => return bad("a native library needs a non-empty 'id'"),
    };
    let soname = match str_of(r.get("soname")) {
        Some(s) if soname_ok(s) => s.to_string(),
        _ => return bad(format!("native '{id}': 'soname' must look like lib<name>.<suffix>")),
    };
    // `r.kind ?? 'shared'`: absent or null is the default.
    let kind_v = r.get("kind").filter(|v| !v.is_null());
    let mode_v = r.get("mode").filter(|v| !v.is_null());
    let kind = match kind_v {
        None => "shared",
        Some(Value::String(s)) if matches!(s.as_str(), "shared" | "static" | "both") => s.as_str(),
        Some(_) => return bad(format!("native '{id}': 'kind' must be shared, static or both")),
    };
    let mode = match mode_v {
        None => "link",
        Some(Value::String(s)) if matches!(s.as_str(), "link" | "load") => s.as_str(),
        Some(_) => return bad(format!("native '{id}': 'mode' must be link or load")),
    };
    if r.get("file").is_some_and(|v| !v.is_string()) {
        return bad(format!("native '{id}': 'file' must be a string"));
    }
    if r.get("static_file").is_some_and(|v| !v.is_string()) {
        return bad(format!("native '{id}': 'static_file' must be a string"));
    }
    if let Some(needs) = r.get("needs") {
        if !needs.as_array().is_some_and(|a| a.iter().all(Value::is_string)) {
            return bad(format!("native '{id}': 'needs' must be an array of strings"));
        }
    }
    if r.get("exclusive").is_some_and(|v| v.as_str().map_or(true, |s| !exclusive_ok(s))) {
        return bad(format!("native '{id}': 'exclusive' must be a non-empty string with no leading or trailing space and no control character"));
    }
    let file = str_of(r.get("file"));
    let static_file = str_of(r.get("static_file"));
    if matches!(kind, "shared" | "both") && file.is_none() {
        return bad(format!("native '{id}': kind {kind} needs 'file'"));
    }
    if matches!(kind, "static" | "both") && static_file.is_none() {
        return bad(format!("native '{id}': kind {kind} needs 'static_file'"));
    }
    let mut paths = Vec::new();
    let (mut shared_path, mut static_path) = (None, None);
    for (field, rel) in [("file", file), ("static_file", static_file)] {
        let Some(rel) = rel else { continue };
        let resolved = js::posix_normalize(&js::posix_join("lib/mojo", rel));
        // Native libraries live directly in lib/: one level, no climbing out, no absolute paths.
        let direct = resolved.strip_prefix("lib/").is_some_and(|r| !r.is_empty() && !r.contains('/'));
        if rel.starts_with('/') || !direct {
            return fail(RuleCode::NativePath, format!("native '{id}': '{rel}' does not resolve to a file directly under lib/"));
        }
        paths.push(resolved.clone());
        if field == "file" {
            shared_path = Some(resolved);
        } else {
            static_path = Some(resolved);
        }
    }
    Ok(NativeDecl { id, soname, kind: kind.to_string(), mode: mode.to_string(), paths, shared_path, static_path })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CondaIndex {
    pub name: String,
    pub version: String,
    pub build: String,
    pub compiler: String,
    pub subdir: String,
    pub depends: Vec<String>,
}

/// The compiler of a build string `mojo<digits>(.<digits>)*_0`.
fn compiler_of(build: &str) -> Option<&str> {
    let c = build.strip_prefix("mojo")?.strip_suffix("_0")?;
    let ok = !c.is_empty() && c.split('.').all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()));
    ok.then_some(c)
}

/// Validate the fields of info/index.json that the registry relies on.
pub fn check_index(o: &Map<String, Value>) -> Checked<CondaIndex> {
    let bad2 = |m: &str| -> Checked<CondaIndex> { fail(RuleCode::IndexInvalid, format!("info/index.json: {m}")) };
    let Some(name) = str_of(o.get("name")) else { return bad2("'name' must be a string") };
    let Some(version) = str_of(o.get("version")) else { return bad2("'version' must be a string") };
    let Some(build) = str_of(o.get("build")) else { return bad2("'build' must be a string") };
    let Some(subdir) = str_of(o.get("subdir")) else { return bad2("'subdir' must be a string") };
    if !o.get("build_number").is_some_and(is_zero) {
        return bad2("'build_number' must be 0");
    }
    let Some(compiler) = compiler_of(build) else { return bad2("'build' must be mojo<compiler>_0") };
    let depends: Option<Vec<String>> = o.get("depends").and_then(Value::as_array).and_then(|a| a.iter().map(|v| v.as_str().map(str::to_string)).collect());
    let Some(depends) = depends else { return bad2("'depends' must be an array of strings") };
    Ok(CondaIndex { name: name.into(), version: version.into(), build: build.into(), compiler: compiler.into(), subdir: subdir.into(), depends })
}

/// The first whitespace-separated word, as `d.split(/\s+/, 1)[0]` gives it (a leading space gives "").
fn first_word(d: &str) -> &str {
    d.split(js::is_space).next().unwrap_or("")
}

/// `s.replace(/\s+/g, ' ')`.
fn collapse_space(s: &str) -> String {
    let mut out = String::new();
    let mut in_run = false;
    for c in s.chars() {
        if js::is_space(c) {
            if !in_run {
                out.push(' ');
            }
            in_run = true;
        } else {
            out.push(c);
            in_run = false;
        }
    }
    out
}

fn sorted_join(set: &BTreeSet<String>) -> String {
    let mut v: Vec<&String> = set.iter().collect();
    v.sort_by(|a, b| cmp_utf16(a, b));
    v.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(", ")
}

const SPEC_MAX: usize = 256;

/// `CONDA_NAME` of `native-mirror.ts`: `^[a-z0-9][a-z0-9._-]{0,127}$`.
fn is_conda_name(s: &str) -> bool {
    let b = s.as_bytes();
    !b.is_empty()
        && b.len() <= 128
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'.' | b'_' | b'-'))
}

/// `[A-Za-z0-9.*+!_,|<>=~^-]{1,128}`: a version requirement as `depends` writes it.
fn is_version_token(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s.bytes().all(|c| c.is_ascii_alphanumeric() || b".*+!_,|<>=~^-".contains(&c))
}

/// `[A-Za-z0-9.*+_-]{1,64}`: a build string.
fn is_build_token(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|c| c.is_ascii_alphanumeric() || b".*+_-".contains(&c))
}

/// Whether one `depends` entry is well formed (`name`, `name version` or `name version build`), else why it is not
/// (`parseSpec` of the TypeScript, word for word).
fn parse_spec(d: &str) -> Result<(), String> {
    if d.encode_utf16().count() > SPEC_MAX {
        return Err(format!("is longer than {SPEC_MAX} characters"));
    }
    // `d.split(/\s+/)`, then the empty word of a trailing space dropped.
    let collapsed = collapse_space(d);
    let mut parts: Vec<&str> = collapsed.split(' ').collect();
    if parts.last() == Some(&"") {
        parts.pop();
    }
    let name = parts.first().copied().unwrap_or("");
    if !is_conda_name(name) {
        return Err("does not start with a conda package name (lower-case letters, digits, ., _ and -)".to_string());
    }
    if parts.len() > 3 {
        return Err("has more than a name, a version and a build string".to_string());
    }
    if let Some(v) = parts.get(1) {
        if !is_version_token(v) {
            return Err(format!("has a version requirement '{v}' that is not one"));
        }
    }
    if let Some(b) = parts.get(2) {
        if !is_build_token(b) {
            return Err(format!("has a build string '{b}' that is not one"));
        }
    }
    Ok(())
}

/// Check `depends` of the index: the compiler exactly once and equal to the build string's compiler, every other entry a
/// well-formed conda requirement (any native name is accepted; malformed text is the only refusal), and the `mojo-*` set equal to
/// `deps` of the embedded metadata. Returns the dependency names for the verdict. The TypeScript also warns about a name the
/// conda-forge mirror does not list; this port has no mirror and no warnings yet (README, "Differences").
pub fn check_depends(idx: &CondaIndex, mopm: &Mopm) -> Checked<Vec<String>> {
    let compilers: Vec<&String> = idx.depends.iter().filter(|d| first_word(d) == "mojo-compiler").collect();
    if compilers.is_empty() {
        return fail(RuleCode::CompilerMissing, "info/index.json 'depends' has no 'mojo-compiler ==<exact>'");
    }
    if compilers.len() > 1 {
        return fail(RuleCode::CompilerMismatch, "info/index.json 'depends' names mojo-compiler more than once");
    }
    if collapse_space(compilers[0]) != format!("mojo-compiler =={}", idx.compiler) {
        return fail(
            RuleCode::CompilerMismatch,
            format!("'{}' does not equal 'mojo-compiler =={}' (the compiler in the build string)", compilers[0], idx.compiler),
        );
    }
    let mut mojo_deps: BTreeSet<String> = BTreeSet::new();
    for d in &idx.depends {
        let dn = first_word(d);
        if dn == "mojo-compiler" {
            continue;
        }
        // A name that starts with `mojo-` is a Mojo package and is never a native one: it must be declared in the metadata's `deps`
        // (below), and the bare prefix is not a package.
        if dn.starts_with("mojo-") {
            if dn.len() == 5 {
                return fail(RuleCode::DependencyNotAllowed, format!("dependency '{d}' is not a Mojo package name"));
            }
            mojo_deps.insert(dn.to_string());
            continue;
        }
        if let Err(why) = parse_spec(d) {
            let head: Vec<u16> = d.encode_utf16().take(80).collect();
            return fail(RuleCode::DependencyNotAllowed, format!("dependency '{}' {why}", String::from_utf16_lossy(&head)));
        }
    }
    let declared: BTreeSet<String> = mopm.deps.iter().map(|d| format!("mojo-{}", d.name)).collect();
    if declared != mojo_deps {
        return fail(
            RuleCode::DepsMismatch,
            format!("info/index.json depends [{}] differ from the metadata deps [{}]", sorted_join(&mojo_deps), sorted_join(&declared)),
        );
    }
    let mut out: Vec<String> = mojo_deps.into_iter().collect();
    out.sort_by(|a, b| cmp_utf16(a, b));
    Ok(out)
}

/// The requirements of `depends` that are neither the compiler nor a `mojo-*` package (after `check_depends` accepted the
/// index, these are conda packages the package loads), runs of white space as one space and no trailing space, in the
/// TypeScript's sort order.
pub fn native_depends_of(idx: &CondaIndex) -> Vec<String> {
    let mut out: Vec<String> = idx
        .depends
        .iter()
        .filter(|d| {
            let dn = first_word(d);
            dn != "mojo-compiler" && !dn.starts_with("mojo-")
        })
        .map(|d| {
            let c = collapse_space(d);
            c.strip_suffix(' ').map(str::to_string).unwrap_or(c)
        })
        .collect();
    out.sort_by(|a, b| cmp_utf16(a, b));
    out
}

/// Compare a version string from the archive to the one requested.
pub fn same_version(a: &str, b: &str) -> bool {
    matches!((canonical_version(a), canonical_version(b)), (Ok(x), Ok(y)) if x == y)
}

/// The file naming rules relative to the declared soname.
pub fn check_native_names(n: &NativeDecl) -> Checked<()> {
    let stem = n.soname.split('.').next().unwrap_or("");
    let base_of = |p: &str| p.rsplit('/').next().unwrap_or(p).to_string();
    if let Some(shared) = &n.shared_path {
        let base = base_of(shared);
        let so_like = {
            // /\.so(?:\.\d+)*$/ on the soname
            n.soname.match_indices(".so").any(|(i, _)| {
                let tail = &n.soname[i + 3..];
                tail.split('.').skip(1).all(|d| !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit())) && (tail.is_empty() || tail.starts_with('.'))
            })
        };
        let ok = base == n.soname || (so_like && base.starts_with(&format!("{}.", n.soname)));
        if !ok {
            return fail(RuleCode::NativePath, format!("native '{}': file '{base}' does not fit soname '{}'", n.id, n.soname));
        }
    }
    if let Some(stat) = &n.static_path {
        let base = base_of(stat);
        if base != format!("{stem}.a") {
            return fail(RuleCode::NativePath, format!("native '{}': static_file '{base}' must be '{stem}.a'", n.id));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn an_exclusive_group_is_exact_text_with_no_edge_space_and_no_control_character() {
        for ok in ["libcrypto", "lib x", "LibCrypto", "é", "a\u{80}"] {
            assert!(exclusive_ok(ok), "{ok:?}");
        }
        for bad in ["", " ", " a", "a ", "a\t", "\ta", "a\nb", "a\u{0}b", "a\u{7f}"] {
            assert!(!exclusive_ok(bad), "{bad:?}");
        }
    }

    fn obj(v: Value) -> Map<String, Value> {
        v.as_object().unwrap().clone()
    }

    fn mopm_msg(v: Value) -> (RuleCode, String) {
        let e = check_mopm(&obj(v)).err().expect("a refusal");
        (e.rule, e.message)
    }

    #[test]
    fn a_minimal_manifest_and_the_defaults_of_a_native_declaration() {
        let m = check_mopm(&obj(json!({"schema": 1, "name": "demo"}))).unwrap();
        assert_eq!(m, Mopm { name: "demo".into(), version: None, deps: vec![], native: vec![] });
        let m = check_mopm(&obj(json!({"schema": 1.0, "name": "demo", "version": "1.0.0", "deps": [{"name": "q", "range": ">=1"}, {"name": "r"}],
            "native": [{"id": "zlib", "soname": "libz.so.1", "file": "../libz.so.1"}]})))
        .unwrap();
        assert_eq!(m.deps[1].range, None);
        let n = &m.native[0];
        assert_eq!((n.kind.as_str(), n.mode.as_str(), n.paths.as_slice(), n.shared_path.as_deref()), ("shared", "link", &["lib/libz.so.1".to_string()][..], Some("lib/libz.so.1")));
    }

    #[test]
    fn schema_refusals_say_what_is_wrong() {
        let table: Vec<(Value, &str)> = vec![
            (json!({"name": "d"}), "<name>.mopm.json: 'schema' must be 1"),
            (json!({"schema": 2, "name": "d"}), "<name>.mopm.json: 'schema' must be 1"),
            (json!({"schema": "1", "name": "d"}), "<name>.mopm.json: 'schema' must be 1"),
            (json!({"schema": 1}), "<name>.mopm.json: 'name' must be a non-empty string"),
            (json!({"schema": 1, "name": ""}), "<name>.mopm.json: 'name' must be a non-empty string"),
            (json!({"schema": 1, "name": "d", "version": 1}), "<name>.mopm.json: 'version' must be a string"),
            (json!({"schema": 1, "name": "d", "version": null}), "<name>.mopm.json: 'version' must be a string"),
            (json!({"schema": 1, "name": "d", "version": "1.0"}), "<name>.mopm.json: 'version' '1.0' is not MAJOR.MINOR.PATCH (three numbers, no suffix)"),
            (json!({"schema": 1, "name": "d", "deps": {}}), "<name>.mopm.json: 'deps' must be an array"),
            (json!({"schema": 1, "name": "d", "deps": [1]}), "<name>.mopm.json: 'deps' items must be objects"),
            (json!({"schema": 1, "name": "d", "deps": [{}]}), "<name>.mopm.json: a dependency needs a non-empty 'name'"),
            (json!({"schema": 1, "name": "d", "deps": [{"name": "q", "range": 3}]}), "<name>.mopm.json: a dependency 'range' must be a string"),
            (json!({"schema": 1, "name": "d", "deps": [{"name": "q", "path": 3}]}), "<name>.mopm.json: a dependency 'path' must be a string"),
            (json!({"schema": 1, "name": "d", "deps": [{"name": "q", "path": "../q"}]}), "<name>.mopm.json: dependency 'q' has a path but no version; a published package depends on a version, so add one next to the path"),
            (json!({"schema": 1, "name": "d", "native": 3}), "<name>.mopm.json: 'native' must be an array"),
            (json!({"schema": 1, "name": "d", "native": [3]}), "<name>.mopm.json: 'native' items must be objects"),
            (json!({"schema": 1, "name": "d", "native": [{}]}), "<name>.mopm.json: a native library needs a non-empty 'id'"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "z.so"}]}), "<name>.mopm.json: native 'z': 'soname' must look like lib<name>.<suffix>"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "kind": "x"}]}), "<name>.mopm.json: native 'z': 'kind' must be shared, static or both"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "mode": "x"}]}), "<name>.mopm.json: native 'z': 'mode' must be link or load"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "file": 1}]}), "<name>.mopm.json: native 'z': 'file' must be a string"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "needs": [1]}]}), "<name>.mopm.json: native 'z': 'needs' must be an array of strings"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "exclusive": 1}]}), "<name>.mopm.json: native 'z': 'exclusive' must be a non-empty string with no leading or trailing space and no control character"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "exclusive": ""}]}), "<name>.mopm.json: native 'z': 'exclusive' must be a non-empty string with no leading or trailing space and no control character"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "exclusive": " libx"}]}), "<name>.mopm.json: native 'z': 'exclusive' must be a non-empty string with no leading or trailing space and no control character"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "exclusive": "libx "}]}), "<name>.mopm.json: native 'z': 'exclusive' must be a non-empty string with no leading or trailing space and no control character"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "exclusive": "libx\n"}]}), "<name>.mopm.json: native 'z': 'exclusive' must be a non-empty string with no leading or trailing space and no control character"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "exclusive": "lib\u{1}x"}]}), "<name>.mopm.json: native 'z': 'exclusive' must be a non-empty string with no leading or trailing space and no control character"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "exclusive": "lib\u{7f}x"}]}), "<name>.mopm.json: native 'z': 'exclusive' must be a non-empty string with no leading or trailing space and no control character"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so"}]}), "<name>.mopm.json: native 'z': kind shared needs 'file'"),
            (json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "kind": "both", "file": "libz.so"}]}), "<name>.mopm.json: native 'z': kind both needs 'static_file'"),
        ];
        for (v, want) in table {
            let (rule, msg) = mopm_msg(v.clone());
            assert_eq!((rule, msg.as_str()), (if want.is_empty() { rule } else { RuleCode::ManifestSchema }, want), "{v}");
        }
    }

    #[test]
    fn a_native_path_must_resolve_to_one_file_directly_under_lib() {
        let with = |file: &str| json!({"schema": 1, "name": "d", "native": [{"id": "z", "soname": "libz.so", "file": file}]});
        for ok in ["../libz.so", "../x/../libz.so", "../././libz.so"] {
            check_mopm(&obj(with(ok))).unwrap_or_else(|e| panic!("{ok}: {e}"));
        }
        for bad in ["libz.so", "/lib/libz.so", "../../libz.so", "../sub/libz.so", "..", "../", "x/y"] {
            let (rule, msg) = mopm_msg(with(bad));
            assert_eq!(rule, RuleCode::NativePath, "{bad}");
            assert_eq!(msg, format!("native 'z': '{bad}' does not resolve to a file directly under lib/"));
        }
    }

    #[test]
    fn json_parsing_is_strict_utf8_with_the_byte_order_mark_dropped() {
        assert!(parse_json_object(b"{\"a\":1}", "x", JsonRule::Manifest).is_ok());
        assert!(parse_json_object(b"\xef\xbb\xbf{\"a\":1}", "x", JsonRule::Manifest).is_ok());
        let e = parse_json_object(b"{\"a\":\xff}", "the file", JsonRule::Manifest).unwrap_err();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::ManifestJson, "the file is not valid UTF-8 JSON"));
        let e = parse_json_object(b"[1]", "the file", JsonRule::Index).unwrap_err();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::IndexInvalid, "the file is not a JSON object"));
        assert_eq!(parse_json_object(b"null", "f", JsonRule::Index).unwrap_err().message, "f is not a JSON object");
    }

    fn index(v: Value) -> Checked<CondaIndex> {
        check_index(&obj(v))
    }

    #[test]
    fn the_index_fields_and_the_compiler_in_the_build_string() {
        let good = json!({"name": "mojo-demo", "version": "1.0.0", "build": "mojo1.0.0_0", "build_number": 0, "subdir": "noarch", "depends": ["mojo-compiler ==1.0.0"]});
        let i = index(good.clone()).unwrap();
        assert_eq!((i.compiler.as_str(), i.build.as_str()), ("1.0.0", "mojo1.0.0_0"));
        let mut g = good.clone();
        g["build_number"] = json!(0.0);
        index(g).unwrap();
        for (field, value, msg) in [
            ("name", json!(1), "info/index.json: 'name' must be a string"),
            ("version", json!(null), "info/index.json: 'version' must be a string"),
            ("build", json!(1), "info/index.json: 'build' must be a string"),
            ("subdir", json!(1), "info/index.json: 'subdir' must be a string"),
            ("build_number", json!(1), "info/index.json: 'build_number' must be 0"),
            ("build", json!("mojo1.0.0_1"), "info/index.json: 'build' must be mojo<compiler>_0"),
            ("build", json!("mojo_0"), "info/index.json: 'build' must be mojo<compiler>_0"),
            ("build", json!("mojo1..0_0"), "info/index.json: 'build' must be mojo<compiler>_0"),
            ("depends", json!("x"), "info/index.json: 'depends' must be an array of strings"),
            ("depends", json!([1]), "info/index.json: 'depends' must be an array of strings"),
        ] {
            let mut g = good.clone();
            g[field] = value;
            let e = index(g).unwrap_err();
            assert_eq!((e.rule, e.message.as_str()), (RuleCode::IndexInvalid, msg), "{field}");
        }
        let mut g = good;
        g.as_object_mut().unwrap().remove("build_number");
        assert_eq!(index(g).unwrap_err().message, "info/index.json: 'build_number' must be 0");
    }

    fn idx(depends: &[&str]) -> CondaIndex {
        CondaIndex { name: "mojo-demo".into(), version: "1.0.0".into(), build: "mojo1.0.0_0".into(), compiler: "1.0.0".into(), subdir: "noarch".into(), depends: depends.iter().map(|s| s.to_string()).collect() }
    }

    fn mopm_with(deps: &[&str]) -> Mopm {
        Mopm { name: "demo".into(), version: None, deps: deps.iter().map(|d| Dep { name: d.to_string(), range: None }).collect(), native: vec![] }
    }

    fn depends(d: &[&str], deps: &[&str]) -> Checked<Vec<String>> {
        check_depends(&idx(d), &mopm_with(deps))
    }

    #[test]
    fn depends_rules_in_their_order() {
        assert_eq!(depends(&["mojo-compiler ==1.0.0"], &[]).unwrap(), Vec::<String>::new());
        assert_eq!(depends(&["mojo-compiler  ==1.0.0", "mojo-b >=1", "mojo-a", "zlib"], &["a", "b"]).unwrap(), ["mojo-a", "mojo-b"]);
        let rule = |r: Checked<Vec<String>>| r.unwrap_err().rule;
        assert_eq!(rule(depends(&[], &[])), RuleCode::CompilerMissing);
        assert_eq!(rule(depends(&["mojo-compiler ==1.0.0", "mojo-compiler ==1.0.0"], &[])), RuleCode::CompilerMismatch);
        assert_eq!(rule(depends(&["mojo-compiler >=1.0.0"], &[])), RuleCode::CompilerMismatch);
        assert_eq!(rule(depends(&["mojo-compiler ==1.0.1"], &[])), RuleCode::CompilerMismatch);
        assert_eq!(rule(depends(&["mojo-compiler ==1.0.0", "Zlib"], &[])), RuleCode::DependencyNotAllowed, "a name that is not a conda name");
        assert_eq!(rule(depends(&["mojo-compiler ==1.0.0", "zlib >=1 h1 extra"], &[])), RuleCode::DependencyNotAllowed);
        assert_eq!(rule(depends(&["mojo-compiler ==1.0.0", "mojo-"], &[])), RuleCode::DependencyNotAllowed, "mojo- alone is not a package");
        let e = depends(&["mojo-compiler ==1.0.0", "mojo-b"], &["a"]).unwrap_err();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::DepsMismatch, "info/index.json depends [mojo-b] differ from the metadata deps [mojo-a]"));
        let e = depends(&["mojo-compiler ==1.0.0", "Zlib"], &[]).unwrap_err();
        assert_eq!(e.message, "dependency 'Zlib' does not start with a conda package name (lower-case letters, digits, ., _ and -)");
        let e = depends(&["mojo-compiler ==1.0.0", "mojo-"], &[]).unwrap_err();
        assert_eq!(e.message, "dependency 'mojo-' is not a Mojo package name");
        // Any well-formed native name is accepted, with or without a version and a build string.
        assert!(depends(&["mojo-compiler ==1.0.0", "zlib", "openssl >=3,<4", "libsqlite 3.* h5eee18b_0", "x  >=1"], &[]).is_ok());
        for bad in [" zlib", "zlib>=1", "zlib >=1;x", "zlib '>=1'", "zlib >=1 h/1", "a/b", "-zlib"] {
            assert_eq!(depends(&["mojo-compiler ==1.0.0", bad], &[]).unwrap_err().rule, RuleCode::DependencyNotAllowed, "{bad}");
        }
        assert_eq!(depends(&["mojo-compiler ==1.0.0", &"a".repeat(129)], &[]).unwrap_err().rule, RuleCode::DependencyNotAllowed);
        assert_eq!(depends(&["mojo-compiler ==1.0.0", &format!("zlib >={}", "1".repeat(300))], &[]).unwrap_err().rule, RuleCode::DependencyNotAllowed);
    }

    #[test]
    fn mojo_deps_are_returned_in_javascript_sort_order() {
        // U+1F600 is a surrogate pair (D83D DE00) and sorts before U+FF5E in UTF-16, after it in UTF-8.
        let r = depends(&["mojo-compiler ==1.0.0", "mojo-\u{ff5e}", "mojo-\u{1f600}", "mojo-a"], &["\u{ff5e}", "\u{1f600}", "a"]).unwrap();
        assert_eq!(r, ["mojo-a", "mojo-\u{1f600}", "mojo-\u{ff5e}"]);
    }

    #[test]
    fn native_names_fit_the_soname() {
        let n = |soname: &str, shared: Option<&str>, stat: Option<&str>| NativeDecl {
            id: "z".into(),
            soname: soname.into(),
            kind: "both".into(),
            mode: "link".into(),
            paths: vec![],
            shared_path: shared.map(String::from),
            static_path: stat.map(String::from),
        };
        check_native_names(&n("libz.so.1", Some("lib/libz.so.1"), Some("lib/libz.a"))).unwrap();
        check_native_names(&n("libz.so", Some("lib/libz.so.1.2"), None)).unwrap();
        let e = check_native_names(&n("libz.so.1", Some("lib/libfoo.so.1"), None)).unwrap_err();
        assert_eq!((e.rule, e.message.as_str()), (RuleCode::NativePath, "native 'z': file 'libfoo.so.1' does not fit soname 'libz.so.1'"));
        assert!(check_native_names(&n("libz.dylib", Some("lib/libz.dylib.1"), None)).is_err(), "only a .so soname takes version suffixes");
        let e = check_native_names(&n("libz.so", None, Some("lib/libfoo.a"))).unwrap_err();
        assert_eq!(e.message, "native 'z': static_file 'libfoo.a' must be 'libz.a'");
    }

    #[test]
    fn soname_pattern() {
        for yes in ["libz.so", "libz.so.1", "libz.1", "lib-x.a", "libfoo.dylib"] {
            assert!(soname_ok(yes), "{yes}");
        }
        for no in ["z.so", "lib.so", "libz", "libz.", "lib/z.so", "libz.\n"] {
            assert!(!soname_ok(no), "{no:?}");
        }
    }

    #[test]
    fn same_version_is_equality_of_valid_versions() {
        assert!(same_version("1.0.0", "1.0.0"));
        assert!(!same_version("1.0.0", "1.0.1"));
        assert!(!same_version("1.0", "1.0"), "an invalid spelling matches nothing");
    }
}
