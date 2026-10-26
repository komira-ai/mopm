//! mopm_validate: the package validator, ported from `service/api/src/validate`. Pure: bytes in, verdict out, no I/O.
//! A hostile or malformed archive yields a rejected [`Verdict`] with a stable code; it never panics. The verdicts
//! (rule, code, message, path, and the order rules are applied in) are held to the corpus of
//! `tests/validator_corpus`, which records what the TypeScript validator answered for each input.
//!
//! Hand-written on purpose, because the readers define the verdict: the zip central-directory reader
//! ([`zip`]) and the tar reader ([`tar`]); the `zip` and `tar` crates normalise what they must refuse.
//! Decompression uses `ruzstd` and `flate2` (pure Rust), under the collector's caps ([`collector`]).

pub mod codes;
pub mod collector;
pub mod js;
pub mod layout;
pub mod metadata;
pub mod tar;
pub mod zip;
pub mod zstd;

use std::collections::{BTreeMap, BTreeSet};

use mopm_core::limits::Limits;
use mopm_core::rejection::RejectionCode;
use serde::Serialize;
use sha2::{Digest, Sha256};

pub use codes::{Failure, RuleCode};
pub use layout::Role;
pub use metadata::Mopm;

use codes::{fail, fail_at, Checked};
use collector::Collector;
use tar::{Budget, TarEntry};

/// What the publisher declared (begin-upload and commit); the archive must agree with every field.
#[derive(Clone, Debug, Default)]
pub struct PublishExpectation {
    pub name: String,
    pub version: String,
    pub subdir: String,
    pub filename: String,
    /// Hex sha256 declared at begin-upload. Checked when given.
    pub sha256: Option<String>,
    /// Hex sha256 declared at commit, taken to be of the bytes of `lib/mojo/<name>.mopm.json`. Checked when given.
    pub manifest_sha256: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct ValidatorOptions {
    /// Defaults to [`Limits::DEFAULT`].
    pub limits: Limits,
    /// Native library ids that may appear in `depends` (the maintained allow-list). Default: none.
    pub allowed_native_deps: BTreeSet<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FactsFile {
    pub path: String,
    pub size: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PackageFacts {
    pub format: &'static str,
    pub name: String,
    pub version: String,
    pub build: String,
    pub compiler: String,
    pub subdir: String,
    /// Names of the `mojo-*` packages depended on, sorted, with the `mojo-` prefix.
    #[serde(rename = "mojoDeps")]
    pub mojo_deps: Vec<String>,
    /// The allow-listed system libraries `depends` requires (`lz4-c >=1.9.3`), sorted; never a library the package ships.
    #[serde(rename = "nativeDepends")]
    pub native_depends: Vec<String>,
    pub metadata: Mopm,
    #[serde(rename = "manifestSha256")]
    pub manifest_sha256: String,
    pub files: Vec<FactsFile>,
    #[serde(rename = "unpackedBytes")]
    pub unpacked_bytes: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    Accepted(Box<PackageFacts>),
    Rejected(Failure),
}

impl Verdict {
    /// The verdict as the corpus records it: `{ok: true, facts}` or `{ok: false, rejection_code, rule, message, path?}`.
    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Verdict::Accepted(f) => serde_json::json!({"ok": true, "facts": f}),
            Verdict::Rejected(e) => {
                let mut v = serde_json::json!({"ok": false, "rejection_code": e.rejection().as_str(), "rule": e.rule.as_str(), "message": e.message});
                if let Some(p) = &e.path {
                    v["path"] = serde_json::Value::String(p.clone());
                }
                v
            }
        }
    }

    pub fn rejection_code(&self) -> Option<RejectionCode> {
        match self {
            Verdict::Accepted(_) => None,
            Verdict::Rejected(e) => Some(e.rejection()),
        }
    }
}

const ZIP_MAGIC: [u8; 4] = [0x50, 0x4b, 0x03, 0x04];
const BZIP2_MAGIC: [u8; 3] = [0x42, 0x5a, 0x68];

fn sha256_hex(b: &[u8]) -> String {
    hex::encode(Sha256::digest(b))
}

/// Validate an uploaded package archive before it is committed.
pub fn validate_package(archive: &[u8], expected: &PublishExpectation, options: &ValidatorOptions) -> Verdict {
    match run(archive, expected, options, &options.limits) {
        Ok(facts) => Verdict::Accepted(Box::new(facts)),
        Err(f) => Verdict::Rejected(f),
    }
}

/// `/^pkg-.+\.tar\.zst$/` and `/^info-.+\.tar\.zst$/` on a zip entry name.
fn tar_zst_named(name: &str, prefix: &str) -> bool {
    name.strip_prefix(prefix).and_then(|r| r.strip_suffix(".tar.zst")).is_some_and(|mid| !mid.is_empty() && !mid.contains(['\n', '\r', '\u{2028}', '\u{2029}']))
}

fn run(buf: &[u8], expected: &PublishExpectation, options: &ValidatorOptions, limits: &Limits) -> Checked<PackageFacts> {
    // 1. Size and declared hash.
    if buf.is_empty() {
        return fail(RuleCode::NotAnArchive, "the upload is empty");
    }
    if buf.len() as u64 > limits.max_archive_bytes {
        return fail(RuleCode::ArchiveTooLarge, format!("the archive is {} bytes; the limit is {}", buf.len(), limits.max_archive_bytes));
    }
    if let Some(want) = &expected.sha256 {
        if sha256_hex(buf) != want.to_lowercase() {
            return fail(RuleCode::Sha256Mismatch, "the archive does not hash to the sha256 declared at begin-upload");
        }
    }

    // 2. Which format it really is: the bytes decide, the name must agree.
    let format = if buf.starts_with(&ZIP_MAGIC) {
        "conda"
    } else if buf.starts_with(&BZIP2_MAGIC) {
        "tar.bz2"
    } else {
        return fail(RuleCode::NotAnArchive, "the upload is neither a .conda (zip) nor a .tar.bz2 archive");
    };
    if !expected.filename.ends_with(&format!(".{format}")) {
        return fail(RuleCode::NotAnArchive, format!("the bytes are a {format} archive but the file is named '{}'", expected.filename));
    }
    // The channel publishes only `.conda`; a `.tar.bz2` is read by nothing here.
    if format != "conda" {
        return fail(RuleCode::FormatNotAllowed, format!(".{format} packages are not accepted"));
    }

    // 3. Unpack with every cap live.
    let mut budget = Budget::default();
    let slack = limits.max_files * 2048 + 65536; // tar headers and padding on top of file bytes
    let tar_of = |compressed: &[u8], what: &str, budget: &mut Budget| -> Checked<Vec<TarEntry>> {
        let cap = limits.max_unpacked_bytes.saturating_sub(budget.bytes) + slack;
        let mut out = Collector::new(cap, compressed.len() as u64, limits, what);
        zstd::unzstd(compressed, &mut out, what)?;
        tar::read_tar(&out.result(), limits, budget)
    };
    let zip = zip::read_zip(buf, limits, limits.max_unpacked_bytes + slack)?;
    let meta: Vec<_> = zip.iter().filter(|z| z.name == "metadata.json").collect();
    let pkg: Vec<_> = zip.iter().filter(|z| tar_zst_named(&z.name, "pkg-")).collect();
    let info: Vec<_> = zip.iter().filter(|z| tar_zst_named(&z.name, "info-")).collect();
    if zip.len() != 3 || meta.len() != 1 || pkg.len() != 1 || info.len() != 1 {
        return fail(RuleCode::CondaLayout, "a .conda holds exactly metadata.json, one pkg-*.tar.zst and one info-*.tar.zst");
    }
    let conda_meta = js::decode_utf8(&meta[0].data).and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok());
    let version_ok = conda_meta.as_ref().and_then(|m| m.as_object()).and_then(|o| o.get("conda_pkg_format_version")).is_some_and(|v| v.as_f64() == Some(2.0));
    if !version_ok {
        return fail(RuleCode::CondaLayout, "metadata.json must be an object with conda_pkg_format_version 2");
    }
    let info_entries = tar_of(&info[0].data, &info[0].name, &mut budget)?;
    for e in &info_entries {
        if e.path.split('/').next() != Some("info") {
            return fail_at(RuleCode::CondaLayout, format!("'{}' is in the info tar but not under info/", e.path), e.path.clone());
        }
    }
    let pkg_entries = tar_of(&pkg[0].data, &pkg[0].name, &mut budget)?;
    for e in &pkg_entries {
        if e.path.split('/').next() == Some("info") {
            return fail_at(RuleCode::CondaLayout, format!("'{}' is in the pkg tar but under info/", e.path), e.path.clone());
        }
    }
    let entries: Vec<TarEntry> = info_entries.into_iter().chain(pkg_entries).collect();

    // 4. Names: collisions, then the layout allow-list.
    layout::check_collisions(&entries)?;
    let mut roles: BTreeMap<&str, Role> = BTreeMap::new();
    let mut by_path: BTreeMap<&str, &TarEntry> = BTreeMap::new();
    for e in &entries {
        roles.insert(&e.path, layout::classify(e, &expected.name)?);
        by_path.insert(&e.path, e);
    }
    let mojoc_path = format!("lib/mojo/{}.mojoc", expected.name);
    let mopm_path = format!("lib/mojo/{}.mopm.json", expected.name);
    if !by_path.contains_key(mojoc_path.as_str()) {
        return fail(RuleCode::MojocMissing, format!("{mojoc_path} is missing"));
    }
    let Some(mopm_file) = by_path.get(mopm_path.as_str()) else { return fail(RuleCode::ManifestMissing, format!("{mopm_path} is missing")) };
    let Some(index_file) = by_path.get("info/index.json") else { return fail(RuleCode::IndexMissing, "info/index.json is missing") };
    for f in [mopm_file, index_file] {
        if f.data.len() as u64 > limits.max_metadata_bytes {
            return fail_at(RuleCode::ManifestTooLarge, format!("'{}' is {} bytes", f.path, f.data.len()), f.path.clone());
        }
    }

    // 5. Metadata consistency.
    let manifest_sha256 = sha256_hex(&mopm_file.data);
    if let Some(want) = &expected.manifest_sha256 {
        if manifest_sha256 != want.to_lowercase() {
            return fail(RuleCode::ManifestSha256Mismatch, "the embedded metadata does not hash to the manifest_sha256 declared at commit");
        }
    }
    let mopm = metadata::check_mopm(&metadata::parse_json_object(&mopm_file.data, &mopm_file.path, metadata::JsonRule::Manifest)?)?;
    if mopm.name != expected.name {
        return fail(RuleCode::NameMismatch, format!("metadata name '{}' is not the published name '{}'", mopm.name, expected.name));
    }
    if let Some(v) = &mopm.version {
        if !metadata::same_version(v, &expected.version) {
            return fail(RuleCode::VersionMismatch, format!("metadata version '{v}' is not the published version '{}'", expected.version));
        }
    }
    let idx = metadata::check_index(&metadata::parse_json_object(&index_file.data, &index_file.path, metadata::JsonRule::Index)?)?;
    if idx.name != format!("mojo-{}", expected.name) {
        return fail(RuleCode::NameMismatch, format!("info/index.json name '{}' is not 'mojo-{}'", idx.name, expected.name));
    }
    if !metadata::same_version(&idx.version, &expected.version) {
        return fail(RuleCode::VersionMismatch, format!("info/index.json version '{}' is not the published version '{}'", idx.version, expected.version));
    }
    if idx.subdir != expected.subdir {
        return fail(RuleCode::SubdirMismatch, format!("info/index.json subdir '{}' is not '{}'", idx.subdir, expected.subdir));
    }
    let mojo_deps = metadata::check_depends(&idx, &mopm, &options.allowed_native_deps)?;
    let native_depends = metadata::native_depends_of(&idx);
    let want_file = format!("mojo-{}-{}-{}.{format}", expected.name, expected.version, idx.build);
    if expected.filename != want_file {
        return fail(RuleCode::FilenameMismatch, format!("the file is named '{}' but its metadata says '{want_file}'", expected.filename));
    }

    // 6. Native libraries: every declared file present, every library file declared.
    let mut claimed: BTreeSet<&str> = BTreeSet::new();
    let mut ids: BTreeSet<&str> = BTreeSet::new();
    for n in &mopm.native {
        if !ids.insert(&n.id) {
            return fail(RuleCode::ManifestSchema, format!("native id '{}' is declared twice", n.id));
        }
        metadata::check_native_names(n)?;
        for p in &n.paths {
            if roles.get(p.as_str()) != Some(&Role::Native) {
                return fail_at(RuleCode::NativeMissing, format!("native '{}' declares '{p}', which the package does not contain", n.id), p.clone());
            }
            claimed.insert(p);
        }
    }
    // Map order is by path, as the TypeScript Map's is by insertion: the first undeclared library in either order is a
    // matter of which one is named in the message, so walk in insertion order.
    for e in &entries {
        if roles.get(e.path.as_str()) == Some(&Role::Native) && !claimed.contains(e.path.as_str()) {
            return fail_at(RuleCode::NativeUndeclared, format!("'{}' is a native library the metadata does not declare", e.path), e.path.clone());
        }
    }

    Ok(PackageFacts {
        format: "conda",
        name: expected.name.clone(),
        version: expected.version.clone(),
        build: idx.build,
        compiler: idx.compiler,
        subdir: idx.subdir,
        mojo_deps,
        native_depends,
        metadata: mopm,
        manifest_sha256,
        files: entries.iter().filter(|e| e.kind == tar::Kind::File).map(|e| FactsFile { path: e.path.clone(), size: e.data.len() as u64 }).collect(),
        unpacked_bytes: budget.bytes,
    })
}

#[cfg(test)]
mod corpus_replay;
#[cfg(test)]
mod corpus_table;
