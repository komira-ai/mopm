//! What an entry of the package may be (`validate/layout.ts`): names that are one file on some filesystem, and
//! the layout allow-list. "This is a package registry, not file storage."

use std::collections::BTreeMap;

use unicode_normalization::UnicodeNormalization;

use crate::codes::{fail_at, Checked, RuleCode};
use crate::tar::{Kind, TarEntry};

/// What an entry of the package is, once it passed the allow-list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Mojoc,
    Mopm,
    Native,
    /// A program shipped as source: `lib/mojo/<name>.bins/<bin>.mojo`, built on the installer's machine.
    Source,
    Info,
    License,
    Dir,
}

const INFO_FILES: [&str; 5] = ["info/index.json", "info/paths.json", "info/about.json", "info/files", "info/hash_input.json"];
const ALLOWED_DIRS: [&str; 4] = ["lib", "lib/mojo", "info", "info/licenses"];

/// `^lib\/lib[^/]+\.(?:so(?:\.\d+)*|dylib|a)$`: native library file names under `lib/`: `lib<stem>.so[.N...]`,
/// `lib<stem>.dylib`, `lib<stem>.a` (a static archive).
pub fn is_native_file(p: &str) -> bool {
    let Some(rest) = p.strip_prefix("lib/lib") else { return false };
    if rest.is_empty() || rest.contains('/') {
        return false;
    }
    // The stem is one or more characters, then a dot and a known suffix: try each dot.
    rest.char_indices().filter(|(_, c)| *c == '.').any(|(i, _)| i > 0 && suffix_ok(&rest[i + 1..]))
}

fn suffix_ok(s: &str) -> bool {
    if s == "dylib" || s == "a" {
        return true;
    }
    let Some(more) = s.strip_prefix("so") else { return false };
    more.split('.').skip(1).all(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit())) && (more.is_empty() || more.starts_with('.'))
}

/// `^[a-z0-9_]+\.mojo$`: the file name of a program's source below `lib/mojo/<name>.bins/`.
fn is_bin_source(file: &str) -> bool {
    file.strip_suffix(".mojo").is_some_and(|stem| !stem.is_empty() && stem.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_'))
}

/// `(?:^|[-_.])(?:pre-link|post-link|pre-unlink)\.(?:sh|bat)$`, case-insensitive, on the base name.
fn is_link_script(base: &str) -> bool {
    let lower = base.to_ascii_lowercase();
    ["pre-link", "post-link", "pre-unlink"].iter().any(|stem| {
        ["sh", "bat"].iter().any(|ext| {
            let tail = format!("{stem}.{ext}");
            match lower.strip_suffix(tail.as_str()) {
                Some("") => true,
                Some(before) => before.ends_with(['-', '_', '.']),
                None => false,
            }
        })
    })
}

fn fold(path: &str) -> String {
    path.nfkc().collect::<String>().to_lowercase().nfkc().collect()
}

/// Refuse two entries whose names are the same file on some filesystem: byte-identical duplicates, and paths that
/// differ only by Unicode normalisation (NFC/NFD, compatibility forms) or letter case, which fold together on macOS and
/// Windows and let one entry shadow another there.
pub fn check_collisions(entries: &[TarEntry]) -> Checked<()> {
    let mut seen: BTreeMap<String, &str> = BTreeMap::new();
    for e in entries {
        let key = fold(&e.path);
        match seen.get(&key) {
            None => {
                seen.insert(key, &e.path);
            }
            Some(prior) if *prior == e.path => {
                return fail_at(RuleCode::DuplicatePath, format!("'{}' appears more than once", e.path), e.path.clone());
            }
            Some(prior) => {
                return fail_at(
                    RuleCode::UnicodeCollision,
                    format!("'{prior}' and '{}' are the same name after Unicode normalisation or case folding", e.path),
                    e.path.clone(),
                );
            }
        }
    }
    Ok(())
}

/// Apply the layout allow-list to one entry.
pub fn classify(e: &TarEntry, name: &str) -> Checked<Role> {
    let p = e.path.as_str();
    let base = p.rsplit('/').next().unwrap_or(p);
    if p == "info/link.json" || p.starts_with("etc/conda/") || is_link_script(base) {
        return fail_at(RuleCode::LinkScript, format!("'{p}' is a link or activation script; packages may not run code at install time"), p);
    }
    let top = p.split('/').next().unwrap_or(p);
    if matches!(top, "bin" | "sbin" | "Scripts") {
        return fail_at(RuleCode::BinDir, format!("'{p}' is under {top}/; packages may not ship executables"), p);
    }
    if e.kind == Kind::Dir {
        if p == format!("lib/mojo/{name}.bins") {
            return Ok(Role::Dir);
        }
        if ALLOWED_DIRS.contains(&p) || p.starts_with("info/licenses/") {
            return Ok(Role::Dir);
        }
        return fail_at(RuleCode::LayoutNotAllowed, format!("directory '{p}' is outside the allowed layout"), p);
    }
    if p == format!("lib/mojo/{name}.mojoc") {
        return Ok(Role::Mojoc);
    }
    if p == format!("lib/mojo/{name}.mopm.json") {
        return Ok(Role::Mopm);
    }
    if p.strip_prefix(&format!("lib/mojo/{name}.bins/")).is_some_and(is_bin_source) {
        return Ok(Role::Source);
    }
    if is_native_file(p) {
        return Ok(Role::Native);
    }
    if INFO_FILES.contains(&p) {
        return Ok(Role::Info);
    }
    if p.starts_with("info/licenses/") {
        return Ok(Role::License);
    }
    fail_at(
        RuleCode::LayoutNotAllowed,
        format!("'{p}' is not an allowed path (allowed: lib/mojo/{name}.mojoc, lib/mojo/{name}.mopm.json, declared native libraries, info/ metadata, licence files)"),
        p,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(p: &str) -> TarEntry {
        TarEntry { path: p.into(), kind: Kind::File, data: vec![] }
    }

    fn dir(p: &str) -> TarEntry {
        TarEntry { path: p.into(), kind: Kind::Dir, data: vec![] }
    }

    #[test]
    fn native_file_names() {
        for yes in ["lib/libfoo.so", "lib/libfoo.so.1", "lib/libfoo.so.1.2.3", "lib/libfoo.dylib", "lib/libfoo.a", "lib/libfoo.bar.so", "lib/lib.x.a", "lib/libf.so.9"] {
            assert!(is_native_file(yes), "{yes}");
        }
        for no in ["lib/foo.so", "lib/libfoo", "lib/libfoo.so.", "lib/libfoo.so.x", "lib/libfoo.sox", "lib/sub/libfoo.so", "lib/lib.so", "lib/libfoo.so.1.", "lib/libfoo.dll", "lib/libfoo.a.b", "libfoo.so", "lib/lib"] {
            assert!(!is_native_file(no), "{no}");
        }
    }

    #[test]
    fn link_scripts_in_any_directory_in_any_case() {
        for yes in ["post-link.sh", "pre-link.bat", "pre-unlink.sh", "POST-LINK.SH", "x-post-link.sh", "x_pre-link.bat", "x.pre-unlink.bat"] {
            assert!(is_link_script(yes), "{yes}");
        }
        for no in ["xpost-link.sh", "post-link.sh.txt", "post-link", "link.sh", "post-link.py"] {
            assert!(!is_link_script(no), "{no}");
        }
    }

    #[test]
    fn collisions_by_normalisation_and_case() {
        let ok = [file("a"), file("b")];
        check_collisions(&ok).unwrap();
        let dup = check_collisions(&[file("a"), file("a")]).unwrap_err();
        assert_eq!((dup.rule, dup.message.as_str()), (RuleCode::DuplicatePath, "'a' appears more than once"));
        let case = check_collisions(&[file("lib/A"), file("lib/a")]).unwrap_err();
        assert_eq!((case.rule, case.message.as_str()), (RuleCode::UnicodeCollision, "'lib/A' and 'lib/a' are the same name after Unicode normalisation or case folding"));
        // NFC and NFD of e-acute, a ligature, a full-width letter.
        for (x, y) in [("\u{e9}", "e\u{301}"), ("\u{fb01}", "fi"), ("\u{ff21}", "a")] {
            assert_eq!(check_collisions(&[file(x), file(y)]).unwrap_err().rule, RuleCode::UnicodeCollision, "{x} {y}");
        }
        assert_eq!(check_collisions(&[file("a"), dir("a")]).unwrap_err().rule, RuleCode::DuplicatePath);
    }

    #[test]
    fn roles_of_the_allowed_paths() {
        let n = "demo";
        let cases = [
            (file("lib/mojo/demo.mojoc"), Role::Mojoc),
            (file("lib/mojo/demo.mopm.json"), Role::Mopm),
            (file("lib/mojo/demo.bins/agg_bench.mojo"), Role::Source),
            (dir("lib/mojo/demo.bins"), Role::Dir),
            (file("lib/libz.so.1"), Role::Native),
            (file("info/index.json"), Role::Info),
            (file("info/licenses/LICENSE"), Role::License),
            (file("info/licenses/a/b/NOTICE"), Role::License),
            (dir("lib"), Role::Dir),
            (dir("lib/mojo"), Role::Dir),
            (dir("info/licenses"), Role::Dir),
            (dir("info/licenses/sub"), Role::Dir),
        ];
        for (e, role) in cases {
            assert_eq!(classify(&e, n).unwrap(), role, "{}", e.path);
        }
    }

    #[test]
    fn refusals_and_their_order() {
        let n = "demo";
        let rule = |e: TarEntry| classify(&e, n).unwrap_err().rule;
        assert_eq!(rule(file("info/link.json")), RuleCode::LinkScript);
        assert_eq!(rule(file("etc/conda/activate.d/x.sh")), RuleCode::LinkScript);
        assert_eq!(rule(file("lib/post-link.sh")), RuleCode::LinkScript);
        assert_eq!(rule(file("bin/tool")), RuleCode::BinDir);
        assert_eq!(rule(file("sbin/tool")), RuleCode::BinDir);
        assert_eq!(rule(file("Scripts/x")), RuleCode::BinDir);
        assert_eq!(rule(file("bin/post-link.sh")), RuleCode::LinkScript, "the link-script rule is first");
        assert_eq!(rule(file("share/x")), RuleCode::LayoutNotAllowed);
        assert_eq!(rule(dir("share")), RuleCode::LayoutNotAllowed);
        assert_eq!(rule(file("lib/mojo/other.mojoc")), RuleCode::LayoutNotAllowed);
        assert_eq!(rule(file("lib/sub/libfoo.so")), RuleCode::LayoutNotAllowed);
        for no in ["lib/mojo/demo.bins/Bench.mojo", "lib/mojo/demo.bins/a-b.mojo", "lib/mojo/demo.bins/.mojo", "lib/mojo/demo.bins/a.py", "lib/mojo/demo.bins/sub/a.mojo", "lib/mojo/other.bins/a.mojo", "lib/mojo/demo.bins"] {
            assert_eq!(rule(file(no)), RuleCode::LayoutNotAllowed, "{no}");
        }
        assert_eq!(rule(dir("lib/mojo/other.bins")), RuleCode::LayoutNotAllowed);
        assert_eq!(rule(dir("lib/mojo/demo.bins/sub")), RuleCode::LayoutNotAllowed);
        let e = classify(&file("share/x"), n).unwrap_err();
        assert_eq!(e.message, "'share/x' is not an allowed path (allowed: lib/mojo/demo.mojoc, lib/mojo/demo.mopm.json, declared native libraries, info/ metadata, licence files)");
        assert_eq!(e.path.as_deref(), Some("share/x"));
    }
}
